import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import Manzanero

/// The recording loop's own wiring, restarts included, against a scripted
/// stream and a clock that moves only when the stream or the loop's waits
/// move it (docs/recording-recovery.md#how-it-is-tested-before-a-device).
/// Nothing here sleeps: every wait advances the clock.
@MainActor struct NativeRecordingLoopTests {
    static let second: UInt64 = 1_000_000_000
    static let confirmed = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: true, ownedStreamAbsent: true, diagnostic: nil)
    /// The sound an iPhone 13 mini agrees on: AAC-ELD, 48 kHz stereo, 10 ms packets.
    static let sound = NativeMediaFrames.AudioProfile(payloadType: 101, streamIdentifier: 501, codecType: 0, sampleRate: 48_000,
                                                      channels: 2, packetMilliseconds: 10)
    /// A real 4 × 2 JPEG: `frames` reads each saved frame's size back.
    static let jpeg: Data = {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    @MainActor final class Clock {
        var now: UInt64 = 0
    }

    /// What a session does when the loop asks it for a packet at a time.
    /// `junk` is a new packet that decodes to nothing; `repeated` is the one
    /// packet an Apple TV with a still screen sends again, unchanged, once
    /// a second.
    enum Step { case picture, junk, repeated, silence }

    @MainActor final class ScriptedSession: NativeRecordingSession {
        let clock: Clock
        let opened: UInt64
        /// The step at a time since this session was opened.
        var script: (UInt64) -> Step = { _ in .picture }
        /// The device ends the stream at this time since the session was opened.
        var endsAfter: UInt64?
        var startError: (any Error)?
        var profile: [String: UInt64] = ["width": 4, "height": 2, "payloadType": 100]
        var cleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: true, ownedStreamAbsent: true, diagnostic: nil)
        private(set) var closed = false
        private var sequence: UInt16 = 1
        private var timestamp: UInt32 = 1
        private(set) var audioProfile: NativeMediaFrames.AudioProfile?
        /// The sound this session agrees on once its sound is started.
        var soundProfile = NativeRecordingLoopTests.sound
        var ownedIdentifier: UInt32?
        var ownedAudioIdentifier: UInt32?
        let receiverReportsSent: UInt64 = 2
        let senderReportsObserved: UInt64 = 1
        let negotiatedFeedback = "disabled"
        var audioReceiverReportsSent: UInt64 { audioProfile == nil ? 0 : 3 }
        let audioFeedbackNote: String? = nil
        private(set) var audioStarted = false
        /// The RTP timestamp of this session's first sound packet: a new
        /// session's sound has timestamps of its own.
        var soundBase: UInt32 = 7_000_000
        private var soundSent: UInt64 = 0

        init(clock: Clock) {
            self.clock = clock
            opened = clock.now
        }

        func startAudio() throws { audioStarted = true; audioProfile = soundProfile }
        func start(displayID: Int64) throws { if let startError { throw startError } }
        func packetProfile() -> [String: UInt64]? { profile }
        func requireActive() throws {
            if let endsAfter, clock.now - opened >= endsAfter {
                throw CommandFailure(.transportFailed, "The scripted stream ended.", inputSent: .none)
            }
        }
        /// One 10 ms packet of sound (payload type 101) for every 10 ms of the
        /// session's clock, until the stream ends. Its payload is not AAC, so
        /// each decodes to silence of its length: enough for the timeline.
        func nextAudioPacket() throws -> Data? {
            guard audioStarted else { return nil }
            let elapsed = clock.now - opened
            if let endsAfter, elapsed >= endsAfter { return nil }
            guard soundSent * 10_000_000 <= elapsed else { return nil }
            let stamp = soundBase &+ UInt32(soundSent * 480)
            soundSent += 1
            var bytes = Data([0x80, 101, UInt8(soundSent >> 8 & 255), UInt8(soundSent & 255)])
            for word in [stamp, 2] { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: word >> shift)) } }
            bytes.append(contentsOf: [0, 1, 2, 3])
            return bytes
        }
        func nextPacket() throws -> Data? {
            if let endsAfter, clock.now - opened >= endsAfter { return nil }
            switch script(clock.now - opened) {
            case .silence: return nil
            case .junk:
                // Video packets after a loss: dependent pictures with a gap
                // before each, which the assembler discards until a key frame.
                clock.now += 40_000_000
                sequence &+= 1
                var bytes = Data([0x80, 0xe4, UInt8(sequence >> 8), UInt8(sequence & 255)])
                for word in [timestamp, 1] { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: word >> shift)) } }
                bytes.append(Self.nal(1))
                sequence &+= 1
                timestamp &+= 3000
                return bytes
            case .repeated:
                clock.now += 1_000_000_000
                // Its own sequence (12 against the video's 53606) and not a
                // video packet: the live recording took it without failing.
                return Data([0x80, 0xfe, 0, 12, 0xc8, 0x3a, 0x5d, 0xb9, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 48))
            case .picture:
                clock.now += 40_000_000
                // A new session starts with its parameter sets and a key frame.
                let payload = sequence == 1
                    ? Self.aggregation(Self.sets + [Self.nal(19)])
                    : Self.nal(1)
                var bytes = Data([0x80, 0xe4, UInt8(sequence >> 8), UInt8(sequence & 255)])
                for word in [timestamp, 1] { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: word >> shift)) } }
                bytes.append(payload)
                sequence &+= 1
                timestamp &+= 3000
                return bytes
            }
        }
        func close() -> NativeMediaFrames.Cleanup {
            closed = true
            return cleanup
        }

        static func nal(_ type: UInt8) -> Data { Data([type << 1, 1, 7]) }
        static let sets = [nal(32), nal(33), nal(34)]
        static func aggregation(_ nals: [Data]) -> Data {
            var result = Data([96, 1])
            for nal in nals { result.append(contentsOf: [UInt8(nal.count >> 8), UInt8(nal.count & 255)]); result.append(nal) }
            return result
        }
    }

    /// Makes one small picture of every access unit.
    @MainActor final class PictureDecoder: NativeRecordingDecoder {
        let picture: CVReadOnlyPixelBuffer
        init() throws {
            picture = CVReadOnlyPixelBuffer(try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                                                         size: .init(width: 4, height: 2))))
        }
        func decodePixels(_ unit: MediaHEVCAccessUnit, emit: Bool, crop: (width: Int, height: Int)?) throws -> CVReadOnlyPixelBuffer? {
            emit ? picture : nil
        }
        func decodeFrameJPEG(_ unit: MediaHEVCAccessUnit, emit: Bool, crop: (width: Int, height: Int), quality: Double) throws -> Data? {
            emit ? NativeRecordingLoopTests.jpeg : nil
        }
        func close() {}
    }

    /// Counts what would be written, and checks it as the encoder does.
    actor Sink: NativeRecordingSink {
        private(set) var times: [UInt64] = []
        private(set) var finished: Bool?
        private(set) var cancelled = false
        func consume(_ frame: NativeVideoFrame) async throws {
            guard times.isEmpty ? frame.nanoseconds == 0 : frame.nanoseconds > times.last! else {
                throw CommandFailure(.internal, "Out of order: \(frame.nanoseconds)", inputSent: .none)
            }
            times.append(frame.nanoseconds)
        }
        /// Each sound piece's start and end, as the encoder would write them.
        private(set) var sound: [(start: UInt64, end: UInt64)] = []
        func consumeAudio(_ samples: [Int16], nanoseconds: UInt64) async throws {
            sound.append((nanoseconds, nanoseconds + NativeAudioTrack.nanoseconds(frames: UInt64(samples.count / 2))))
        }
        func finish(partial: Bool) async throws -> Int {
            finished = partial
            return times.count
        }
        func cancel() { cancelled = true }
    }

    /// The device as the loop sees it: one scripted session per open, in order.
    @MainActor final class Device {
        let clock = Clock()
        var plans: [(ScriptedSession) -> Void] = []
        private(set) var sessions: [ScriptedSession] = []
        var openError: [Int: any Error] = [:]
        var counts: [UInt64?] = []
        /// Every identifier a stop by identifier named, in order.
        private(set) var stopped: [UInt32] = []
        /// What a stop by identifier returns.
        var stopResult = NativeRecordingLoopTests.confirmed
        private(set) var relinks = 0
        private(set) var pauses = 0

        func link() -> NativeRecordingLink {
            NativeRecordingLink(
                open: { [self] in
                    if let error = openError[sessions.count] { throw error }
                    // Every earlier session is closed before the next opens.
                    guard sessions.allSatisfy(\.closed) else { throw CommandFailure(.internal, "A session was opened while another was open.", inputSent: .none) }
                    let session = ScriptedSession(clock: clock)
                    if sessions.count < plans.count { plans[sessions.count](session) }
                    sessions.append(session)
                    return session
                },
                decoder: { _, _ in try PictureDecoder() },
                sessionCount: { [self] in
                    guard !counts.isEmpty, let count = counts.removeFirst() else {
                        throw CommandFailure(.transportFailed, "The device does not answer.", inputSent: .none)
                    }
                    return count
                },
                stop: { [self] identifiers in
                    stopped += identifiers
                    return stopResult
                },
                relink: { [self] in relinks += 1 },
                release: { NativeTunnelAssertion.Release(confirmed: true, status: "released", diagnostic: nil) },
                now: { [clock] in clock.now },
                idle: { [clock] in clock.now += 5_000_000 },
                pause: { [self] in pauses += 1; clock.now += NativeRecordingLoopTests.second },
                firewallHint: { nil })
        }

        func record(seconds: Double, audio: Bool = false, sink: Sink) async throws -> NativeRecordingReceipt {
            try await NativeRecording.record(seconds: seconds, audio: audio, displayID: 1, crop: { _, _ in nil },
                                             encoder: sink, link: link())
        }

        /// `frames` into a fresh directory under ./tmp; returns the receipt
        /// and the index file as written.
        func frames(count: Int, seconds: Double?) async throws -> (receipt: [String: Any], index: [String: Any]) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/frames-loop-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let command = FramesCommand(device: "00008110-000A11112222801E", directory: directory, count: count, seconds: seconds,
                                        intervalMilliseconds: 0, overwrite: false)
            let result = try await NativeFrameCapture.capture(command, displayID: 1, link: link()) { _, _ in (4, 2) }
            let index = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(FramesCommand.indexName))) as? [String: Any]
            return (result.json, index ?? [:])
        }
    }

    @Test func framesRestartsAStreamThatEndsAndRecordsTheGapInItsIndex() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 4 * Self.second }]
        let (receipt, index) = try await device.frames(count: 1000, seconds: 10)
        #expect(device.sessions.count == 2 && device.sessions.allSatisfy(\.closed))
        #expect(receipt["status"] as? String == "captured" && receipt["stopReason"] as? String == "duration")
        let recovery = try #require(index["recovery"] as? [String: Any])
        #expect(recovery["restarts"] as? Int == 1)
        #expect((recovery["gaps"] as? [[String: Any]])?.first?["reason"] as? String == "stream-ended")
        #expect((receipt["frameCount"] as? Int ?? 0) > 100)
    }

    /// A count the stream can no longer reach: three restarts that deliver
    /// no picture, then the run ends instead of waiting for ever.
    @Test func framesEndsAStalledRunOnceNoRestartIsLeft() async throws {
        let device = Device()
        device.plans = [{ $0.script = { $0 < NativeRecordingLoopTests.second ? .picture : .junk } }]
            + Array(repeating: { $0.script = { _ in .junk } }, count: 3)
        let (receipt, index) = try await device.frames(count: 1000, seconds: nil)
        #expect(device.sessions.count == 4)
        #expect(receipt["status"] as? String == "captured" && receipt["stopReason"] as? String == "stream-stalled")
        #expect((index["recovery"] as? [String: Any])?["restarts"] as? Int == 3)
    }

    @Test func framesStopsAtTheFirstFailureBeforeAnyPictureWithoutARestart() async throws {
        let device = Device()
        device.plans = [{ $0.script = { _ in .silence }; $0.endsAfter = Self.second / 2 }]
        await #expect(throws: CommandFailure.self) { _ = try await device.frames(count: 10, seconds: nil) }
        #expect(device.sessions.count == 1 && device.sessions[0].closed)
    }

    /// An interrupt reaches an in-process recording as cancellation, so the
    /// loop stops its own stream; the backends that run Apple's tools are
    /// unchanged.
    @Test func anInProcessRecordingRunsUnderTheSignalScope() throws {
        let device = ["--device", "00008110-000A11112222801E"]
        #expect(try request(["record", "tmp/a.mp4", "60", "--backend", "coredevice"] + device).signalContext == "native recording")
        #expect(try request(["record", "tmp/a.mp4", "60"] + device).signalContext == nil)
        #expect(try request(["record", "tmp/a.mp4", "60", "--simulator", "11111111-2222-3333-4444-555555555555"]).signalContext == nil)
    }

    @Test func aStreamThatEndsAndComesBackLeavesOneGapInOneMovie() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 4 * Self.second }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        let recovery = try #require(receipt.recovery)
        #expect(device.sessions.count == 2 && device.sessions.allSatisfy(\.closed))
        #expect(recovery.restarts == 1 && recovery.heldFrom == nil)
        #expect(recovery.gaps.map(\.reason) == [.streamEnded])
        // A picture every 40 ms of the clock, and the loop writes one when
        // 33 ms have passed since the last it wrote, measured from the top
        // of a pass: every other one here, over ten seconds less the gap.
        #expect(receipt.partial == nil && receipt.frames > 110)
        #expect(await sink.finished == false)
        // Both sessions' reports add up.
        #expect(receipt.receiverReportsSent == 4 && receipt.senderReportsObserved == 2)
    }

    @Test func aStreamThatNeverComesBackUsesThreeRestartsThenKeepsWhatWasCaptured() async throws {
        let device = Device()
        let refused = CommandFailure(.transportFailed, "The scripted session did not start.", inputSent: .none)
        device.plans = [{ $0.endsAfter = 3 * Self.second }] + Array(repeating: { $0.startError = refused }, count: 3)
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        #expect(device.sessions.count == 4)
        #expect(receipt.recovery?.restarts == 3)
        #expect(receipt.partial?.contains("did not start") == true)
        #expect(await sink.finished == true)
    }

    @Test func aStallWithTooLittleTimeLeftHoldsTheLastPicture() async throws {
        let device = Device()
        // Pictures for 4.5 s, then packets that decode to nothing: the stall
        // is seen at 7.5 s, with less than 2 s of the 8 left.
        device.plans = [{ $0.script = { $0 < 4_500_000_000 ? .picture : .junk } }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 8, sink: sink)
        let recovery = try #require(receipt.recovery)
        #expect(device.sessions.count == 1 && recovery.restarts == 0)
        let held = try #require(recovery.heldFrom)
        #expect(held > 4.3 && held < 4.5)
        #expect(receipt.partial == nil && receipt.media.ownedStreamAbsent)
        #expect(await sink.finished == false)
    }

    /// The Apple TV 4K on 2026-11-21: a still screen sends pictures for
    /// about five seconds, then only one unchanged packet once a second. That
    /// is a quiet session, not a lost one: no restart, nothing held.
    @Test func aStillAppleTVScreenWithOneRepeatedPacketIsNotRestarted() async throws {
        let device = Device()
        device.plans = [{ $0.script = { $0 < 5 * NativeRecordingLoopTests.second ? .picture : .repeated } }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 30, sink: sink)
        let recovery = try #require(receipt.recovery)
        #expect(device.sessions.count == 1 && recovery.restarts == 0 && recovery.gaps.isEmpty && recovery.heldFrom == nil)
        #expect(receipt.partial == nil, "\(receipt.partial ?? "")")
        #expect(receipt.frames > 50, "\(receipt.frames)")
    }

    /// The human owner's decision of 2026-11-22: an interrupted recording
    /// keeps what it captured, as `frames` keeps its frames.
    @Test func cancellationDuringARestartKeepsTheMovieAsInterrupted() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 3 * Self.second }]
        device.openError = [1: CancellationError()]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        #expect(device.sessions.count == 1 && device.sessions[0].closed)
        #expect(receipt.interrupted && receipt.stopCause == "interrupted")
        #expect(receipt.partial?.hasPrefix("Interrupted.") == true)
        #expect(receipt.frames > 30)
        #expect(await sink.finished == true)
        #expect(await !sink.cancelled)
    }

    /// Nothing captured, nothing to keep: the interrupt goes through.
    @Test func cancellationBeforeTheFirstPictureDiscardsTheMovie() async throws {
        let device = Device()
        device.plans = [{ $0.startError = CancellationError() }]
        let sink = Sink()
        await #expect(throws: CancellationError.self) { try await device.record(seconds: 10, sink: sink) }
        #expect(await sink.cancelled)
        #expect(await sink.finished == nil)
    }

    /// The lost session's end was confirmed and a session still runs: it is
    /// another client's. The recording ends with that reason and opens
    /// nothing (the human owner's decision of 2026-11-22: no wait).
    @Test func anotherViewerAfterAConfirmedStopEndsTheRecordingWithItsCause() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 3 * Self.second }]
        device.counts = [1]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        #expect(device.sessions.count == 1 && device.stopped.isEmpty)
        #expect(receipt.stopCause == "another-viewer" && !receipt.interrupted)
        #expect(receipt.partial?.contains("Another viewer took the device's screen") == true)
        #expect(receipt.recovery?.restarts == 1)
        #expect(await sink.finished == true)
    }

    /// As seen twice on the iPhone 13 mini on 2026-11-21 with Device Hub:
    /// the stop could not be confirmed, the stop by identifier is not
    /// acknowledged and a session still runs. One attempt, no retry.
    @Test func anotherViewerAfterAnUnconfirmedStopEndsTheRecordingWithoutARetry() async throws {
        let device = Device()
        device.plans = [{
            $0.endsAfter = 3 * Self.second
            $0.ownedIdentifier = 7
            $0.cleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: "ended")
        }]
        device.counts = [1]
        device.stopResult = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: "not acknowledged")
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        #expect(device.sessions.count == 1 && device.stopped == [7])
        #expect(receipt.stopCause == "another-viewer")
        #expect(receipt.recovery?.restarts == 1)
    }

    @Test func aChangedPictureSizeAfterARestartEndsTheRecording() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 3 * Self.second }, { $0.profile = ["width": 8, "height": 2, "payloadType": 100] }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, sink: sink)
        #expect(device.sessions.count == 2 && receipt.recovery?.restarts == 1)
        #expect(receipt.partial?.contains("another picture size") == true)
        #expect(await sink.finished == true)
    }

    @Test func aLossBeforeTheFirstPictureFailsWithoutARestart() async throws {
        let device = Device()
        device.plans = [{ $0.script = { _ in .silence }; $0.endsAfter = Self.second / 2 }]
        let sink = Sink()
        await #expect(throws: CommandFailure.self) { try await device.record(seconds: 10, sink: sink) }
        #expect(device.sessions.count == 1 && device.sessions[0].closed)
        #expect(await sink.cancelled)
        #expect(await sink.finished == nil)
    }

    @Test func aLostLinkWaitsForTheDeviceAndStopsItsOwnSessionByIdentifier() async throws {
        let device = Device()
        device.plans = [{
            $0.endsAfter = 3 * Self.second
            $0.ownedIdentifier = 7
            // The cable is out: the stop cannot be confirmed.
            $0.cleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: "unreachable")
        }]
        // Two looks with no answer, then the lost session still running.
        device.counts = [nil, nil, 1]
        let sink = Sink()
        let receipt = try await device.record(seconds: 12, sink: sink)
        #expect(device.pauses == 2 && device.stopped == [7] && device.relinks == 1)
        #expect(device.sessions.count == 2 && receipt.recovery?.restarts == 1 && receipt.partial == nil)
        #expect(receipt.media.stopAcknowledged && receipt.media.ownedStreamAbsent)
    }

    @Test func aDeviceThatNeverAnswersAgainEndsTheRecordingAfterThirtySeconds() async throws {
        let device = Device()
        device.plans = [{
            $0.endsAfter = 3 * Self.second
            $0.ownedIdentifier = 7
            $0.cleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: "unreachable")
        }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 60, sink: sink)
        #expect(device.pauses == 30 && device.stopped.isEmpty && device.relinks == 0)
        #expect(device.sessions.count == 1)
        #expect(receipt.partial?.contains("did not answer again") == true)
    }

    /// Since 2026-11-22 a recording with sound restarts too: the new session
    /// starts its sound before its video, and the sound track starts a new
    /// timeline at the new stream's first packet, after a gap and never
    /// overlapping what was written.
    @Test func aStreamWithSoundThatEndsAndComesBackRestartsItsSound() async throws {
        let device = Device()
        device.plans = [{ $0.endsAfter = 3 * Self.second }, { $0.soundBase = 900_000_000 }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, audio: true, sink: sink)
        #expect(device.sessions.count == 2 && device.sessions.allSatisfy { $0.closed && $0.audioStarted })
        #expect(receipt.partial == nil && receipt.recovery?.restarts == 1)
        let audio = try #require(receipt.audio)
        #expect(audio.restarts == 1 && audio.receiverReportsSent == 6)
        let pieces = await sink.sound
        #expect(pieces.count > 500)
        // In order and never overlapping across the restart (the scripted
        // loss is seen within milliseconds, so the new timeline starts where
        // the old one ended), and sound from both sessions to the end.
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(pieces.contains { $0.start > 4 * Self.second } && pieces.contains { $0.start < 2 * Self.second })
        #expect((pieces.last?.end ?? 0) > 9 * Self.second)
    }

    @Test func aRestartWithOtherSoundEndsTheRecording() async throws {
        let device = Device()
        let other = NativeMediaFrames.AudioProfile(payloadType: 101, streamIdentifier: 502, codecType: 0, sampleRate: 44_100,
                                                   channels: 2, packetMilliseconds: 10)
        device.plans = [{ $0.endsAfter = 3 * Self.second }, { $0.soundProfile = other }]
        let sink = Sink()
        let receipt = try await device.record(seconds: 10, audio: true, sink: sink)
        #expect(device.sessions.count == 2)
        #expect(receipt.partial?.contains("other sound") == true)
        #expect(await sink.finished == true)
    }

    /// A lost link with sound: once the device answers again, the lost
    /// session's video and sound are stopped by their identifiers together.
    @Test func aLostLinkWithSoundStopsBothStreamsByIdentifier() async throws {
        let device = Device()
        device.plans = [{
            $0.endsAfter = 3 * Self.second
            $0.ownedIdentifier = 7
            $0.ownedAudioIdentifier = 8
            $0.cleanup = NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: "unreachable")
        }]
        device.counts = [nil, 2]
        let sink = Sink()
        let receipt = try await device.record(seconds: 12, audio: true, sink: sink)
        #expect(device.stopped == [7, 8] && device.relinks == 1)
        #expect(device.sessions.count == 2 && receipt.recovery?.restarts == 1 && receipt.partial == nil)
        #expect(receipt.audio?.restarts == 1)
    }
}
