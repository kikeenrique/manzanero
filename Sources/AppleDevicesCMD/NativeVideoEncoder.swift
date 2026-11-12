import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO

@available(macOS 26.0, *)
actor NativeVideoEncoder {
    private var parser: TimedVideoFrames
    private let destination: URL
    private let codec: String
    private let seconds: Double
    private let context = CIContext()
    private var writer: AVAssetWriter?
    private var receiver: AVAssetWriterInput.PixelBufferReceiver?
    private var dimensions: (Int, Int)?
    private var last: CVReadOnlyPixelBuffer?
    private var lastTime: UInt64 = 0
    private var frameCount = 0

    init(destination: URL, seconds: Double, codec: String) throws {
        guard seconds.isFinite, (1...300).contains(seconds), ["h264", "hevc"].contains(codec) else {
            throw CommandFailure(description: "Invalid native recording duration or codec.")
        }
        self.destination = destination
        self.seconds = seconds
        self.codec = codec
        parser = TimedVideoFrames(maximumNanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func consume(_ data: Data) async throws {
        for frame in try parser.feed(data) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CommandFailure(description: "Native video frame has unsupported image data or dimensions.")
            }
            if let dimensions {
                guard dimensions == (width, height) else { throw CommandFailure(description: "Native video dimensions changed during recording.") }
            } else {
                dimensions = (width, height)
                let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: (codec == "hevc" ? AVVideoCodecType.hevc : .h264).rawValue,
                    AVVideoWidthKey: (width + 1) / 2 * 2, AVVideoHeightKey: (height + 1) / 2 * 2,
                    // The deduplicated stream has irregular presentation times.
                    // Keep decode order equal to presentation order for seeking.
                    AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CommandFailure(description: "Cannot create native movie encoder input.") }
                receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
                try writer.start()
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                FileHandle.standardError.write(Data("Recording started (native video first frame).\n".utf8))
            }
            let outWidth = (width + 1) / 2 * 2, outHeight = (height + 1) / 2 * 2
            let pixel = try CVMutablePixelBuffer(.init(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: .init(width: outWidth, height: outHeight)))
            let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            pixel.withUnsafeBuffer {
                context.render(CIImage(cgImage: image).composited(over: background), to: $0)
            }
            let buffer = CVReadOnlyPixelBuffer(pixel)
            guard let receiver else { throw CommandFailure(description: "Native encoder receiver is unavailable.") }
            try await receiver.append(buffer, with: CMTime(value: Int64(frame.nanoseconds), timescale: 1_000_000_000))
            last = buffer
            lastTime = frame.nanoseconds
            frameCount += 1
        }
    }

    func finish() async throws -> Int {
        try parser.finish()
        guard let writer, let receiver, let last else { throw CommandFailure(description: "Native video produced no encodable frame.") }
        // Deduplication/static screens must retain their last image through the
        // requested interval instead of becoming a one-frame-duration movie.
        let tail = UInt64(seconds * 1_000_000_000) - 1_000_000
        if lastTime < tail {
            try await receiver.append(last, with: CMTime(value: Int64(tail), timescale: 1_000_000_000))
        }
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CommandFailure(description: "Native movie finalization failed: \(String(describing: writer.error))")
        }
        return frameCount
    }

    func cancel() { writer?.cancelWriting() }
}

@available(macOS 26.0, *)
enum NativeRecording {
    private static let sessions = NativeRecordingSessions()

    static func execute(_ command: RecordingCommand, staging: URL, runner: ToolRunner) async throws -> Int {
        guard let details = try DeviceCommand.parse(["physical", command.device, "details"]) else {
            throw CommandFailure(description: "Cannot plan native recording identity query.")
        }
        let identity = try runner.run(details.arguments + ["--quiet"])
        let inventory = try runner.run(["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"])
        let endpoint = try NativeMediaEndpoint.resolve(details: identity, inventory: inventory, requested: command.device)
        let plan = command.nativeCommand(endpoint: endpoint)
        let encoder = try NativeVideoEncoder(destination: staging, seconds: command.seconds, codec: command.codec)
        try await sessions.begin(endpoint.uuid)
        do {
            try await StreamingToolRunner().run(executable: plan.executable, arguments: plan.arguments, timeout: command.seconds + 90) {
                try await encoder.consume($0)
            }
            let frames = try await encoder.finish()
            await sessions.end(endpoint.uuid)
            return frames
        } catch {
            await encoder.cancel()
            await sessions.end(endpoint.uuid)
            throw error
        }
    }
}

/// Resolve aliases to the CoreDevice UUID before reserving a stream. This covers
/// concurrent MCP requests in this process; separate CLI processes do not share it.
actor NativeRecordingSessions {
    private var devices: Set<String> = []

    func begin(_ uuid: String) throws {
        try Task.checkCancellation()
        guard devices.insert(uuid.lowercased()).inserted else {
            throw CommandFailure(description: "A native recording is already active for this device in this process.")
        }
    }

    func end(_ uuid: String) { devices.remove(uuid.lowercased()) }
}
