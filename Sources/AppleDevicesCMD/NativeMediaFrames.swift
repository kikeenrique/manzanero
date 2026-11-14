import AppleDeviceBridge
import Foundation

/// Apple's per-stream decoder/output objects stay on the main actor. Ingress
/// retains only the latest valid sample; JPEG encoding happens on demand.
@MainActor
final class NativeMediaFrames {
    struct Cleanup: Sendable, Encodable {
        let startAttempted: Bool
        let stopAcknowledged: Bool
        let ownedStreamAbsent: Bool
        let localDecoderStopRequested: Bool
        let localOutputReleaseRequested: Bool
        let decodedFrames: UInt64
        let droppedFrames: UInt64
        let diagnostic: String?
    }
    private var owner: UnsafeMutableRawPointer?
    private var cleanup: Cleanup?

    init(endpoint: NativeMediaEndpoint, version: String) throws {
        var pointer: UnsafeMutableRawPointer?, error = [CChar](repeating: 0, count: 1024)
        let result = ADCCreateVideoSession(endpoint.uuid, version, endpoint.interface, endpoint.host, endpoint.device,
            { Task.isCancelled ? 1 : 0 }, &pointer, &error, error.count)
        guard result == 0, let pointer else { throw CommandFailure(description: Self.text(error)) }
        owner = pointer
    }

    isolated deinit { _ = close() }

    func start(displayID: Int64) throws {
        try Task.checkCancellation()
        var error = [CChar](repeating: 0, count: 1024)
        let result = ADCStartVideoSession(owner, displayID, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        try Task.checkCancellation()
        guard result == 0 else { throw CommandFailure(description: Self.text(error)) }
    }

    func next() throws -> TimedVideoFrame? {
        try Task.checkCancellation()
        var error = [CChar](repeating: 0, count: 1024), frame: TimedVideoFrame?
        let result = ADCCopyNextVideoFrame(owner, { Task.isCancelled ? 1 : 0 }, { bytes, count, time in
            if let bytes { frame = TimedVideoFrame(nanoseconds: time, jpeg: Data(bytes: bytes, count: count)) }
        }, &error, error.count)
        try Task.checkCancellation()
        guard result >= 0 else { throw CommandFailure(description: Self.text(error)) }
        return frame
    }

    @discardableResult
    func close() -> Cleanup {
        if let cleanup { return cleanup }
        let saved = owner; owner = nil
        var result = ADCVideoCleanup(), error = [CChar](repeating: 0, count: 1024)
        let status = ADCCloseVideoSession(saved, &result, &error, error.count)
        let value = Cleanup(startAttempted: result.startAttempted != 0, stopAcknowledged: result.stopAcknowledged != 0,
            ownedStreamAbsent: result.ownedStreamAbsent != 0, localDecoderStopRequested: result.localDecoderStopRequested != 0,
            localOutputReleaseRequested: result.localOutputReleaseRequested != 0, decodedFrames: result.decodedFrames,
            droppedFrames: result.droppedFrames, diagnostic: status == 0 ? nil : Self.text(error))
        cleanup = value
        return value
    }

    private static func text(_ bytes: [CChar]) -> String { String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}
