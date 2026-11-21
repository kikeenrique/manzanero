import Foundation

/// Runs `frames` on a physical device: one owned native video session (the
/// standard-RTP mode native recording uses), HEVC decoded with VideoToolbox,
/// each saved frame encoded as JPEG, then the same owned cleanup as recording.
/// A session lost after the first picture is restarted as a recording's is
/// (`NativeStreamSessions`, docs/recording-recovery.md#frames).
///
/// Apple's own decoder output (`AVCStreamOutput`) is not an option: its
/// access check admits only the process names in AVConference's
/// AVCStreamOutputAccess.plist, and manzanero is not one of them. The bridge
/// mode built on it was removed (docs/recording.md).
@MainActor enum NativeFrameCapture {
    /// JPEG quality of saved frames.
    static let quality = 0.85

    static func execute(_ command: FramesCommand, runner: ToolRunner) async throws -> Data {
        let begun = DispatchTime.now().uptimeNanoseconds
        let (link, reserved, display) = try NativeRecordingLink.device(command.device, operation: "frames", runner: runner)
        defer { _ = link.release() }
        try await NativeRecordingSessions.shared.begin(reserved)
        do {
            var result = try await capture(command, displayID: Int64(display.id), link: link) {
                FramesCommand.visibleSize(display: display, stream: ($0, $1))
            }
            await NativeRecordingSessions.shared.end(reserved)
            // Identity, tunnel and display queries before the stream request.
            result.stream["displayRotation"] = display.rotation
            result.json["stream"] = result.stream
            result.json["setupMilliseconds"] = FrameRun.decimal(Double(result.started - begun) / 1_000_000)
            return try JSONSerialization.data(withJSONObject: result.json, options: [.prettyPrinted, .sortedKeys])
        } catch {
            await NativeRecordingSessions.shared.end(reserved)
            throw error
        }
    }

    /// The capture loop, every effect on the device and every reading of the
    /// clock through `link`. Returns the receipt without the display's
    /// rotation and the setup time, which `execute` adds.
    static func capture(_ command: FramesCommand, displayID: Int64, link: NativeRecordingLink,
                        crop: (Int, Int) -> (width: Int, height: Int)) async throws
        -> (json: [String: Any], stream: [String: Any], started: UInt64)
    {
        let media = NativeStreamSessions(link: link, displayID: displayID)
        var run = FrameRun(command: command, started: link.now())
        var packets = 0, units = 0
        // The stream as it arrived, kept beside the frames when asked for.
        var dump: NativeStreamDump? = NativeStreamDump.requested ? NativeStreamDump() : nil
        defer { try? dump?.write(to: command.directory) }
        // Bounded as a recording is: a run without --seconds counts as the
        // longest one, for the rule that no restart begins near the end.
        var recovery: RecordingRecovery? = RecordingRecovery(
            durationNanoseconds: UInt64((command.seconds ?? FramesCommand.secondsRange.upperBound) * 1_000_000_000))
        do {
            try media.open().start(displayID: displayID)
            let payloadType = try media.negotiate()
            let size = crop(Int(media.width), Int(media.height))
            let startup = link.now() + UInt64(FramesCommand.firstFrameBudgetSeconds) * 1_000_000_000
            var checked = link.now()
            var received = 0
            var reason: FrameRun.StopReason?
            func recoverable(_ error: any Error) -> Bool {
                recovery?.first != nil && !(error is CancellationError) && !Task.isCancelled
            }
            while reason == nil {
                try Task.checkCancellation()
                let now = link.now()
                if let stop = run.stopReason(at: now) { reason = stop; break }
                if run.first == nil, now >= startup {
                    throw CommandFailure(.timeout, "No frame arrived within the \(FramesCommand.firstFrameBudgetSeconds)-second first-frame budget.", inputSent: .none)
                }
                // With no restart left, a stall ends the run: a count that
                // cannot be reached would otherwise keep it open for ever.
                if let stall = recovery?.stall(at: now) {
                    if try !media.recover(stall, nil, &recovery) { reason = .streamStalled }
                    continue
                }
                if now - checked >= 1_000_000_000 {
                    do { try media.capture?.requireActive() }
                    catch where recoverable(error) {
                        _ = try media.recover(.streamEnded, error, &recovery)
                        checked = link.now()
                        continue
                    }
                    checked = link.now()
                }
                let next: Data?
                do { next = try media.capture?.nextPacket() }
                catch where recoverable(error) {
                    _ = try media.recover(.transportFailed, error, &recovery)
                    continue
                }
                guard let packet = next else {
                    try await link.idle()
                    continue
                }
                packets += 1
                dump?.packet(packet)
                received += packet.count
                guard received <= 1024 * 1024 * 1024 else {
                    throw CommandFailure(.transportFailed, "Frame capture exceeded its one-GiB transport budget.", inputSent: .none)
                }
                guard let rtp = MediaRTPPacket(packet, payloadType: payloadType) else { continue }
                if media.isNewVideoPacket(packet) { recovery?.packet(at: now) }
                guard let unit = try media.assembler.accept(rtp) else { continue }
                units += 1
                dump?.unit(unit)
                // A complete access unit is a picture for recovery: only the
                // frames to be saved are decoded to JPEG, so with a long
                // --interval a decoded picture would be seen too seldom.
                recovery?.picture(at: link.now())
                // Every unit is decoded to keep reference pictures; only a frame
                // that will be saved is encoded as JPEG.
                let wanted = run.wants(at: link.now())
                guard let jpeg = try media.decoder?.decodeFrameJPEG(unit, emit: wanted, crop: size, quality: quality) else { continue }
                reason = try run.save(jpeg, at: link.now())
            }
            // A stalled stream was lost for good; its cleanup is still checked.
            if reason != .streamStalled { try media.capture?.requireActive() }
            let cleanup = media.close() ?? media.closedCleanup
            let release = link.release()
            guard let cleanup, cleanup.stopAcknowledged || media.absenceByCount, cleanup.ownedStreamAbsent, release.confirmed else {
                try? run.writeIndex(status: "cleanup-unconfirmed", stopReason: reason, recovery: recovery)
                throw CommandFailure(.transportFailed,
                    "Frame capture cleanup unconfirmed after \(run.entries.count) frames in \(command.directory.path): owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")",
                    inputSent: .none)
            }
            try run.writeIndex(status: "captured", stopReason: reason, recovery: recovery)
            var result = run.summary(status: "captured", stopReason: reason, recovery: recovery)
            result["backend"] = "coredevice-videotoolbox"
            let stream: [String: Any] = ["width": media.width, "height": media.height, "packets": packets, "accessUnits": units,
                                         "savedWidth": size.width, "savedHeight": size.height]
            result["jpegQuality"] = NSDecimalNumber(string: String(quality))
            result["cleanup"] = ["ownedStopAcknowledged": cleanup.stopAcknowledged, "ownedStreamAbsent": cleanup.ownedStreamAbsent,
                                 "tunnelAssertionRelease": release.status] as [String: Any]
            return (result, stream, run.started)
        } catch {
            let cleanup = media.close() ?? media.closedCleanup
            let release = link.release()
            let interrupted = error is CancellationError || Task.isCancelled
            try? run.writeIndex(status: interrupted ? "interrupted" : "failed", stopReason: interrupted ? .interrupted : nil, recovery: recovery)
            var detail = "\(run.entries.count) frames written to \(command.directory.path) (index \(FramesCommand.indexName)). Stream: packets=\(packets), access units=\(units). Cleanup: start attempted=\(cleanup?.startAttempted ?? false), owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")"
            if interrupted {
                FileHandle.standardError.write(Data("Frame capture interrupted: \(detail)\n".utf8))
                throw CancellationError()
            }
            // A started stream that delivers nothing is what a firewall
            // dropping the incoming video looks like.
            var firewallDrops = false
            if packets == 0, let hint = link.firewallHint() {
                detail += " \(hint)"
                firewallDrops = true
            }
            throw CommandFailure.nativeRecording("Frame capture failed: \(error) \(detail)", wrapping: error, firewallDropsVideo: firewallDrops)
        }
    }
}
