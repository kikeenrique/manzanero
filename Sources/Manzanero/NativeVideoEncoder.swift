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
        guard let audioReceiver, let audioFormat, !samples.isEmpty, nanoseconds >= audioEnd,
              nanoseconds < UInt64(seconds * 1_000_000_000) else { return }
        try Task.checkCancellation()
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
        audioEnd = nanoseconds + UInt64(Double(frames) / NativeAudioDecoder.sampleRate * 1_000_000_000)
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
}

@MainActor enum NativeRecording {
    private static var sessions: NativeRecordingSessions { .shared }

    static func execute(_ command: RecordingCommand, staging: URL, runner: ToolRunner) async throws
        -> NativeRecordingReceipt
    {
        let input = CoreDeviceInput(device: command.device, operation: "record", operands: [])
        let details = try runner.run(input.identityPlan().arguments, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        // Both are taken again when a restart follows a lost link: the
        // device's address in the tunnel can change when its cable comes back.
        var assertion = try NativeTunnelAssertion(device: command.device, details: details)
        defer { assertion.close() }
        let inventory = try runner.run([
            "devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet",
        ])
        var endpoint = try NativeMediaEndpoint.resolve(
            details: details, inventory: inventory, requested: command.device)
        let display = try DirectTouchDisplay(
            runner.run(AccessibilityDisplay.plan(device: identity.uuid).arguments, timeout: 15), capture: true)
        let encoder = try NativeVideoEncoder(destination: staging, seconds: command.seconds, codec: command.codec, audio: command.audio)
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
        let duration = UInt64(command.seconds * 1_000_000_000)
        // A lost session after the first picture is restarted on the same
        // endpoint (docs/recording-recovery.md). With --audio there is no
        // restart: the sound stream's restart has not been checked.
        var recovery = command.audio ? nil : RecordingRecovery(durationNanoseconds: duration)
        var earlierReportsSent: UInt64 = 0, earlierReportsObserved: UInt64 = 0
        /// The last lost session's cleanup, for a recording that ends holding
        /// its picture, or is kept after a failure, with no session open.
        var closedCleanup: NativeMediaFrames.Cleanup?
        /// A lost session's absence read from the device's session count
        /// after its stop could not be confirmed (an unreachable device).
        var absenceByCount = false
        /// The lost session's stream identifier, kept across restart attempts.
        var lostIdentifier: UInt32?
        var stoppedByIdentifier = false
        do {
            capture = try NativeMediaFrames(endpoint: endpoint, version: identity.version, plainOffer: display.external)
            // The device's sound is a second stream, started before the
            // video as Apple's Device Hub starts it. With --audio a failure
            // to start it fails the recording: there is no silent fallback.
            var sound: NativeAudioTrack?
            if command.audio {
                try capture?.startAudio()
                guard let agreed = capture?.audioProfile else {
                    throw CommandFailure(.transportFailed, "Native recording has no negotiated audio profile.", inputSent: .none)
                }
                sound = try NativeAudioTrack(profile: agreed)
            }
            try capture?.start(displayID: Int64(display.id))
            guard let profile = capture?.packetProfile(), let width = profile["width"], let height = profile["height"],
                let payload = profile["payloadType"], let payloadType = UInt8(exactly: payload)
            else {
                throw CommandFailure(.transportFailed, "Native recording has no negotiated video profile.", inputSent: .none)
            }
            decoder = try NativeHEVCDecoder(width: Int(width), height: Int(height))
            // An Apple TV's screen fills the stream's width and leaves black
            // rows below it, which `frames` drops too. A phone's movie keeps
            // the whole picture, as it always has.
            let crop = display.external ? FramesCommand.visibleSize(display: display, stream: (Int(width), Int(height))) : nil
            var assembler = MediaHEVCAssembler()
            let startup = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
            var first: UInt64?
            var last: UInt64 = 0
            var checked = DispatchTime.now().uptimeNanoseconds
            var received = 0
            func restartSession() throws {
                earlierReportsSent += capture?.receiverReportsSent ?? 0
                earlierReportsObserved += capture?.senderReportsObserved ?? 0
                decoder?.close(); decoder = nil
                if let identifier = capture?.ownedIdentifier { lostIdentifier = identifier }
                let cleanup = capture?.close() ?? closedCleanup; capture = nil
                closedCleanup = cleanup
                if cleanup?.stopAcknowledged != true || cleanup?.ownedStreamAbsent != true {
                    // The stop could not be confirmed, as when the cable is
                    // pulled: the device cannot answer. Wait for it to answer
                    // again, then require that it runs no media session at
                    // all; a session still running is not stopped.
                    let deadline = DispatchTime.now().uptimeNanoseconds + RecordingRecovery.linkWaitNanoseconds
                    var count: UInt64?
                    while count == nil {
                        try Task.checkCancellation()
                        count = try? NativeMediaInspection.sessionCount(uuid: identity.uuid, version: identity.version)
                        if count == nil {
                            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                                throw CommandFailure(.timeout, "Native recording lost the device and it did not answer again within \(RecordingRecovery.linkWaitNanoseconds / 1_000_000_000) s, so the lost session's end could not be confirmed and no new one was opened. \(cleanup?.diagnostic ?? "")", inputSent: .none)
                            }
                            Thread.sleep(forTimeInterval: 1)
                        }
                    }
                    if count != 0 {
                        // Seen on the iPhone 13 mini after a pulled cable: the
                        // lost session was still running. Stop it by its own
                        // identifier, the stop that could not be sent before,
                        // and require that no session remains.
                        guard let identifier = lostIdentifier else {
                            throw CommandFailure(.preconditionChanged, "Native recording's lost session ended unconfirmed and the device still runs \(count!) media session(s) it cannot identify as its own, so no new one was opened; nothing was stopped.", inputSent: .none)
                        }
                        let stopped = NativeMediaFrames.stop(identifier: identifier, uuid: identity.uuid, version: identity.version)
                        guard stopped.ownedStreamAbsent else {
                            throw CommandFailure(.preconditionChanged, "Native recording stopped its lost session by identifier (acknowledged: \(stopped.stopAcknowledged)) but the device still runs a media session, so no new one was opened. \(stopped.diagnostic ?? "")", inputSent: .none)
                        }
                        stoppedByIdentifier = true
                    }
                    absenceByCount = true
                    closedCleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: (cleanup?.stopAcknowledged ?? false) || stoppedByIdentifier,
                        ownedStreamAbsent: true, diagnostic: stoppedByIdentifier
                            ? "The lost session was stopped by its identifier once the device answered again; no session remained."
                            : "The lost session's absence was read from the device's media session count (0).")
                    // The link may have come back on another address.
                    let fresh = try runner.run(input.identityPlan().arguments, timeout: 20)
                    assertion.close()
                    assertion = try NativeTunnelAssertion(device: command.device, details: fresh)
                    endpoint = try NativeMediaEndpoint.resolve(details: fresh, inventory: runner.run([
                        "devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"]), requested: command.device)
                }
                capture = try NativeMediaFrames(endpoint: endpoint, version: identity.version, plainOffer: display.external)
                try capture?.start(displayID: Int64(display.id))
                guard let again = capture?.packetProfile(), again["width"] == width, again["height"] == height, again["payloadType"] == payload else {
                    throw CommandFailure(.preconditionChanged, "A restarted native session negotiated another picture size or payload; the recording stops.", inputSent: .none)
                }
                decoder = try NativeHEVCDecoder(width: Int(width), height: Int(height))
                assembler = MediaHEVCAssembler()
            }
            /// Restarts after a loss when the bounds allow; false when the
            /// picture is to be held instead. A failure without a restart is
            /// thrown as it always was.
            func recover(_ reason: RecordingRecovery.Reason, _ error: (any Error)?) throws -> Bool {
                guard var state = recovery else {
                    if let error { throw error }
                    return false
                }
                defer { recovery = state }
                var lastError = error
                while true {
                    switch state.decide(reason, at: DispatchTime.now().uptimeNanoseconds) {
                    case .hold: return false
                    case .fail: throw lastError ?? CommandFailure(.transportFailed, "Native recording lost its stream (\(reason.rawValue)).", inputSent: .none)
                    case .restart:
                        do { try restartSession(); return true }
                        catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            // A changed stream, a session still running or a device that
                            // never came back: another attempt would meet the same.
                            if let failure = error as? CommandFailure, [.preconditionChanged, .timeout].contains(failure.code) { throw failure }
                            lastError = error
                        }
                    }
                }
            }
            func recoverable(_ error: any Error) -> Bool {
                recovery?.first != nil && !(error is CancellationError) && !Task.isCancelled
            }
            while true {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                if let first, now - first >= duration { break }
                if first == nil, now >= startup {
                    throw CommandFailure(.timeout, "Native recording exceeded its twelve-second first-frame budget.", inputSent: .none)
                }
                if let reason = recovery?.stall(at: now) {
                    _ = try recover(reason, nil)
                    continue
                }
                if now - checked >= 1_000_000_000, recovery?.heldFrom == nil {
                    do { try capture?.requireActive() }
                    catch where recoverable(error) {
                        _ = try recover(.streamEnded, error)
                        checked = DispatchTime.now().uptimeNanoseconds
                        continue
                    }
                    checked = DispatchTime.now().uptimeNanoseconds
                }
                // Sound from before the first picture is dropped: the movie
                // starts there.
                while sound != nil, let datagram = try capture?.nextAudioPacket() {
                    guard let first else { continue }
                    for piece in sound?.accept(datagram, nanoseconds: now - first) ?? [] where piece.nanoseconds < duration {
                        try await encoder.consumeAudio(piece.samples, nanoseconds: piece.nanoseconds)
                    }
                }
                let next: Data?
                do { next = recovery?.heldFrom == nil ? try capture?.nextPacket() : nil }
                catch where recoverable(error) {
                    _ = try recover(.transportFailed, error)
                    continue
                }
                if let packet = next {
                    recovery?.packet(at: now)
                    packetCount += 1
                    received += packet.count
                    guard received <= 1024 * 1024 * 1024 else {
                        throw CommandFailure(.transportFailed, "Native recording exceeded its one-GiB transport budget.", inputSent: .none)
                    }
                    if let packet = MediaRTPPacket(packet, payloadType: payloadType),
                        let unit = try assembler.accept(packet)
                    {
                        unitCount += 1
                        guard let pixels = try decoder?.decodePixels(unit, emit: first == nil || now - last >= 33_333_333, crop: crop)
                        else { continue }
                        decodedCount += 1
                        let time = DispatchTime.now().uptimeNanoseconds
                        if first == nil { first = time }
                        recovery?.picture(at: time)
                        guard let first, time - first < duration else { break }
                        try await encoder.consume(NativeVideoFrame(nanoseconds: time - first, pixels: pixels))
                        last = time
                    }
                } else {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            // A held picture means the stream was lost for good; its cleanup is still checked.
            if recovery?.heldFrom == nil { try capture?.requireActive() }
            let reportsSent = earlierReportsSent + (capture?.receiverReportsSent ?? 0)
            let reportsObserved = earlierReportsObserved + (capture?.senderReportsObserved ?? 0)
            guard let cleanup = closeMedia() ?? (recovery?.heldFrom != nil ? closedCleanup : nil) else {
                throw CommandFailure(.internal, "Native recording lost its media owner.", inputSent: .none)
            }
            let release = assertion.close()
            guard cleanup.stopAcknowledged || absenceByCount, cleanup.ownedStreamAbsent, release.confirmed else {
                throw CommandFailure(.transportFailed,
                        "Native recording cleanup unconfirmed: owned stop=\(cleanup.stopAcknowledged), stream absent=\(cleanup.ownedStreamAbsent), tunnel release=\(release.status). \(cleanup.diagnostic ?? "")",
                        inputSent: .none
                )
            }
            try Task.checkCancellation()
            let frames = try await encoder.finish()
            await sessions.end(endpoint.uuid)
            return NativeRecordingReceipt(frames: frames, media: cleanup, assertionRelease: release.status,
                receiverReportsSent: reportsSent,
                senderReportsObserved: reportsObserved,
                negotiatedFeedback: capture?.negotiatedFeedback ?? "unknown", audio: sound?.receipt, recovery: recovery)
        } catch {
            let cleanup = closeMedia() ?? closedCleanup
            let release = assertion.close()
            // A failure after pictures were captured keeps them: the movie ends
            // after its last picture and the result says it is partial. An
            // interrupt still discards it.
            if !(error is CancellationError), !Task.isCancelled, decodedCount > 0,
               let frames = try? await encoder.finish(partial: true) {
                await sessions.end(endpoint.uuid)
                return NativeRecordingReceipt(frames: frames,
                    media: cleanup ?? NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: nil),
                    assertionRelease: release.status, receiverReportsSent: earlierReportsSent, senderReportsObserved: earlierReportsObserved,
                    negotiatedFeedback: "unknown", recovery: recovery,
                    partial: "\(error) Capture: packets=\(packetCount), access units=\(unitCount), pixel frames=\(decodedCount).")
            }
            await encoder.cancel()
            await sessions.end(endpoint.uuid)
            var detail = "\(error) Capture: packets=\(packetCount), access units=\(unitCount), pixel frames=\(decodedCount). Cleanup: owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")"
            // A started stream that delivers nothing is what a firewall
            // dropping the incoming video looks like.
            var firewallDrops = false
            if packetCount == 0, !(error is CancellationError), !Task.isCancelled, let hint = HostFirewall.check().recordingHint {
                detail += " \(hint)"
                firewallDrops = true
            }
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("\(detail)\n".utf8))
                throw CancellationError()
            }
            throw CommandFailure.nativeRecording(detail, wrapping: error, firewallDropsVideo: firewallDrops)
        }
    }
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
