import Foundation
import AVFoundation

struct RecordingCommand {
    let physical: Bool
    let device: String
    let destination: URL
    let seconds: Double
    let codec: String
    let native: Bool

    static func parse(_ args: [String]) throws -> Self? {
        var args = args
        var native = false
        if args.first == "--recording-backend" {
            guard args.count >= 3, ["devicectl", "coredevice"].contains(args[1]), args[2] == "physical" else {
                throw CommandFailure(description: "--recording-backend <devicectl|coredevice> requires a physical recording command.")
            }
            native = args[1] == "coredevice"
            args = Array(args.dropFirst(2))
        }
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), args[2] == "record" else { return nil }
        guard (5...6).contains(args.count), !args[1].isEmpty, !args[1].hasPrefix("-"),
              !args[3].hasPrefix("-"), args[3].lowercased().hasSuffix(".mp4"),
              let seconds = Double(args[4]), seconds.isFinite, (1...300).contains(seconds),
              ["h264", "hevc"].contains(args.count == 6 ? args[5] : "h264") else {
            throw CommandFailure(description: "Usage: <physical|simulator> <device> record <output.mp4> <seconds: 1...300> [h264|hevc]")
        }
        guard args[0] == "physical" || UUID(uuidString: args[1]) != nil else {
            throw CommandFailure(description: "Simulator recording requires an explicit simulator UUID.")
        }
        return Self(physical: args[0] == "physical", device: args[1], destination: URL(fileURLWithPath: args[3]), seconds: seconds, codec: args.count == 6 ? args[5] : "h264", native: native)
    }

    func command(staging: URL) throws -> DeviceCommand {
        guard !native else { throw CommandFailure(description: "Native recording runs in process through Apple media frameworks.") }
        if physical {
            return DeviceCommand(arguments: ["devicectl", "device", "capture", "screen-record", "--device", device,
                "--destination", staging.path, "--duration", String(seconds), "--codec", codec,
                "--timeout", String(Int(ceil(seconds)) + 60), "--json-output", "-"], jsonOutput: true)
        }
        return DeviceCommand(arguments: ["simctl", "io", device, "recordVideo", "--codec=\(codec)", staging.path], jsonOutput: false)
    }

    func execute(directory: URL, runner: ToolRunner, isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandFailure(description: "Recording destination's parent directory must exist.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CommandFailure(description: "Recording destination already exists; choose a new .mp4 path.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent("capture.mp4")
        do {
            var nativeReceipt: NativeRecordingReceipt?
            if native {
                guard #available(macOS 26.0, *) else { throw CommandFailure(description: "Native recording requires macOS 26 or later.") }
                nativeReceipt = try await NativeRecording.execute(self, staging: staging, runner: runner)
            } else if physical {
                let plan = try command(staging: staging)
                let response = try runner.run(plan.arguments)
                _ = try JSONSerialization.jsonObject(with: response)
            } else {
                let plan = try command(staging: staging)
                try runner.recordSimulator(plan.arguments, timing: .init(seconds: seconds))
            }
            let video = try await VideoArtifact.inspect(staging)
            try Task.checkCancellation()
            // moveItem refuses an existing destination, including one created while recording.
            try FileManager.default.moveItem(at: staging, to: destination)
            var result: [String: Any] = ["status": "recorded", "backend": native ? "coredevice-videotoolbox" : (physical ? "devicectl" : "simctl"),
                "path": destination.path, "requestedSeconds": seconds, "requestedCodec": codec,
                "artifact": ["durationSeconds": video.duration, "width": video.width, "height": video.height, "codec": video.codec, "frameDecoded": true]]
            if let nativeReceipt {
                result["sourceFrames"] = nativeReceipt.frames
                result["timeline"] = "host-pixel-delivery"
                result["audio"] = false
                result["rtcp"] = ["receiverReportsSent": nativeReceipt.receiverReportsSent,
                    "senderReportsObserved": nativeReceipt.senderReportsObserved,
                    "negotiatedFeedback": nativeReceipt.negotiatedFeedback] as [String: Any]
                result["cleanup"] = ["ownedStopAcknowledged": nativeReceipt.media.stopAcknowledged,
                    "ownedStreamAbsent": nativeReceipt.media.ownedStreamAbsent,
                    "deviceStopConfirmed": nativeReceipt.media.stopAcknowledged && nativeReceipt.media.ownedStreamAbsent,
                    "videoToolboxInvalidationReturned": true, "tunnelAssertionRelease": nativeReceipt.assertionRelease] as [String: Any]
                result["warnings"] = ["Experimental HEVC input. Reliable startup, keyframe recovery and crash recovery remain unfinished or unverified; synchronous Apple media calls have no independent hard deadline. RTCP send counts are local sends, not remote acknowledgements."]
            }
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("Recording cancelled. Investigation artifacts: \(directory.path)\n".utf8))
                throw CancellationError()
            }
            throw CommandFailure(description: "Recording failed: \(error). Investigation artifacts: \(directory.path)")
        }
    }
}

struct VideoArtifact: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let codec: String

    static func inspect(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CommandFailure(description: "Recording has no finite positive duration.") }
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: .zero)
        guard frame.image.width > 0, frame.image.height > 0 else { throw CommandFailure(description: "Recording has no decodable video frame.") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw CommandFailure(description: "Recording has no video format description.")
        }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let codec = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }, as: UTF8.self)
        return Self(duration: duration, width: frame.image.width, height: frame.image.height, codec: codec)
    }
}
