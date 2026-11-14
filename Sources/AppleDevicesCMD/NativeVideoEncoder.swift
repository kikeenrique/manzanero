import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO

@available(macOS 26.0, *)
actor NativeVideoEncoder {
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
    }

    func consume(_ frame: TimedVideoFrame) async throws {
        guard frame.nanoseconds < UInt64(seconds * 1_000_000_000), frameCount < 10_000,
            frameCount == 0 ? frame.nanoseconds == 0 : frame.nanoseconds > lastTime,
            (4...8 * 1024 * 1024).contains(frame.jpeg.count)
        else {
            throw CommandFailure(description: "Invalid native frame timestamp, size or count budget.")
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
            CGImageSourceGetType(source) as String? == "public.jpeg",
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CommandFailure(description: "Native video frame has unsupported image data or dimensions.")
        }
        if let dimensions {
            guard dimensions == (width, height) else {
                throw CommandFailure(description: "Native video dimensions changed during recording.")
            }
        } else {
            dimensions = (width, height)
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: (codec == "hevc" ? AVVideoCodecType.hevc : .h264).rawValue,
                    AVVideoWidthKey: (width + 1) / 2 * 2, AVVideoHeightKey: (height + 1) / 2 * 2,
                    // The deduplicated stream has irregular presentation times.
                    // Keep decode order equal to presentation order for seeking.
                    AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
                ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw CommandFailure(description: "Cannot create native movie encoder input.")
            }
            receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            FileHandle.standardError.write(Data("Recording started (native video first frame).\n".utf8))
        }
        let outWidth = (width + 1) / 2 * 2
        let outHeight = (height + 1) / 2 * 2
        let pixel = try CVMutablePixelBuffer(
            .init(
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

    func finish() async throws -> Int {
        guard let writer, let receiver, let last else {
            throw CommandFailure(description: "Native video produced no encodable frame.")
        }
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

struct NativeRecordingReceipt: Sendable {
    let frames: Int
    let media: NativeMediaFrames.Cleanup
    let assertionRelease: String
}

@available(macOS 26.0, *)
@MainActor enum NativeRecording {
    private static let sessions = NativeRecordingSessions()

    static func execute(_ command: RecordingCommand, staging: URL, runner: ToolRunner) async throws
        -> NativeRecordingReceipt
    {
        let input = CoreDeviceInput(device: command.device, operation: "record", operands: [])
        let details = try runner.run(input.identityPlan().arguments, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        let assertion = try NativeTunnelAssertion(device: command.device, details: details)
        defer { assertion.close() }
        let inventory = try runner.run([
            "devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet",
        ])
        let endpoint = try NativeMediaEndpoint.resolve(
            details: details, inventory: inventory, requested: command.device)
        let display = try DirectTouchDisplay(
            runner.run(AccessibilityDisplay.plan(device: identity.uuid).arguments, timeout: 15))
        let encoder = try NativeVideoEncoder(destination: staging, seconds: command.seconds, codec: command.codec)
        try await sessions.begin(endpoint.uuid)
        var capture: NativeMediaFrames?
        var decoder: NativeHEVCDecoder?
        var packetCount = 0
        var unitCount = 0
        var decodedCount = 0
        func closeMedia() -> NativeMediaFrames.Cleanup? {
            decoder?.close()
            return capture?.close()
        }
        do {
            capture = try NativeMediaFrames(endpoint: endpoint, version: identity.version, packets: true)
            try capture?.start(displayID: Int64(display.id))
            guard let profile = capture?.packetProfile(), let width = profile["width"], let height = profile["height"],
                let payload = profile["payloadType"], let payloadType = UInt8(exactly: payload)
            else {
                throw CommandFailure(description: "Native recording has no negotiated video profile.")
            }
            decoder = try NativeHEVCDecoder(width: Int(width), height: Int(height))
            var assembler = MediaHEVCAssembler()
            let startup = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
            let duration = UInt64(command.seconds * 1_000_000_000)
            var first: UInt64?
            var last: UInt64 = 0
            var checked = DispatchTime.now().uptimeNanoseconds
            var received = 0
            var emitted = 0
            while true {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                if let first, now - first >= duration { break }
                if first == nil, now >= startup {
                    throw CommandFailure(description: "Native recording exceeded its twelve-second first-frame budget.")
                }
                if now - checked >= 1_000_000_000 {
                    try capture?.requireActive()
                    checked = DispatchTime.now().uptimeNanoseconds
                }
                if let packet = try capture?.nextPacket() {
                    packetCount += 1
                    received += packet.count
                    guard received <= 1024 * 1024 * 1024 else {
                        throw CommandFailure(description: "Native recording exceeded its one-GiB transport budget.")
                    }
                    if let packet = MediaRTPPacket(packet, payloadType: payloadType),
                        let unit = try assembler.accept(packet)
                    {
                        unitCount += 1
                        guard let jpeg = try decoder?.decode(unit, emitJPEG: first == nil || now - last >= 33_333_333)
                        else { continue }
                        decodedCount += 1
                        let time = DispatchTime.now().uptimeNanoseconds
                        if first == nil { first = time }
                        guard let first, time - first < duration else { break }
                        emitted += jpeg.count
                        guard emitted <= 1024 * 1024 * 1024 else {
                            throw CommandFailure(description: "Native recording exceeded its one-GiB JPEG budget.")
                        }
                        try await encoder.consume(TimedVideoFrame(nanoseconds: time - first, jpeg: jpeg))
                        last = time
                    }
                } else {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try capture?.requireActive()
            guard let cleanup = closeMedia() else {
                throw CommandFailure(description: "Native recording lost its media owner.")
            }
            let release = assertion.close()
            guard cleanup.stopAcknowledged, cleanup.ownedStreamAbsent, release.confirmed else {
                throw CommandFailure(
                    description:
                        "Native recording cleanup unconfirmed: owned stop=\(cleanup.stopAcknowledged), stream absent=\(cleanup.ownedStreamAbsent), tunnel release=\(release.status). \(cleanup.diagnostic ?? "")"
                )
            }
            try Task.checkCancellation()
            let frames = try await encoder.finish()
            await sessions.end(endpoint.uuid)
            return NativeRecordingReceipt(frames: frames, media: cleanup, assertionRelease: release.status)
        } catch {
            let cleanup = closeMedia()
            let release = assertion.close()
            await encoder.cancel()
            await sessions.end(endpoint.uuid)
            let detail = "\(error) Capture: packets=\(packetCount), access units=\(unitCount), JPEG frames=\(decodedCount). Cleanup: owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")"
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("\(detail)\n".utf8))
                throw CancellationError()
            }
            throw CommandFailure(description: detail)
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
