import Foundation

/// Runs `frames` on a physical device: one owned native video session (the
/// standard-RTP mode native recording uses), HEVC decoded with VideoToolbox,
/// each saved frame encoded as JPEG, then the same owned cleanup as recording.
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
        let input = CoreDeviceInput(device: command.device, operation: "frames", operands: [])
        let details = try runner.run(input.identityPlan().arguments, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        let assertion = try NativeTunnelAssertion(device: command.device, details: details)
        defer { assertion.close() }
        let inventory = try runner.run(["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-", "--quiet"])
        let endpoint = try NativeMediaEndpoint.resolve(details: details, inventory: inventory, requested: command.device)
        let display = try DirectTouchDisplay(runner.run(AccessibilityDisplay.plan(device: identity.uuid).arguments, timeout: 15), capture: true)
        try await NativeRecordingSessions.shared.begin(endpoint.uuid)
        var capture: NativeMediaFrames?
        var decoder: NativeHEVCDecoder?
        var run = FrameRun(command: command, started: DispatchTime.now().uptimeNanoseconds)
        var packets = 0, units = 0
        func closeMedia() -> NativeMediaFrames.Cleanup? {
            decoder?.close()
            return capture?.close()
        }
        do {
            capture = try NativeMediaFrames(endpoint: endpoint, version: identity.version)
            try capture?.start(displayID: Int64(display.id))
            guard let profile = capture?.packetProfile(), let width = profile["width"], let height = profile["height"],
                  let payload = profile["payloadType"], let payloadType = UInt8(exactly: payload) else {
                throw CommandFailure(.transportFailed, "The native stream has no negotiated video profile.", inputSent: .none)
            }
            decoder = try NativeHEVCDecoder(width: Int(width), height: Int(height))
            let crop = FramesCommand.visibleSize(display: display, stream: (Int(width), Int(height)))
            var assembler = MediaHEVCAssembler()
            let startup = DispatchTime.now().uptimeNanoseconds + UInt64(FramesCommand.firstFrameBudgetSeconds) * 1_000_000_000
            var checked = DispatchTime.now().uptimeNanoseconds
            var received = 0
            var reason: FrameRun.StopReason?
            while reason == nil {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                if let stop = run.stopReason(at: now) { reason = stop; break }
                if run.first == nil, now >= startup {
                    throw CommandFailure(.timeout, "No frame arrived within the \(FramesCommand.firstFrameBudgetSeconds)-second first-frame budget.", inputSent: .none)
                }
                if now - checked >= 1_000_000_000 {
                    try capture?.requireActive()
                    checked = DispatchTime.now().uptimeNanoseconds
                }
                guard let packet = try capture?.nextPacket() else {
                    try await Task.sleep(for: .milliseconds(2))
                    continue
                }
                packets += 1
                received += packet.count
                guard received <= 1024 * 1024 * 1024 else {
                    throw CommandFailure(.transportFailed, "Frame capture exceeded its one-GiB transport budget.", inputSent: .none)
                }
                guard let rtp = MediaRTPPacket(packet, payloadType: payloadType), let unit = try assembler.accept(rtp) else { continue }
                units += 1
                // Every unit is decoded to keep reference pictures; only a frame
                // that will be saved is encoded as JPEG.
                let wanted = run.wants(at: DispatchTime.now().uptimeNanoseconds)
                guard let jpeg = try decoder?.decodeFrameJPEG(unit, emit: wanted, crop: crop, quality: quality) else { continue }
                reason = try run.save(jpeg, at: DispatchTime.now().uptimeNanoseconds)
            }
            try capture?.requireActive()
            let cleanup = closeMedia()
            let release = assertion.close()
            await NativeRecordingSessions.shared.end(endpoint.uuid)
            guard let cleanup, cleanup.stopAcknowledged, cleanup.ownedStreamAbsent, release.confirmed else {
                try? run.writeIndex(status: "cleanup-unconfirmed", stopReason: reason)
                throw CommandFailure(.transportFailed,
                    "Frame capture cleanup unconfirmed after \(run.entries.count) frames in \(command.directory.path): owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")",
                    inputSent: .none)
            }
            try run.writeIndex(status: "captured", stopReason: reason)
            var result = run.summary(status: "captured", stopReason: reason)
            result["backend"] = "coredevice-videotoolbox"
            result["stream"] = ["width": width, "height": height, "packets": packets, "accessUnits": units,
                                "displayRotation": display.rotation, "savedWidth": crop.width, "savedHeight": crop.height] as [String: Any]
            result["jpegQuality"] = NSDecimalNumber(string: String(quality))
            // Identity, tunnel and display queries before the stream request.
            result["setupMilliseconds"] = FrameRun.decimal(Double(run.started - begun) / 1_000_000)
            result["cleanup"] = ["ownedStopAcknowledged": cleanup.stopAcknowledged, "ownedStreamAbsent": cleanup.ownedStreamAbsent,
                                 "tunnelAssertionRelease": release.status] as [String: Any]
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let cleanup = closeMedia()
            let release = assertion.close()
            await NativeRecordingSessions.shared.end(endpoint.uuid)
            let interrupted = error is CancellationError || Task.isCancelled
            try? run.writeIndex(status: interrupted ? "interrupted" : "failed", stopReason: interrupted ? .interrupted : nil)
            var detail = "\(run.entries.count) frames written to \(command.directory.path) (index \(FramesCommand.indexName)). Stream: packets=\(packets), access units=\(units). Cleanup: start attempted=\(cleanup?.startAttempted ?? false), owned stop=\(cleanup?.stopAcknowledged ?? false), stream absent=\(cleanup?.ownedStreamAbsent ?? false), tunnel release=\(release.status). \(cleanup?.diagnostic ?? "")"
            if interrupted {
                FileHandle.standardError.write(Data("Frame capture interrupted: \(detail)\n".utf8))
                throw CancellationError()
            }
            // A started stream that delivers nothing is what a firewall
            // dropping the incoming video looks like.
            var firewallDrops = false
            if packets == 0, let hint = HostFirewall.check().recordingHint {
                detail += " \(hint)"
                firewallDrops = true
            }
            throw CommandFailure.nativeRecording("Frame capture failed: \(error) \(detail)", wrapping: error, firewallDropsVideo: firewallDrops)
        }
    }
}
