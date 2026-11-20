import Foundation
import AVFoundation

struct RecordingCommand: Sendable, Equatable {
    let physical: Bool
    let device: String
    let destination: URL
    let seconds: Double
    let codec: String
    let native: Bool
    /// The requested simulator display (`--display`), checked by `SimulatorDisplays.validated`.
    var display: String? = nil
    /// The simulator display chosen at run time; nil keeps the plain recordVideo.
    var selection: SimulatorDisplaySelection? = nil
    /// `--audio`: the device's sound in the movie, with the in-process
    /// backend only (docs/recording.md#sound).
    private(set) var audio = false

    /// `--audio` is the in-process physical backend's.
    func withAudio(_ requested: Bool) throws -> RecordingCommand {
        guard requested else { return self }
        guard physical, native else {
            throw CommandFailure.usage("--audio records a physical device's sound and needs --backend coredevice.")
        }
        var copy = self
        copy.audio = true
        return copy
    }

    /// `backend` is devicectl (the default) or coredevice, physical only.
    init(physical: Bool, device: String, output: String, seconds: String, codec: String?, backend: String?) throws {
        if let backend {
            guard ["devicectl", "coredevice"].contains(backend), physical else {
                throw CommandFailure.usage("--backend <devicectl|coredevice> requires a physical recording command.")
            }
        }
        guard !device.isEmpty, !device.hasPrefix("-"),
              !output.hasPrefix("-"), output.lowercased().hasSuffix(".mp4"),
              let duration = Double(seconds), duration.isFinite, (1...300).contains(duration),
              ["h264", "hevc"].contains(codec ?? "h264") else {
            throw CommandFailure.usage("Usage: record <output.mp4> <seconds: 1...300> [h264|hevc] [--backend devicectl|coredevice] (--device <UDID> | --simulator <UUID>)")
        }
        guard physical || UUID(uuidString: device) != nil else {
            throw CommandFailure.usage("Simulator recording requires an explicit simulator UUID.")
        }
        self.init(physical: physical, device: device, destination: URL(fileURLWithPath: output), seconds: duration,
                  codec: codec ?? "h264", native: backend == "coredevice")
    }

    init(physical: Bool, device: String, destination: URL, seconds: Double, codec: String, native: Bool) {
        self.physical = physical; self.device = device; self.destination = destination
        self.seconds = seconds; self.codec = codec; self.native = native
    }

    func command(staging: URL) throws -> DeviceCommand {
        guard !native else { throw CommandFailure(.internal, "Native recording runs in process through Apple media frameworks.", inputSent: .none) }
        if physical {
            return DeviceCommand(arguments: ["devicectl", "device", "capture", "screen-record", "--device", device,
                "--destination", staging.path, "--duration", String(seconds), "--codec", codec,
                "--timeout", String(Int(ceil(seconds)) + 60), "--json-output", "-"], jsonOutput: true)
        }
        return DeviceCommand(arguments: SimulatorDisplays.arguments(["simctl", "io", device, "recordVideo", "--codec=\(codec)", staging.path],
                                                                    selection: selection), jsonOutput: false)
    }

    func execute(directory: URL, runner: ToolRunner, isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandFailure.usage("Recording destination's parent directory must exist.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CommandFailure.usage("Recording destination already exists; choose a new .mp4 path.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent("capture.mp4")
        do {
            var nativeReceipt: NativeRecordingReceipt?
            if native {
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
            if let selection, selection.argument != nil {
                result["display"] = ["id": selection.display.id, "name": selection.display.name, "primary": selection.display.primary]
            }
            if let nativeReceipt {
                result["sourceFrames"] = nativeReceipt.frames
                result["timeline"] = "host-pixel-delivery"
                result["audio"] = nativeReceipt.audio != nil
                if let sound = nativeReceipt.audio {
                    result["audioTrack"] = ["received": "AAC-ELD", "written": "AAC", "sampleRate": Int(NativeAudioDecoder.sampleRate),
                        "channels": NativeAudioDecoder.channels, "packets": sound.packets, "packetsLost": sound.lost,
                        "packetsRefused": sound.refused, "secondsWritten": sound.seconds] as [String: Any]
                }
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
            // A recording sends no input, so nothing was sent whatever failed.
            throw CommandFailure("Recording failed: \(error). Investigation artifacts: \(directory.path)", wrapping: error).noInputSent()
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
        guard duration.isFinite, duration > 0 else { throw CommandFailure(.toolFailed, "Recording has no finite positive duration.", inputSent: .none) }
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: .zero)
        guard frame.image.width > 0, frame.image.height > 0 else { throw CommandFailure(.toolFailed, "Recording has no decodable video frame.", inputSent: .none) }
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw CommandFailure(.toolFailed, "Recording has no video format description.", inputSent: .none)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let codec = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }, as: UTF8.self)
        return Self(duration: duration, width: frame.image.width, height: frame.image.height, codec: codec)
    }
}
