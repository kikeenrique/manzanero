import CoreVideo
import Foundation

/// What the recording loop uses of one media session: `NativeMediaFrames`
/// on a device, a scripted stream in the tests.
@MainActor protocol NativeRecordingSession: AnyObject {
    var audioProfile: NativeMediaFrames.AudioProfile? { get }
    var ownedIdentifier: UInt32? { get }
    var receiverReportsSent: UInt64 { get }
    var senderReportsObserved: UInt64 { get }
    var negotiatedFeedback: String { get }
    func startAudio() throws
    func start(displayID: Int64) throws
    func packetProfile() -> [String: UInt64]?
    func requireActive() throws
    func nextPacket() throws -> Data?
    func nextAudioPacket() throws -> Data?
    @discardableResult func close() -> NativeMediaFrames.Cleanup
}

extension NativeMediaFrames: NativeRecordingSession {}

/// What the recording loop uses of a decoder: `NativeHEVCDecoder`, or one
/// that makes a picture of every access unit in the tests.
@MainActor protocol NativeRecordingDecoder: AnyObject {
    func decodePixels(_ unit: MediaHEVCAccessUnit, emit: Bool, crop: (width: Int, height: Int)?) throws -> CVReadOnlyPixelBuffer?
    func close()
}

extension NativeHEVCDecoder: NativeRecordingDecoder {}

/// Where the recording loop writes: `NativeVideoEncoder`, or a counter in
/// the tests.
protocol NativeRecordingSink: Actor {
    func consume(_ frame: NativeVideoFrame) async throws
    func consumeAudio(_ samples: [Int16], nanoseconds: UInt64) async throws
    func finish(partial: Bool) async throws -> Int
    func cancel()
}

extension NativeVideoEncoder: NativeRecordingSink {}

/// Everything the recording loop does to the device and to time, so that
/// a test can run the loop, restarts included, against a scripted stream
/// and a clock of its own (docs/recording-recovery.md#how-it-is-tested-before-a-device).
@MainActor struct NativeRecordingLink {
    /// A new media session on the current endpoint, not yet started.
    var open: () throws -> any NativeRecordingSession
    var decoder: (_ width: Int, _ height: Int) throws -> any NativeRecordingDecoder
    /// How many media sessions the device runs (read-only, a fresh connection).
    var sessionCount: () throws -> UInt64
    /// Stops a lost session by the identifier it was given at its start.
    var stop: (_ identifier: UInt32) -> NativeMediaFrames.Cleanup
    /// Fresh device details, tunnel assertion and endpoint after a lost link:
    /// the device's address can change when its cable comes back.
    var relink: () throws -> Void
    /// Releases the tunnel assertion.
    var release: () -> NativeTunnelAssertion.Release
    /// Host time in nanoseconds.
    var now: () -> UInt64
    /// The wait when no packet is ready.
    var idle: () async throws -> Void
    /// The wait between two looks for a device that stopped answering.
    var pause: () -> Void
    /// What to add to the failure of a started stream that delivered nothing.
    var firewallHint: () -> String?
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
        let reserved = endpoint.uuid
        try await sessions.begin(reserved)
        let link = NativeRecordingLink(
            open: { try NativeMediaFrames(endpoint: endpoint, version: identity.version, plainOffer: display.external) },
            decoder: { try NativeHEVCDecoder(width: $0, height: $1) },
            sessionCount: { try NativeMediaInspection.sessionCount(uuid: identity.uuid, version: identity.version) },
            stop: { NativeMediaFrames.stop(identifier: $0, uuid: identity.uuid, version: identity.version) },
            relink: {
                let fresh = try runner.run(input.identityPlan().arguments, timeout: 20)
                assertion.close()
                assertion = try NativeTunnelAssertion(device: command.device, details: fresh)
                endpoint = try NativeMediaEndpoint.resolve(details: fresh, inventory: runner.run([
                    "devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"]), requested: command.device)
            },
            release: { assertion.close() },
            now: { DispatchTime.now().uptimeNanoseconds },
            idle: { try await Task.sleep(for: .milliseconds(2)) },
            pause: { Thread.sleep(forTimeInterval: 1) },
            firewallHint: { HostFirewall.check().recordingHint })
        // An Apple TV's screen fills the stream's width and leaves black
        // rows below it, which `frames` drops too. A phone's movie keeps
        // the whole picture, as it always has.
        let crop: (Int, Int) -> (width: Int, height: Int)? = { width, height in
            display.external ? FramesCommand.visibleSize(display: display, stream: (width, height)) : nil
        }
        do {
            let receipt = try await record(seconds: command.seconds, audio: command.audio, displayID: Int64(display.id),
                                           crop: crop, encoder: encoder, link: link)
            await sessions.end(reserved)
            return receipt
        } catch {
            await sessions.end(reserved)
            throw error
        }
    }

    /// The capture loop: one media session after another on the same
    /// endpoint, as recovery allows, written to `encoder` for `seconds` from
    /// the first picture. Every effect on the device and every reading of
    /// the clock goes through `link`.
    static func record(seconds: Double, audio: Bool, displayID: Int64, crop: (Int, Int) -> (width: Int, height: Int)?,
                       encoder: any NativeRecordingSink, link: NativeRecordingLink) async throws -> NativeRecordingReceipt {
        var capture: (any NativeRecordingSession)?
        var decoder: (any NativeRecordingDecoder)?
        var packetCount = 0
        var unitCount = 0
        var decodedCount = 0
        func closeMedia() -> NativeMediaFrames.Cleanup? {
            decoder?.close()
            return capture?.close()
        }
        let duration = UInt64(seconds * 1_000_000_000)
        // A lost session after the first picture is restarted on the same
        // endpoint (docs/recording-recovery.md). With --audio there is no
        // restart: the sound stream's restart has not been checked.
        var recovery = audio ? nil : RecordingRecovery(durationNanoseconds: duration)
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
            capture = try link.open()
            // The device's sound is a second stream, started before the
            // video as Apple's Device Hub starts it. With --audio a failure
            // to start it fails the recording: there is no silent fallback.
            var sound: NativeAudioTrack?
            if audio {
                try capture?.startAudio()
                guard let agreed = capture?.audioProfile else {
                    throw CommandFailure(.transportFailed, "Native recording has no negotiated audio profile.", inputSent: .none)
                }
                sound = try NativeAudioTrack(profile: agreed)
            }
            try capture?.start(displayID: displayID)
            guard let profile = capture?.packetProfile(), let width = profile["width"], let height = profile["height"],
                let payload = profile["payloadType"], let payloadType = UInt8(exactly: payload)
            else {
                throw CommandFailure(.transportFailed, "Native recording has no negotiated video profile.", inputSent: .none)
            }
            decoder = try link.decoder(Int(width), Int(height))
            let cropped = crop(Int(width), Int(height))
            var assembler = MediaHEVCAssembler()
            let startup = link.now() + 12_000_000_000
            var first: UInt64?
            var last: UInt64 = 0
            var checked = link.now()
            var received = 0
            /// The last video packet's sequence number and timestamp. Only a
            /// new video packet counts as traffic for the stall "packets and
            /// no picture". An Apple TV with a still screen sends no new
            /// picture after about five seconds and repeats one 48-byte
            /// packet, unchanged, once a second (the Apple TV 4K, 2026-11-21);
            /// counted as traffic, the repeats and the datagrams between them
            /// made that a stall and restarted a healthy session.
            var lastPacketKey: Data?
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
                    let deadline = link.now() + RecordingRecovery.linkWaitNanoseconds
                    var count: UInt64?
                    while count == nil {
                        try Task.checkCancellation()
                        count = try? link.sessionCount()
                        if count == nil {
                            guard link.now() < deadline else {
                                throw CommandFailure(.timeout, "Native recording lost the device and it did not answer again within \(RecordingRecovery.linkWaitNanoseconds / 1_000_000_000) s, so the lost session's end could not be confirmed and no new one was opened. \(cleanup?.diagnostic ?? "")", inputSent: .none)
                            }
                            link.pause()
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
                        let stopped = link.stop(identifier)
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
                    try link.relink()
                }
                capture = try link.open()
                try capture?.start(displayID: displayID)
                guard let again = capture?.packetProfile(), again["width"] == width, again["height"] == height, again["payloadType"] == payload else {
                    throw CommandFailure(.preconditionChanged, "A restarted native session negotiated another picture size or payload; the recording stops.", inputSent: .none)
                }
                decoder = try link.decoder(Int(width), Int(height))
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
                    switch state.decide(reason, at: link.now()) {
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
                let now = link.now()
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
                        checked = link.now()
                        continue
                    }
                    checked = link.now()
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
                    packetCount += 1
                    received += packet.count
                    guard received <= 1024 * 1024 * 1024 else {
                        throw CommandFailure(.transportFailed, "Native recording exceeded its one-GiB transport budget.", inputSent: .none)
                    }
                    let video = MediaRTPPacket(packet, payloadType: payloadType)
                    if video != nil {
                        let key = packet.subdata(in: 2..<8)
                        if key != lastPacketKey { recovery?.packet(at: now) }
                        lastPacketKey = key
                    }
                    if let video, let unit = try assembler.accept(video) {
                        unitCount += 1
                        guard let pixels = try decoder?.decodePixels(unit, emit: first == nil || now - last >= 33_333_333, crop: cropped)
                        else { continue }
                        decodedCount += 1
                        let time = link.now()
                        if first == nil { first = time }
                        recovery?.picture(at: time)
                        guard let first, time - first < duration else { break }
                        try await encoder.consume(NativeVideoFrame(nanoseconds: time - first, pixels: pixels))
                        last = time
                    }
                } else {
                    try await link.idle()
                }
            }
            // A held picture means the stream was lost for good; its cleanup is still checked.
            if recovery?.heldFrom == nil { try capture?.requireActive() }
            let reportsSent = earlierReportsSent + (capture?.receiverReportsSent ?? 0)
            let reportsObserved = earlierReportsObserved + (capture?.senderReportsObserved ?? 0)
            guard let cleanup = closeMedia() ?? (recovery?.heldFrom != nil ? closedCleanup : nil) else {
                throw CommandFailure(.internal, "Native recording lost its media owner.", inputSent: .none)
            }
            let release = link.release()
            guard cleanup.stopAcknowledged || absenceByCount, cleanup.ownedStreamAbsent, release.confirmed else {
                throw CommandFailure(.transportFailed,
                        "Native recording cleanup unconfirmed: owned stop=\(cleanup.stopAcknowledged), stream absent=\(cleanup.ownedStreamAbsent), tunnel release=\(release.status). \(cleanup.diagnostic ?? "")",
                        inputSent: .none
                )
            }
            try Task.checkCancellation()
            let frames = try await encoder.finish(partial: false)
            return NativeRecordingReceipt(frames: frames, media: cleanup, assertionRelease: release.status,
                receiverReportsSent: reportsSent,
                senderReportsObserved: reportsObserved,
                negotiatedFeedback: capture?.negotiatedFeedback ?? "unknown", audio: sound?.receipt, recovery: recovery)
        } catch {
            let cleanup = closeMedia() ?? closedCleanup
            let release = link.release()
            // A failure after pictures were captured keeps them: the movie ends
            // after its last picture and the result says it is partial. An
            // interrupt still discards it.
            if !(error is CancellationError), !Task.isCancelled, decodedCount > 0,
               let frames = try? await encoder.finish(partial: true) {
                return NativeRecordingReceipt(frames: frames,
                    media: cleanup ?? NativeMediaFrames.Cleanup(startAttempted: true, stopAcknowledged: false, ownedStreamAbsent: false, diagnostic: nil),
                    assertionRelease: release.status, receiverReportsSent: earlierReportsSent, senderReportsObserved: earlierReportsObserved,
                    negotiatedFeedback: "unknown", recovery: recovery,
                    partial: "\(error) Capture: packets=\(packetCount), access units=\(unitCount), pixel frames=\(decodedCount).")
            }
            await encoder.cancel()
            var detail = "\(error) Capture: packets=\(packetCount), access units=\(unitCount), pixel frames=\(decodedCount). Cleanup: owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")"
            // A started stream that delivers nothing is what a firewall
            // dropping the incoming video looks like.
            var firewallDrops = false
            if packetCount == 0, !(error is CancellationError), !Task.isCancelled, let hint = link.firewallHint() {
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
