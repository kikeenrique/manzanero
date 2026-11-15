import Foundation
import ProbeCore

/// How a sent action fared, judged only by what the probe recorded.
public enum ActionStatus: String, Codable, Sendable, CaseIterable {
    /// Every expected contact began and ended (none cancelled), no extra contacts, and the
    /// expected number of contacts were down at once. Position, timing and movement are
    /// reported separately and do not change this status.
    case delivered
    /// Something arrived, but not all of the above holds.
    case partial
    /// The window holds no events for the action.
    case missing
    /// Several actions share one window and their events cannot be split between them.
    case inseparable
    /// The probe's session changed inside the action's window (reset or relaunch).
    case sessionChanged = "session-changed"
    /// No readback bounds the action and the log cannot stand in.
    case noData = "no-data"
    /// The runner did not send the action (it stopped earlier).
    case notSent = "not-sent"
}

/// Where an action's received evidence came from, best first.
public enum EvidenceSource: String, Codable, Sendable {
    /// Log events in the action's `seq` window: per contact, with positions and timestamps.
    case log
    /// The `probe.touch.recent-gestures` readout of the closing readback, proven to list every
    /// gesture of the window: per contact, with positions and timestamps, but no per-event detail.
    case recentGestures = "recent-gestures"
    /// The `probe.touch.last-gesture` readout taken after the action: one gesture.
    case readout
    /// Only the summary's phase counters before and after: counts, no positions or timing.
    case summary
    case none
}

public enum Anomaly: String, Codable, Sendable, CaseIterable, Comparable {
    case dispatchFailed = "dispatch-failed"
    case receivedDespiteDispatchFailure = "received-despite-dispatch-failure"
    case missingContacts = "missing-contacts"
    case extraContacts = "extra-contacts"
    case cancelledContacts = "cancelled-contacts"
    case unfinishedContacts = "unfinished-contacts"
    case contactWithoutBegan = "contact-without-began"
    case maxActiveShort = "max-active-short"
    case gestureCountMismatch = "gesture-count-mismatch"
    case noMovement = "no-movement"
    case positionOutOfTolerance = "position-out-of-tolerance"
    case durationOutOfTolerance = "duration-out-of-tolerance"
    case unmatchedCallbacks = "unmatched-callbacks"
    case contactsStillDown = "contacts-still-down"
    case sessionChanged = "session-changed"
    case inseparable
    case assignedByOrder = "assigned-by-order"
    case logUnusable = "log-unusable"
    case openWindow = "open-window"
    case lateDeliverySuspected = "late-delivery-suspected"

    public static func < (lhs: Anomaly, rhs: Anomaly) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Normalised received minus expected position.
public struct PointError: Codable, Sendable, Equatable {
    public var dx: Double
    public var dy: Double
    public var distance: Double

    init(expected: NormalizedPoint, received: NormalizedPoint) {
        dx = ProbeJSON.round(received.x - expected.x, 5)
        dy = ProbeJSON.round(received.y - expected.y, 5)
        distance = ProbeJSON.round(hypot(received.x - expected.x, received.y - expected.y), 5)
    }
}

public struct ContactResult: Codable, Sendable, Equatable {
    /// 0-based index of the expected gesture within the action.
    public var gesture: Int
    public var expected: ExpectedContact
    public var received: ReceivedContact?
    public var startError: PointError?
    public var endError: PointError?
    /// Received minus expected hold, seconds.
    public var holdError: Double?
}

/// The `seq` range of the probe session attributed to one or more actions.
public struct EventWindow: Codable, Sendable, Equatable {
    public var session: String
    /// Exclusive lower bound: the summary's `events` before the window.
    public var afterSeq: Int
    /// Inclusive upper bound; nil when no readback closed the window.
    public var throughSeq: Int?
    /// Run positions (`sequence`) of every action sharing the window.
    public var actions: [Int]
}

public struct ActionResult: Codable, Sendable, Equatable {
    public var sequence: Int
    public var round: Int
    public var id: String
    public var kind: String
    public var arguments: [String]
    public var status: ActionStatus
    public var source: EvidenceSource
    public var dispatch: DispatchOutcome
    public var window: EventWindow?
    public var expectedGestures: Int
    public var expectedContacts: Int
    public var expectedMaxActive: Int
    public var receivedGestures: Int?
    public var receivedContacts: Int?
    public var receivedMaxActive: Int?
    /// Expected contacts that began and ended (not cancelled) in this action's evidence.
    public var contactsDelivered: Int
    public var contacts: [ContactResult]
    /// Received contacts matched to no expected contact.
    public var extraContacts: [ReceivedContact]
    public var anomalies: [Anomaly]
    public var notes: [String]
    /// Foreground identity of the readback taken after this action; nil when the action has no
    /// readback of its own or no expected bundle identifier was given.
    public var identity: IdentityStatus? = nil
}

/// The foreground identity check over all readbacks used by the comparison (baseline and
/// per-action). `nativeAttributes["3003"]` of the `probe.touch.summary` node is taken to be the
/// owning app's bundle identifier, which rests on one observation on one phone.
public struct IdentityFacts: Codable, Sendable, Equatable {
    public var expectedBundleID: String
    public var readbacks: Int
    public var matched: Int
    public var notChecked: Int
    public var mismatched: Int
}

/// Summary statistics of one measured quantity.
public struct Distribution: Codable, Sendable, Equatable {
    public var count: Int
    public var min: Double
    public var median: Double
    public var mean: Double
    public var max: Double

    public static func of(_ values: [Double]) -> Distribution? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return Distribution(count: sorted.count, min: ProbeJSON.round(first, 5), median: ProbeJSON.round(median, 5),
                            mean: ProbeJSON.round(mean, 5), max: ProbeJSON.round(last, 5))
    }
}

public struct KindSummary: Codable, Sendable, Equatable {
    public var sent: Int
    public var measured: Int
    public var delivered: Int
    public var startError: Distribution?
    public var holdErrorAbsolute: Distribution?
}

/// Contacts down at once, grouped by how many the actions scheduled.
public struct ContactCountRow: Codable, Sendable, Equatable {
    public var expected: Int
    /// Measured actions with log or readout evidence that scheduled this many contacts.
    public var actions: Int
    /// Actions whose received `maxActive` reached `expected`.
    public var reached: Int
    public var receivedMaxActive: Distribution?
}

public struct ReportSummary: Codable, Sendable, Equatable {
    public var actionsPlanned: Int
    public var actionsSent: Int
    /// Actions with status delivered, partial or missing: the denominator of the rates.
    public var actionsMeasured: Int
    public var statusCounts: [String: Int]
    /// Delivered over measured actions; nil when nothing was measured.
    public var deliveryRate: Double?
    public var contactsExpected: Int
    /// Expected contacts that began and ended (not cancelled), in measured actions.
    public var contactsDelivered: Int
    public var contactDeliveryRate: Double?
    public var startError: Distribution?
    public var startDx: Distribution?
    public var startDy: Distribution?
    public var endError: Distribution?
    /// Signed received-minus-expected hold, seconds.
    public var holdError: Distribution?
    public var holdErrorAbsolute: Distribution?
    public var byKind: [String: KindSummary]
    public var contactCounts: [ContactCountRow]
    /// Number of actions showing each anomaly.
    public var anomalyCounts: [String: Int]
    /// Measured actions per evidence source (`log`, `recent-gestures`, `readout`, `summary`).
    public var sourceCounts: [String: Int]
}

public struct LogSessionFacts: Codable, Sendable, Equatable {
    public var session: String
    public var reason: String?
    public var events: Int
    public var contiguousThrough: Int
    public var firstDroppedSeq: Int?
}

public struct LogFacts: Codable, Sendable, Equatable {
    public var available: Bool
    public var sessions: [LogSessionFacts]
    public var malformedLines: Int
    public var incompleteFinalLine: Bool
    public var sequenceBreaks: Int
}

/// Log events attributed to no action.
public struct UnattributedEvents: Codable, Sendable, Equatable {
    /// In the run's first session, at or before the baseline readback (for example a reset press delivered as a tap).
    public var beforeRun: Int = 0
    /// After the last readback that closed a window.
    public var afterRun: Int = 0
    /// In a session that began inside an action's window (after a reset or relaunch).
    public var afterSessionChange: Int = 0
    /// In sessions the readbacks never saw.
    public var otherSessions: Int = 0
}

public struct TouchReport: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public var v = TouchReport.formatVersion
    public var plan: String
    public var tolerances: Tolerances
    /// Probe sessions in the order the readbacks saw them, baseline first.
    public var sessions: [String]
    public var summary: ReportSummary
    public var actions: [ActionResult]
    public var log: LogFacts
    public var unattributed: UnattributedEvents
    /// Nil when the comparison was given no expected bundle identifier.
    public var identity: IdentityFacts?
    public var notes: [String]

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

// MARK: - Human-readable summary

extension TouchReport {
    public func text() -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        func dist(_ d: Distribution?, _ unit: String = "") -> String {
            guard let d else { return "n/a" }
            return String(format: "median %.4f", d.median) + unit + String(format: ", max %.4f", d.max) + unit + " (n=\(d.count))"
        }
        var lines: [String] = []
        let s = summary
        lines.append("Probe touch measurement: plan \(plan)")
        lines.append("Actions: \(s.actionsPlanned) planned, \(s.actionsSent) sent, \(s.actionsMeasured) measured")
        lines.append("Status: " + ActionStatus.allCases.compactMap { status in
            s.statusCounts[status.rawValue].map { "\(status.rawValue) \($0)" }
        }.joined(separator: ", "))
        lines.append("Delivery rate: \(percent(s.deliveryRate)) of measured actions; contacts \(s.contactsDelivered)/\(s.contactsExpected) (\(percent(s.contactDeliveryRate)))")
        lines.append("Start error (normalised): \(dist(s.startError))")
        lines.append("Start offset dx: \(dist(s.startDx)); dy: \(dist(s.startDy))")
        lines.append("End error (normalised): \(dist(s.endError))")
        lines.append("Hold error (received - expected): \(dist(s.holdError, " s"))")
        for row in s.contactCounts {
            lines.append("Contacts \(row.expected): reached in \(row.reached)/\(row.actions) actions; received maxActive \(dist(row.receivedMaxActive))")
        }
        if !s.sourceCounts.isEmpty {
            lines.append("Evidence: " + ["log", "recent-gestures", "readout", "summary"].compactMap { source in
                s.sourceCounts[source].map { "\(source) \($0)" }
            }.joined(separator: ", "))
        }
        if let identity {
            lines.append("Foreground identity (\(identity.expectedBundleID)): matched \(identity.matched), not checked \(identity.notChecked), mismatched \(identity.mismatched) of \(identity.readbacks) readback(s)")
        }
        if !s.anomalyCounts.isEmpty {
            lines.append("Anomalies: " + s.anomalyCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        let u = unattributed
        if u.beforeRun + u.afterRun + u.afterSessionChange + u.otherSessions > 0 {
            lines.append("Unattributed events: before run \(u.beforeRun), after run \(u.afterRun), after session change \(u.afterSessionChange), other sessions \(u.otherSessions)")
        }
        if log.available {
            let truncated = log.sessions.contains { $0.firstDroppedSeq != nil }
            lines.append("Log: \(log.sessions.count) session(s), malformed lines \(log.malformedLines), incomplete final line \(log.incompleteFinalLine), truncated \(truncated)")
        } else {
            lines.append("Log: not available; readouts only")
        }
        lines.append("")
        lines.append("Per action:")
        for a in actions {
            var line = "  #\(a.sequence) r\(a.round) \(a.id) [\(a.kind)] \(a.status.rawValue) via \(a.source.rawValue)"
            if let received = a.receivedContacts { line += ", contacts \(received)/\(a.expectedContacts)" }
            if let maxActive = a.receivedMaxActive { line += ", maxActive \(maxActive)/\(a.expectedMaxActive)" }
            let starts = a.contacts.compactMap { $0.startError?.distance }
            if let worst = starts.max() { line += String(format: ", worst start error %.4f", worst) }
            let holds = a.contacts.compactMap(\.holdError)
            if let worst = holds.max(by: { abs($0) < abs($1) }) { line += String(format: ", hold error %+.3f s", worst) }
            if !a.anomalies.isEmpty { line += " {" + a.anomalies.map(\.rawValue).joined(separator: ", ") + "}" }
            lines.append(line)
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines += notes.map { "  - \($0)" }
        }
        lines.append("")
        lines.append("The probe shows what reached its UIKit view, not why anything was lost. Device timestamps are uptime; only differences are used.")
        return lines.joined(separator: "\n") + "\n"
    }
}
