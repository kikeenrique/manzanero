import AppleDeviceBridge
import Foundation

/// One owned native video session as a standard-RTP receiver: the bridge's
/// negotiator, socket and control channel stay on the main actor, and the
/// packets it hands over are assembled and decoded in Swift.
@MainActor
final class NativeMediaFrames {
    struct Cleanup: Sendable, Encodable {
        let startAttempted: Bool
        let stopAcknowledged: Bool
        let ownedStreamAbsent: Bool
        let diagnostic: String?
    }
    private var owner: UnsafeMutableRawPointer?
    private var cleanup: Cleanup?
    private var feedback: MediaRTCPReceiver?
    private var heartbeat: Task<Void, Never>?
    private var feedbackFailure: String?
    private(set) var receiverReportsSent: UInt64 = 0
    private(set) var senderReportsObserved: UInt64 = 0
    private(set) var negotiatedFeedback = "unknown"

    /// `plainOffer` takes VideoToolbox's resolution adaptation out of the
    /// offer. An Apple TV uses it when it is offered, and its pictures then
    /// come out on top of each other from any standard decoder, this one
    /// included (docs/other-families.md#a-physical-apple-tv).
    init(endpoint: NativeMediaEndpoint, version: String, plainOffer: Bool = false) throws {
        var pointer: UnsafeMutableRawPointer?, error = [CChar](repeating: 0, count: 1024)
        let result = ADCCreateVideoPacketSession(endpoint.uuid, version, endpoint.interface, endpoint.host, endpoint.device,
            { Task.isCancelled ? 1 : 0 }, &pointer, &error, error.count)
        guard result == 0, let pointer else { throw CommandFailure(.transportFailed, Self.text(error), inputSent: .none) }
        owner = pointer
        if plainOffer, ADCOfferVideoWithoutResolutionAdaptation(pointer, &error, error.count) != 0 {
            let message = Self.text(error)
            _ = close()
            throw CommandFailure(.transportFailed, message, inputSent: .none)
        }
    }

    isolated deinit { _ = close() }

    func start(displayID: Int64) throws {
        try Task.checkCancellation()
        var error = [CChar](repeating: 0, count: 1024)
        let result = ADCStartVideoSession(owner, displayID, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        try Task.checkCancellation()
        guard result == 0 else { throw CommandFailure(.transportFailed, Self.text(error), inputSent: .none) }
        var profile = ADCVideoRTCPProfile()
        guard ADCReadVideoRTCPProfile(owner, &profile) == 0, let payload = packetProfile()?["payloadType"],
              let payload = UInt8(exactly: payload) else { throw CommandFailure(.transportFailed, "Native media has no owned RTCP profile.", inputSent: .none) }
        negotiatedFeedback = profile.feedbackKnown == 0 ? "unknown" : (profile.feedbackEnabled != 0 ? "enabled" : "disabled")
        feedback = try MediaRTCPReceiver(sender: profile.senderSSRC, receiver: profile.receiverSSRC,
            payloadType: payload, cname: UUID().uuidString.lowercased() + "@manzanero",
            intervalSeconds: profile.reportIntervalSeconds, now: DispatchTime.now().uptimeNanoseconds)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.owner != nil else { return }
                do { try self.flushReceiverReport() }
                catch { self.feedbackFailure = String(describing: error); return }
            }
        }
    }

    /// One datagram of the stream, or nil when none is pending. Packets are
    /// not decoded frames.
    func nextPacket() throws -> Data? {
        try Task.checkCancellation()
        if let feedbackFailure { throw CommandFailure(.transportFailed, feedbackFailure, inputSent: .none) }
        var error = [CChar](repeating: 0, count: 1024), packet: Data?
        let result = ADCCopyNextVideoPacket(owner, { Task.isCancelled ? 1 : 0 }, { bytes, count in
            if let bytes { packet = Data(bytes: bytes, count: count) }
        }, &error, error.count)
        try Task.checkCancellation()
        guard result >= 0 else { throw CommandFailure(.transportFailed, Self.text(error), inputSent: .none) }
        if let packet {
            try feedback?.observe(packet, now: DispatchTime.now().uptimeNanoseconds)
            senderReportsObserved = feedback?.senderReportsObserved ?? 0
        }
        return packet
    }

    private func flushReceiverReport() throws {
        try Task.checkCancellation()
        guard let report = feedback?.reportIfDue(now: DispatchTime.now().uptimeNanoseconds) else { return }
        var error = [CChar](repeating: 0, count: 512)
        let sent = report.withUnsafeBytes {
            ADCSendVideoReceiverReport(owner, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                { Task.isCancelled ? 1 : 0 }, &error, error.count)
        }
        guard sent >= 0 else { throw CommandFailure(.transportFailed, Self.text(error), inputSent: .none) }
        if sent == 1 { receiverReportsSent += 1 }
    }

    func packetProfile() -> [String: UInt64]? {
        var profile = ADCVideoPacketProfile()
        guard ADCReadVideoPacketProfile(owner, &profile) == 0 else { return nil }
        return ["negotiatorMode": profile.negotiatorMode, "width": profile.width, "height": profile.height,
            "frameRate": profile.frameRate, "payloadType": profile.payloadType]
    }

    func requireActive() throws {
        try Task.checkCancellation()
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCVideoSessionActive(owner, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        try Task.checkCancellation()
        guard status == 1 else {
            throw CommandFailure(.transportFailed, status == 0 ? "Owned native video stream disappeared during capture." : Self.text(error), inputSent: .none)
        }
    }

    @discardableResult
    func close() -> Cleanup {
        if let cleanup { return cleanup }
        heartbeat?.cancel(); heartbeat = nil; feedback = nil
        let saved = owner; owner = nil
        var result = ADCVideoCleanup(), error = [CChar](repeating: 0, count: 1024)
        let status = ADCCloseVideoSession(saved, &result, &error, error.count)
        let value = Cleanup(startAttempted: result.startAttempted != 0, stopAcknowledged: result.stopAcknowledged != 0,
            ownedStreamAbsent: result.ownedStreamAbsent != 0, diagnostic: status == 0 ? nil : Self.text(error))
        cleanup = value
        return value
    }

    private static func text(_ bytes: [CChar]) -> String { String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}
