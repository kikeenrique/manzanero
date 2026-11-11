import Foundation
import AVFoundation

struct RecordingCommand {
    let physical: Bool
    let device: String
    let destination: URL
    let seconds: Double
    let codec: String

    static func parse(_ args: [String]) throws -> Self? {
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
        return Self(physical: args[0] == "physical", device: args[1], destination: URL(fileURLWithPath: args[3]), seconds: seconds, codec: args.count == 6 ? args[5] : "h264")
    }

    func command(staging: URL) -> DeviceCommand {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent("capture.mp4")
        let plan = command(staging: staging)
        do {
            if physical {
                let response = try runner.run(plan.arguments)
                _ = try JSONSerialization.jsonObject(with: response)
            } else {
                try runner.recordSimulator(plan.arguments, timing: .init(seconds: seconds))
            }
            let video = try await VideoArtifact.inspect(staging)
            // moveItem refuses an existing destination, including one created while recording.
            try FileManager.default.moveItem(at: staging, to: destination)
            return try JSONSerialization.data(withJSONObject: ["status": "recorded", "backend": physical ? "devicectl" : "simctl",
                "path": destination.path, "requestedSeconds": seconds, "requestedCodec": codec,
                "artifact": ["durationSeconds": video.duration, "width": video.width, "height": video.height, "frameDecoded": true]], options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw CommandFailure(description: "Recording failed: \(error). Investigation artifacts: \(directory.path)")
        }
    }
}

struct VideoArtifact: Sendable {
    let duration: Double
    let width: Int
    let height: Int

    static func inspect(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CommandFailure(description: "Recording has no finite positive duration.") }
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: .zero)
        guard frame.image.width > 0, frame.image.height > 0 else { throw CommandFailure(description: "Recording has no decodable video frame.") }
        return Self(duration: duration, width: frame.image.width, height: frame.image.height)
    }
}
