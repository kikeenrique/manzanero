import Foundation

/// Records raw touch callbacks and derives the summary and last-gesture readouts.
///
/// `Key` identifies a live contact across callbacks (the app uses the UITouch's
/// object identity). The recorder is a value type with no UIKit dependency; the
/// app owns one instance on the main actor.
public struct TouchRecorder<Key: Hashable> {
    struct ActiveContact {
        let index: Int
        let from: ProbePoint
        let began: Double
        var moves = 0
    }

    struct GestureInProgress {
        let number: Int
        let start: Double
        var maxActive = 0
        var contacts: [GestureContact] = []
    }

    public private(set) var session: String
    public private(set) var interface: InterfaceSize
    private var nextSeq = 1
    private var nextContact = 0
    private var active: [Key: ActiveContact] = [:]
    private var counts: [TouchPhase: Int] = [:]
    private var unmatched = 0
    private var maxActive = 0
    private var gestureCount = 0
    private var gesture: GestureInProgress?
    public private(set) var lastGesture: LastGestureReadout

    public init(session: String, interface: InterfaceSize) {
        self.session = session
        self.interface = interface
        lastGesture = .none(session: session)
    }

    /// Discard all state and start a new session. Contacts still down become
    /// unknown: their later callbacks count as `unmatched`.
    public mutating func reset(session: String) {
        self = Self(session: session, interface: interface)
    }

    /// Normalisation uses the size current at each event.
    public mutating func setInterface(_ size: InterfaceSize) {
        interface = size
    }

    public var activeCount: Int { active.count }

    /// Contact index for a live key, if it is down.
    public func contactIndex(for key: Key) -> Int? { active[key]?.index }

    /// Record one callback for one contact. Returns nil (and counts it as
    /// unmatched) for a moved/ended/cancelled callback whose contact is unknown.
    /// A repeated `began` for a live key keeps that contact's index.
    public mutating func record(key: Key, phase: TouchPhase, point: ProbePoint, timestamp: Double,
                                kind: String = "direct", radius: Double = 0) -> TouchEventRecord? {
        let normalized = interface.normalize(point)
        let contact: ActiveContact
        let activeAtEvent: Int
        switch phase {
        case .began:
            if let existing = active[key] {
                contact = existing
            } else {
                if active.isEmpty {
                    gestureCount += 1
                    gesture = GestureInProgress(number: gestureCount, start: timestamp)
                }
                contact = ActiveContact(index: nextContact, from: normalized, began: timestamp)
                nextContact += 1
                active[key] = contact
            }
            activeAtEvent = active.count
            maxActive = max(maxActive, activeAtEvent)
            if let current = gesture?.maxActive { gesture?.maxActive = max(current, activeAtEvent) }
        case .moved:
            guard var existing = active[key] else { unmatched += 1; return nil }
            existing.moves += 1
            active[key] = existing
            contact = existing
            activeAtEvent = active.count
        case .ended, .cancelled:
            guard let existing = active.removeValue(forKey: key) else { unmatched += 1; return nil }
            contact = existing
            activeAtEvent = active.count + 1
            gesture?.contacts.append(GestureContact(
                c: existing.index,
                from: Self.pair(existing.from),
                to: Self.pair(normalized),
                began: ProbeJSON.round(existing.began, 6),
                duration: ProbeJSON.round(timestamp - existing.began, 6),
                end: phase.rawValue,
                moves: existing.moves))
            if active.isEmpty, let finished = gesture {
                lastGesture = LastGestureReadout(
                    session: session, gesture: finished.number, maxActive: finished.maxActive,
                    duration: ProbeJSON.round(timestamp - finished.start, 6),
                    contacts: finished.contacts.sorted { $0.c < $1.c })
                gesture = nil
            }
        }
        counts[phase, default: 0] += 1
        let record = TouchEventRecord(
            session: session, seq: nextSeq, contact: contact.index, phase: phase,
            x: ProbeJSON.round(point.x, 2), y: ProbeJSON.round(point.y, 2),
            nx: ProbeJSON.round(normalized.x, 5), ny: ProbeJSON.round(normalized.y, 5),
            t: ProbeJSON.round(timestamp, 6), active: activeAtEvent,
            kind: kind, radius: ProbeJSON.round(radius, 2))
        nextSeq += 1
        return record
    }

    public func summary(log: LogStatus) -> SummaryReadout {
        SummaryReadout(
            session: session,
            size: [ProbeJSON.round(interface.width, 2), ProbeJSON.round(interface.height, 2)],
            events: nextSeq - 1,
            began: counts[.began, default: 0], moved: counts[.moved, default: 0],
            ended: counts[.ended, default: 0], cancelled: counts[.cancelled, default: 0],
            unmatched: unmatched, active: active.count, maxActive: maxActive,
            gestures: lastGesture.gesture, log: log)
    }

    private static func pair(_ point: ProbePoint) -> [Double] {
        [ProbeJSON.round(point.x, 5), ProbeJSON.round(point.y, 5)]
    }
}

/// A short random session identifier: 16 lowercase hex characters (64 bits).
public func makeProbeSessionID() -> String {
    var generator = SystemRandomNumberGenerator()
    let value = generator.next() as UInt64
    let hex = String(value, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}
