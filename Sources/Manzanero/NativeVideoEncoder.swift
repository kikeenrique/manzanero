import AVFoundation
import CoreImage
import CoreVideo
import Foundation

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
    /// With sound, a second input: the device's audio decoded to PCM and
    /// written as AAC.
    private let audio: Bool
    private var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var audioFormat: CMAudioFormatDescription?
    private var audioEnd: UInt64 = 0

    init(destination: URL, seconds: Double, codec: String, audio: Bool = false) throws {
        guard seconds.isFinite, (1...300).contains(seconds), ["h264", "hevc"].contains(codec) else {
            throw CommandFailure(.internal, "Invalid native recording duration or codec.", inputSent: .none)
        }
        self.destination = destination
        self.seconds = seconds
        self.codec = codec
        self.audio = audio
    }

    /// Interleaved 16-bit samples at `nanoseconds` on the movie's timeline.
    /// Sound that arrives before the first picture has no movie to go into
    /// and is dropped; so is sound that would start before what is written.
    func consumeAudio(_ samples: [Int16], nanoseconds: UInt64) async throws {
        guard audioReceiver != nil, audioFormat != nil, !samples.isEmpty, nanoseconds >= audioEnd,
              nanoseconds < UInt64(seconds * 1_000_000_000) else { return }
        try Task.checkCancellation()
        // A piece that starts after the last one ended (a recording's restart,
        // docs/recording-recovery.md) leaves a gap. The AAC writer encodes the
        // samples it is given back to back whatever their times, so a gap left
        // empty disappeared from the movie and all the sound after a restart
        // played seven seconds early (iPhone 13 mini, 2026-11-22). The gap is
        // written as silence, in pieces of at most a second.
        if audioEnd > 0 {
            var gap = NativeAudioTrack.frames(nanoseconds: nanoseconds - audioEnd)
            while gap > 0 {
                let chunk = min(gap, Int(NativeAudioDecoder.sampleRate))
                try await appendAudio([Int16](repeating: 0, count: chunk * NativeAudioDecoder.channels), nanoseconds: audioEnd)
                gap -= chunk
            }
        }
        try await appendAudio(samples, nanoseconds: max(nanoseconds, audioEnd))
    }

    private func appendAudio(_ samples: [Int16], nanoseconds: UInt64) async throws {
        guard let audioReceiver, let audioFormat else { return }
        let frames = samples.count / NativeAudioDecoder.channels, bytes = samples.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                blockBufferOut: &block) == noErr, let block,
              samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr
        else { throw CommandFailure(.toolFailed, "Cannot allocate a native audio sample.", inputSent: .none) }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
                sampleCount: frames, presentationTimeStamp: CMTime(value: Int64(nanoseconds), timescale: 1_000_000_000),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr, let buffer
        else { throw CommandFailure(.toolFailed, "Cannot create a native audio sample.", inputSent: .none) }
        try await audioReceiver.append(CMReadySampleBuffer(unsafeBuffer: buffer))
        // The same whole-number length NativeAudioTrack places pieces by, so
        // the next piece never seems to start before this one ends.
        audioEnd = nanoseconds + NativeAudioTrack.nanoseconds(frames: UInt64(frames))
    }

    func consume(_ frame: NativeVideoFrame) async throws {
        guard frame.nanoseconds < UInt64(seconds * 1_000_000_000), frameCount < 10_000,
            frameCount == 0 ? frame.nanoseconds == 0 : frame.nanoseconds > lastTime
        else {
            throw CommandFailure(.internal, "Invalid native frame timestamp or count budget.", inputSent: .none)
        }
        try Task.checkCancellation()
        let width = frame.pixels.size.width, height = frame.pixels.size.height
        guard
            (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000,
            frame.pixels.pixelFormatType.rawValue == kCVPixelFormatType_32BGRA
        else {
            throw CommandFailure(.transportFailed, "Native video frame has unsupported pixel format or dimensions.", inputSent: .none)
        }
        if let dimensions {
            guard dimensions == (width, height) else {
                throw CommandFailure(.preconditionChanged, "Native video dimensions changed during recording.", inputSent: .none)
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
                throw CommandFailure(.internal, "Cannot create native movie encoder input.", inputSent: .none)
            }
            receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            if audio {
                let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: NativeAudioDecoder.sampleRate,
                    AVNumberOfChannelsKey: NativeAudioDecoder.channels, AVEncoderBitRateKey: 160_000])
                sound.expectsMediaDataInRealTime = true
                var pcm = NativeAudioDecoder.pcmFormat
                var format: CMAudioFormatDescription?
                guard writer.canAdd(sound), CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &pcm, layoutSize: 0, layout: nil,
                        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
                    throw CommandFailure(.internal, "Cannot create native movie audio input.", inputSent: .none)
                }
                audioFormat = format
                audioReceiver = writer.inputReceiver(for: sound)
            }
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            FileHandle.standardError.write(Data("Recording started (native video first frame).\n".utf8))
        }
        let outWidth = (width + 1) / 2 * 2
        let outHeight = (height + 1) / 2 * 2
        let buffer: CVReadOnlyPixelBuffer
        if width == outWidth && height == outHeight {
            buffer = frame.pixels
        } else {
            let pixel = try CVMutablePixelBuffer(
                .init(
                    pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                    size: .init(width: outWidth, height: outHeight)))
            let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            frame.pixels.withUnsafeBuffer { source in
                pixel.withUnsafeBuffer { context.render(CIImage(cvPixelBuffer: source).composited(over: background), to: $0) }
            }
            buffer = CVReadOnlyPixelBuffer(pixel)
        }
        guard let receiver else { throw CommandFailure(.internal, "Native encoder receiver is unavailable.", inputSent: .none) }
        try await receiver.append(buffer, with: CMTime(value: Int64(frame.nanoseconds), timescale: 1_000_000_000))
        last = buffer
        lastTime = frame.nanoseconds
        frameCount += 1
    }

    /// Ends the movie at the requested duration, or, for a recording kept
    /// after a failure (`partial`), shortly after its last picture.
    func finish(partial: Bool = false) async throws -> Int {
        guard let writer, let receiver, let last else {
            throw CommandFailure(.transportFailed, "Native video produced no encodable frame.", inputSent: .none)
        }
        // Deduplication/static screens must retain their last image through the
        // requested interval instead of becoming a one-frame-duration movie.
        let end = partial ? min(lastTime + 100_000_000, UInt64(seconds * 1_000_000_000)) : UInt64(seconds * 1_000_000_000)
        let tail = end - 1_000_000
        if lastTime < tail {
            try await receiver.append(last, with: CMTime(value: Int64(tail), timescale: 1_000_000_000))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(end), timescale: 1_000_000_000))
        receiver.finish()
        audioReceiver?.finish()
        await writer.finishWriting()
        guard writer.status == .completed else {
            // AVFoundation refused to finish the file; recording sends no input.
            throw CommandFailure(.toolFailed, "Native movie finalization failed: \(String(describing: writer.error))", inputSent: .none)
        }
        return frameCount
    }

    func cancel() { writer?.cancelWriting() }
}

struct NativeRecordingReceipt: Sendable {
    let frames: Int
    let media: NativeMediaFrames.Cleanup
    let assertionRelease: String
    let receiverReportsSent: UInt64
    let senderReportsObserved: UInt64
    let negotiatedFeedback: String
    /// The sound written, when the recording asked for it.
    var audio: NativeAudioTrack.Receipt? = nil
    /// Restarts and gaps, for a recording without sound.
    var recovery: RecordingRecovery? = nil
    /// Why the recording ended early, when what was captured was kept.
    var partial: String? = nil
    /// What ended a kept partial recording: `interrupted` (SIGINT, SIGTERM
    /// or MCP cancellation), `another-viewer` (another client took the
    /// screen) or `failure`.
    var stopCause: String? = nil
    var interrupted: Bool { stopCause == "interrupted" }
}

extension CommandFailure {
    /// A failed native recording. When no packet arrived and the firewall
    /// would drop the video, the Mac's firewall is the thing to fix.
    static func nativeRecording(_ detail: String, wrapping error: any Error, firewallDropsVideo: Bool) -> Self {
        firewallDropsVideo
            ? Self(.hostRequirement, detail, inputSent: .none, action: .allowFirewall)
            : Self(detail, wrapping: error)
    }
}

/// Resolve aliases to the CoreDevice UUID before reserving a stream. This covers
/// concurrent MCP requests in this process; separate CLI processes do not share it.
/// Native recording and `frames` share one reservation: one stream per device.
actor NativeRecordingSessions {
    static let shared = NativeRecordingSessions()
    private var devices: Set<String> = []

    func begin(_ uuid: String) throws {
        try Task.checkCancellation()
        guard devices.insert(uuid.lowercased()).inserted else {
            throw CommandFailure(.deviceBusy, "A native recording or frame capture is already active for this device in this process.", inputSent: .none)
        }
    }

    func end(_ uuid: String) { devices.remove(uuid.lowercased()) }
}
