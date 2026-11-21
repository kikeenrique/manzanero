import Foundation

/// When a native recording restarts its media session, and what it says
/// about it afterwards (docs/recording-recovery.md). Pure bookkeeping: the
/// recording loop reports packets, pictures and failures with host times in
/// nanoseconds and acts on the answers.
struct RecordingRecovery: Sendable {
    static let maximumRestarts = 3
    /// No packet, or packets and no picture, for this long is a loss.
    static let stallNanoseconds: UInt64 = 3_000_000_000
    /// A restart must deliver its first picture within this.
    static let restartBudgetNanoseconds: UInt64 = 10_000_000_000
    /// No restart begins with less of the requested duration left.
    static let minimumRemainingNanoseconds: UInt64 = 2_000_000_000
    /// How long a restart waits for a device that stopped answering (a
    /// pulled cable) before it gives up on the lost session's end.
    static let linkWaitNanoseconds: UInt64 = 30_000_000_000

    enum Reason: String, Sendable {
        case streamEnded = "stream-ended", transportFailed = "transport-failed"
        case noPackets = "no-packets", noPictures = "no-pictures"
    }

    struct Gap: Sendable, Equatable {
        let atSeconds: Double
        var seconds: Double
        let reason: Reason
    }

    /// The movie's first picture; nothing is recovered before it.
    private(set) var first: UInt64?
    private(set) var restarts = 0
    private(set) var gaps: [Gap] = []
    /// From when the last picture is held to the end, in movie seconds.
    private(set) var heldFrom: Double?
    /// When the session being waited for was opened.
    private(set) var restartedAt: UInt64?
    private var lastPacket: UInt64 = 0
    private var lastPicture: UInt64 = 0
    /// Where the open gap starts: the last picture before the loss.
    private var lossAt: UInt64 = 0
    private let duration: UInt64

    init(durationNanoseconds: UInt64) { duration = durationNanoseconds }

    /// `later - earlier`, or 0 when the clock did not move forward.
    private static func span(_ later: UInt64, _ earlier: UInt64) -> UInt64 { later > earlier ? later - earlier : 0 }
    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e9 }

    mutating func packet(at now: UInt64) { lastPacket = max(lastPacket, now) }

    mutating func picture(at now: UInt64) {
        if first == nil { first = now }
        lastPacket = max(lastPacket, now)
        lastPicture = max(lastPicture, now)
        // The first picture of a restarted session closes the gap.
        if restartedAt != nil, !gaps.isEmpty {
            gaps[gaps.count - 1].seconds = Self.seconds(Self.span(now, lossAt))
            restartedAt = nil
        }
    }

    /// A stall seen at `now`, once pictures have started and while the
    /// picture is not already held: packets that still arrive and decode to
    /// no picture for `stallNanoseconds`, which a new session's key frame
    /// mends. Silence alone is not a stall: how long a still screen can go
    /// without a packet has not been measured, and a silent session that
    /// has really ended is caught by the once-a-second liveness check.
    /// While a restart waits for its first picture, only its budget counts.
    func stall(at now: UInt64) -> Reason? {
        guard first != nil, heldFrom == nil else { return nil }
        if let restartedAt {
            return Self.span(now, restartedAt) >= Self.restartBudgetNanoseconds ? .noPictures : nil
        }
        if Self.span(now, lastPicture) >= Self.stallNanoseconds, Self.span(now, lastPacket) < Self.stallNanoseconds { return .noPictures }
        return nil
    }

    /// What to do about a loss at `now`: `.restart`, or `.fail` (a failure
    /// is thrown as before), or `.hold` (a stall with no restart left: the
    /// last picture stays to the end, as before recovery existed).
    enum Decision: Equatable { case restart, fail, hold }

    mutating func decide(_ reason: Reason, at now: UInt64) -> Decision {
        let stall = reason == .noPackets || reason == .noPictures
        guard let first else { return stall ? .hold : .fail }
        guard restarts < Self.maximumRestarts, Self.span(now, first) + Self.minimumRemainingNanoseconds <= duration else {
            if stall {
                if heldFrom == nil { heldFrom = Self.seconds(Self.span(min(lastPicture, now), first)) }
                restartedAt = nil
                return .hold
            }
            return .fail
        }
        restarts += 1
        if restartedAt == nil {
            // A new loss; further attempts for it add no gap.
            lossAt = max(lastPicture, first)
            gaps.append(Gap(atSeconds: Self.seconds(Self.span(lossAt, first)), seconds: Self.seconds(Self.span(now, lossAt)), reason: reason))
        }
        restartedAt = now
        return .restart
    }

    /// The receipt's `recovery` object.
    var json: [String: Any] {
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        return ["restarts": restarts,
                "gaps": gaps.map { ["atSeconds": rounded($0.atSeconds), "seconds": rounded($0.seconds), "reason": $0.reason.rawValue] as [String: Any] },
                "lastPictureHeldFrom": heldFrom.map { rounded($0) as Any } ?? NSNull()]
    }
}
