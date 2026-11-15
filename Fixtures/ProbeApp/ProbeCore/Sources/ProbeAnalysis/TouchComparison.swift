import Foundation
import ProbeCore

/// What happened when the runner invoked Manzanero for one action.
public struct DispatchOutcome: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Exit status 0 and a receipt with `status: dispatched`.
        case dispatched
        /// Any other exit status or receipt. Input may still have partly reached the device.
        case failed
        /// The runner interrupted the command after its deadline.
        case timedOut = "timed-out"
        /// The runner stopped before this action.
        case notSent = "not-sent"
    }

    public var state: State
    public var exitCode: Int32?
    public var receiptStatus: String?
    public var message: String?

    public init(state: State, exitCode: Int32? = nil, receiptStatus: String? = nil, message: String? = nil) {
        self.state = state
        self.exitCode = exitCode
        self.receiptStatus = receiptStatus
        self.message = message
    }

    public var sent: Bool { state != .notSent }
}

/// One accessibility readback of the probe: the summary and, when present, the last gesture.
public struct ProbeReadback: Codable, Sendable, Equatable {
    public var summary: SummaryReadout
    public var lastGesture: LastGestureReadout?

    public init(summary: SummaryReadout, lastGesture: LastGestureReadout?) {
        self.summary = summary
        self.lastGesture = lastGesture
    }
}

/// One sent (or unsent) action and the readback taken after it.
public struct ActionAttempt: Codable, Sendable, Equatable {
    /// 1-based position in the run.
    public var sequence: Int
    /// 1-based repeat of the plan.
    public var round: Int
    public var planned: PlannedAction
    public var dispatch: DispatchOutcome
    /// Readback after this action; nil when none was taken or it failed.
    public var readback: ProbeReadback?

    public init(sequence: Int, round: Int, planned: PlannedAction, dispatch: DispatchOutcome, readback: ProbeReadback?) {
        self.sequence = sequence
        self.round = round
        self.planned = planned
        self.dispatch = dispatch
        self.readback = readback
    }
}

public struct ComparisonInput: Sendable {
    public var planName: String
    public var tolerances: Tolerances
    /// Readback after the reset and before the first action.
    public var baseline: ProbeReadback
    public var attempts: [ActionAttempt]
    /// The pulled log, if the pull succeeded.
    public var log: ParsedProbeLog?
    public var notes: [String]

    public init(planName: String, tolerances: Tolerances, baseline: ProbeReadback, attempts: [ActionAttempt],
                log: ParsedProbeLog?, notes: [String] = []) {
        self.planName = planName
        self.tolerances = tolerances
        self.baseline = baseline
        self.attempts = attempts
        self.log = log
        self.notes = notes
    }
}

/// Compares sent actions with what the probe recorded. Pure: no clocks, files or processes.
///
/// Matching rules (also in docs/probe-touch-runner.md):
/// 1. Windows. Consecutive readbacks bound a `seq` window `(before.events, after.events]` in one
///    session. Actions without their own readback share the window that the next readback closes.
///    Host and device clocks are never compared.
/// 2. Session change. If the session differs across a window, its actions are `session-changed`
///    and the new session's events are unattributed.
/// 3. Evidence. Log events are used when the log holds the window's session contiguously through
///    the window's end. Otherwise a single action with exactly one new gesture uses the
///    last-gesture readout, and anything else falls back to the summary's phase counters.
/// 4. Shared windows. When actions share a window, log gestures are assigned in order only if
///    their number equals the expected number of gestures; otherwise the actions are `inseparable`.
/// 5. Contacts. Within an action, expected and received gestures are paired in order when their
///    counts agree, else all contacts are pooled. Contacts are paired greedily by smallest
///    start-position distance.
/// 6. Late delivery. A `missing` action followed in the adjacent window by extra gestures is
///    flagged on both actions; events are never moved between windows.
public enum TouchComparison {
    struct Counts {
        var began = 0, moved = 0, ended = 0, cancelled = 0, gestures = 0
    }

    public static func compare(_ input: ComparisonInput) -> TouchReport {
        var results: [ActionResult] = []
        var unattributed = UnattributedEvents()
        var notes = input.notes
        var sessions = [input.baseline.summary.session]
        var start = input.baseline
        var group: [ActionAttempt] = []
        let log = input.log

        func evaluateClosed(_ group: [ActionAttempt], end: ProbeReadback) {
            let s0 = start.summary, s1 = end.summary
            let ids = group.map(\.sequence)
            if s1.session != s0.session {
                let window = EventWindow(session: s0.session, afterSeq: s0.events, throughSeq: nil, actions: ids)
                for attempt in group {
                    results.append(unmeasured(attempt, status: .sessionChanged, window: window, anomalies: [.sessionChanged],
                                              note: "Session \(s0.session) became \(s1.session) inside the window."))
                }
                if let changed = log?.session(s1.session) {
                    unattributed.afterSessionChange += changed.events(after: 0, through: s1.events).count
                }
                return
            }
            let window = EventWindow(session: s0.session, afterSeq: s0.events, throughSeq: s1.events, actions: ids)
            var shared: [Anomaly] = []
            if s1.active > 0 { shared.append(.contactsStillDown) }
            if s1.unmatched > s0.unmatched { shared.append(.unmatchedCallbacks) }
            if let logSession = log?.session(s0.session), logSession.contiguousThrough >= s1.events {
                let gestures = ReceivedTouches.gestures(from: logSession.events(after: s0.events, through: s1.events))
                assign(group, gestures: gestures, window: window, shared: shared)
                return
            }
            if log != nil { shared.append(.logUnusable) }
            let counts = Counts(began: s1.began - s0.began, moved: s1.moved - s0.moved, ended: s1.ended - s0.ended,
                                cancelled: s1.cancelled - s0.cancelled, gestures: s1.gestures - s0.gestures)
            if group.count == 1, let attempt = group.first, attempt.planned.action.expectedGestures.count == 1,
               counts.gestures == 1, let last = end.lastGesture, last.session == s1.session, last.gesture == s1.gestures {
                results.append(evaluate(attempt, source: .readout, gestures: [ReceivedTouches.gesture(from: last)],
                                        window: window, anomalies: shared, tolerances: input.tolerances))
            } else if group.count == 1, let attempt = group.first {
                results.append(evaluate(attempt, counts: counts, window: window, anomalies: shared))
            } else {
                for attempt in group {
                    results.append(unmeasured(attempt, status: .inseparable, window: window, anomalies: shared + [.inseparable],
                                              note: "Shared window without usable log events; summary counts cannot be split."))
                }
            }
        }

        func assign(_ group: [ActionAttempt], gestures: [ReceivedGesture], window: EventWindow, shared: [Anomaly]) {
            if group.count == 1, let attempt = group.first {
                results.append(evaluate(attempt, source: .log, gestures: gestures, window: window,
                                        anomalies: shared, tolerances: input.tolerances))
                return
            }
            let expectedCounts = group.map { $0.planned.action.expectedGestures.count }
            guard gestures.count == expectedCounts.reduce(0, +) else {
                for attempt in group {
                    results.append(unmeasured(attempt, status: .inseparable, window: window, anomalies: shared + [.inseparable],
                                              note: "\(gestures.count) gesture(s) received for \(expectedCounts.reduce(0, +)) expected across actions \(window.actions.map(String.init).joined(separator: ", "))."))
                }
                return
            }
            var offset = 0
            for (attempt, count) in zip(group, expectedCounts) {
                let slice = Array(gestures[offset..<(offset + count)])
                offset += count
                results.append(evaluate(attempt, source: .log, gestures: slice, window: window,
                                        anomalies: shared + [.assignedByOrder], tolerances: input.tolerances))
            }
        }

        for attempt in input.attempts {
            guard attempt.dispatch.sent else {
                results.append(unmeasured(attempt, status: .notSent, window: nil, anomalies: [], note: nil))
                continue
            }
            group.append(attempt)
            if let end = attempt.readback {
                evaluateClosed(group, end: end)
                if sessions.last != end.summary.session { sessions.append(end.summary.session) }
                start = end
                group = []
            }
        }

        if !group.isEmpty {
            // No readback closed the last window: the log, if it holds the session, closes it.
            let s0 = start.summary
            let window = EventWindow(session: s0.session, afterSeq: s0.events, throughSeq: nil, actions: group.map(\.sequence))
            if let logSession = log?.session(s0.session) {
                let gestures = ReceivedTouches.gestures(from: logSession.events(after: s0.events, through: logSession.contiguousThrough))
                assign(group, gestures: gestures, window: window, shared: [.openWindow])
                notes.append("No readback followed action \(group.last?.sequence ?? 0); its window was closed by the end of the log.")
            } else {
                for attempt in group {
                    results.append(unmeasured(attempt, status: .noData, window: window, anomalies: [],
                                              note: "No readback after the action and no log for session \(s0.session)."))
                }
            }
        } else if let logSession = log?.session(start.summary.session) {
            unattributed.afterRun = logSession.events.filter { $0.seq > start.summary.events }.count
        }

        if let log {
            if let first = log.session(input.baseline.summary.session) {
                unattributed.beforeRun = first.events.filter { $0.seq <= input.baseline.summary.events }.count
            }
            let seen = Set(sessions)
            unattributed.otherSessions = log.sessions.filter { !seen.contains($0.session) }.reduce(0) { $0 + $1.events.count }
            if log.session(sessions.last ?? "") == nil {
                notes.append("The pulled log does not hold the last session the readbacks saw; it was reset or relaunched, or the pull failed to capture it.")
            }
        } else {
            notes.append("No log was available; evidence comes from accessibility readouts only.")
        }

        results.sort { $0.sequence < $1.sequence }
        flagLateDelivery(&results, notes: &notes)
        return TouchReport(plan: input.planName, tolerances: input.tolerances, sessions: sessions,
                           summary: summarize(results), actions: results, log: facts(log),
                           unattributed: unattributed, notes: notes)
    }

    /// Rule 6: an action with nothing in its window, followed in the adjacent window of the same
    /// session by more gestures than the next action expects, suggests events that arrived after
    /// the readback (settle too short). Both are flagged; nothing is reassigned.
    static func flagLateDelivery(_ results: inout [ActionResult], notes: inout [String]) {
        for i in results.indices.dropLast() {
            let current = results[i], next = results[i + 1]
            guard current.status == .missing, let a = current.window, let b = next.window,
                  a.session == b.session, a.throughSeq == b.afterSeq, a.actions == [current.sequence],
                  let received = next.receivedGestures, received > next.expectedGestures else { continue }
            for index in [i, i + 1] where !results[index].anomalies.contains(.lateDeliverySuspected) {
                results[index].anomalies = (results[index].anomalies + [.lateDeliverySuspected]).sorted()
            }
            notes.append("Action \(current.sequence) received nothing and action \(next.sequence) received extra gestures: events may have arrived after the readback. Consider a longer --settle.")
        }
    }

    // MARK: Per action

    private static func base(_ attempt: ActionAttempt, status: ActionStatus, source: EvidenceSource,
                             window: EventWindow?) -> ActionResult {
        let expected = attempt.planned.action.expectedGestures
        return ActionResult(
            sequence: attempt.sequence, round: attempt.round, id: attempt.planned.id, kind: attempt.planned.action.kind,
            arguments: attempt.planned.action.cliArguments, status: status, source: source, dispatch: attempt.dispatch,
            window: window, expectedGestures: expected.count,
            expectedContacts: expected.reduce(0) { $0 + $1.contacts.count },
            expectedMaxActive: expected.map(\.maxActive).max() ?? 0,
            receivedGestures: nil, receivedContacts: nil, receivedMaxActive: nil, contactsDelivered: 0,
            contacts: [], extraContacts: [], anomalies: [], notes: [])
    }

    private static func dispatchAnomalies(_ attempt: ActionAttempt, received: Int) -> [Anomaly] {
        guard attempt.dispatch.sent, attempt.dispatch.state != .dispatched else { return [] }
        return received > 0 ? [.dispatchFailed, .receivedDespiteDispatchFailure] : [.dispatchFailed]
    }

    private static func unmeasured(_ attempt: ActionAttempt, status: ActionStatus, window: EventWindow?,
                                   anomalies: [Anomaly], note: String?) -> ActionResult {
        var result = base(attempt, status: status, source: .none, window: window)
        result.anomalies = Array(Set(anomalies + dispatchAnomalies(attempt, received: 0))).sorted()
        if let note { result.notes.append(note) }
        return result
    }

    static func evaluate(_ attempt: ActionAttempt, counts: Counts, window: EventWindow, anomalies: [Anomaly]) -> ActionResult {
        var result = base(attempt, status: .partial, source: .summary, window: window)
        let expected = result.expectedContacts
        var flags = Set(anomalies)
        result.receivedContacts = counts.began
        result.receivedGestures = counts.gestures
        if counts.began < expected, counts.began > 0 { flags.insert(.missingContacts) }
        if counts.began > expected { flags.insert(.extraContacts) }
        if counts.cancelled > 0 { flags.insert(.cancelledContacts) }
        if counts.began - counts.ended - counts.cancelled > 0 { flags.insert(.unfinishedContacts) }
        if counts.began > 0, counts.moved == 0, attempt.planned.action.expectedGestures.contains(where: { $0.contacts.contains(where: \.moves) }) {
            flags.insert(.noMovement)
        }
        if counts.began + counts.ended + counts.cancelled + counts.moved == 0 {
            result.status = .missing
        } else if counts.began == expected, counts.ended == expected, counts.cancelled == 0 {
            result.status = .delivered
        }
        result.contactsDelivered = min(counts.began, counts.ended, expected)
        flags.formUnion(dispatchAnomalies(attempt, received: counts.began))
        result.anomalies = flags.sorted()
        result.notes.append("Summary counters only: began \(counts.began), moved \(counts.moved), ended \(counts.ended), cancelled \(counts.cancelled). No positions or timing.")
        return result
    }

    static func evaluate(_ attempt: ActionAttempt, source: EvidenceSource, gestures: [ReceivedGesture], window: EventWindow,
                         anomalies: [Anomaly], tolerances: Tolerances) -> ActionResult {
        var result = base(attempt, status: .partial, source: source, window: window)
        let expected = attempt.planned.action.expectedGestures
        var flags = Set(anomalies)
        let received = gestures.flatMap(\.contacts)
        result.receivedGestures = gestures.count
        result.receivedContacts = received.count
        result.receivedMaxActive = gestures.map(\.maxActive).max() ?? 0

        var groups: [([(Int, ExpectedContact)], [ReceivedContact])] = []
        if expected.count == gestures.count {
            for (index, pair) in zip(expected, gestures).enumerated() {
                groups.append((pair.0.contacts.map { (index, $0) }, pair.1.contacts))
            }
        } else {
            if !gestures.isEmpty { flags.insert(.gestureCountMismatch) }
            groups.append((expected.enumerated().flatMap { index, gesture in gesture.contacts.map { (index, $0) } }, received))
        }

        var missing = 0
        for (expectedContacts, receivedContacts) in groups {
            let (pairs, unmatched) = match(expectedContacts.map(\.1), receivedContacts)
            for (offset, item) in expectedContacts.enumerated() {
                let (gesture, contact) = item
                guard let r = pairs[offset].map({ receivedContacts[$0] }) else {
                    missing += 1
                    result.contacts.append(ContactResult(gesture: gesture, expected: contact, received: nil,
                                                         startError: nil, endError: nil, holdError: nil))
                    continue
                }
                let startError = r.from.map { PointError(expected: contact.start, received: $0) }
                let endError = r.end != nil ? r.to.map { PointError(expected: contact.end, received: $0) } : nil
                let holdError = r.duration.map { ProbeJSON.round($0 - contact.holdSeconds, 6) }
                if let e = startError, e.distance > tolerances.position { flags.insert(.positionOutOfTolerance) }
                if let e = endError, e.distance > tolerances.position { flags.insert(.positionOutOfTolerance) }
                if let h = holdError, abs(h) > tolerances.duration { flags.insert(.durationOutOfTolerance) }
                if contact.moves, r.moves == 0 { flags.insert(.noMovement) }
                result.contacts.append(ContactResult(gesture: gesture, expected: contact, received: r,
                                                     startError: startError, endError: endError, holdError: holdError))
            }
            result.extraContacts += unmatched.map { receivedContacts[$0] }
        }
        // Nothing at all is status `missing`, not an anomaly on top of it.
        if missing > 0, !received.isEmpty { flags.insert(.missingContacts) }
        if !result.extraContacts.isEmpty { flags.insert(.extraContacts) }
        if received.contains(where: { $0.end == "cancelled" }) { flags.insert(.cancelledContacts) }
        if received.contains(where: { $0.end == nil }) { flags.insert(.unfinishedContacts) }
        if received.contains(where: { !$0.sawBegan }) { flags.insert(.contactWithoutBegan) }
        if !received.isEmpty, (result.receivedMaxActive ?? 0) < result.expectedMaxActive { flags.insert(.maxActiveShort) }

        let failing: Set<Anomaly> = [.missingContacts, .extraContacts, .cancelledContacts, .unfinishedContacts,
                                     .contactWithoutBegan, .maxActiveShort, .gestureCountMismatch]
        if received.isEmpty {
            result.status = .missing
        } else if flags.isDisjoint(with: failing) {
            result.status = .delivered
        }
        result.contactsDelivered = result.contacts.filter { $0.received?.end == "ended" && $0.received?.sawBegan == true }.count
        flags.formUnion(dispatchAnomalies(attempt, received: received.count))
        result.anomalies = flags.sorted()
        return result
    }

    /// Greedy pairing by smallest start distance (received `from`, else its last position).
    /// Returns, per expected contact, the index of its received contact, plus the unmatched received indexes.
    static func match(_ expected: [ExpectedContact], _ received: [ReceivedContact]) -> ([Int?], [Int]) {
        var candidates: [(cost: Double, e: Int, r: Int)] = []
        for (e, contact) in expected.enumerated() {
            for (r, got) in received.enumerated() {
                let cost = (got.from ?? got.to).map { contact.start.distance(to: $0) } ?? 10
                candidates.append((cost, e, r))
            }
        }
        candidates.sort { ($0.cost, $0.e, $0.r) < ($1.cost, $1.e, $1.r) }
        var pairs = [Int?](repeating: nil, count: expected.count)
        var used = Set<Int>()
        for candidate in candidates where pairs[candidate.e] == nil && !used.contains(candidate.r) {
            pairs[candidate.e] = candidate.r
            used.insert(candidate.r)
        }
        return (pairs, received.indices.filter { !used.contains($0) })
    }

    // MARK: Aggregate

    static func summarize(_ results: [ActionResult]) -> ReportSummary {
        let measuredStatuses: Set<ActionStatus> = [.delivered, .partial, .missing]
        let measured = results.filter { measuredStatuses.contains($0.status) }
        let delivered = measured.filter { $0.status == .delivered }.count
        var statusCounts: [String: Int] = [:]
        var anomalyCounts: [String: Int] = [:]
        for result in results {
            statusCounts[result.status.rawValue, default: 0] += 1
            for anomaly in result.anomalies { anomalyCounts[anomaly.rawValue, default: 0] += 1 }
        }
        let expectedContacts = measured.reduce(0) { $0 + $1.expectedContacts }
        let deliveredContacts = measured.reduce(0) { $0 + $1.contactsDelivered }
        let contacts = measured.flatMap(\.contacts)
        let starts = contacts.compactMap(\.startError)
        let holds = contacts.compactMap(\.holdError)

        var byKind: [String: KindSummary] = [:]
        for kind in Set(results.map(\.kind)) {
            let ofKind = results.filter { $0.kind == kind }
            let measuredOfKind = ofKind.filter { measuredStatuses.contains($0.status) }
            let kindContacts = measuredOfKind.flatMap(\.contacts)
            byKind[kind] = KindSummary(
                sent: ofKind.filter(\.dispatch.sent).count, measured: measuredOfKind.count,
                delivered: measuredOfKind.filter { $0.status == .delivered }.count,
                startError: Distribution.of(kindContacts.compactMap { $0.startError?.distance }),
                holdErrorAbsolute: Distribution.of(kindContacts.compactMap { $0.holdError.map(abs) }))
        }

        var rows: [Int: [Int]] = [:]
        for result in measured where result.source == .log || result.source == .readout {
            rows[result.expectedMaxActive, default: []].append(result.receivedMaxActive ?? 0)
        }
        let contactCounts = rows.keys.sorted().map { expected in
            let values = rows[expected] ?? []
            return ContactCountRow(expected: expected, actions: values.count, reached: values.filter { $0 >= expected }.count,
                                   receivedMaxActive: Distribution.of(values.map(Double.init)))
        }

        func rate(_ numerator: Int, _ denominator: Int) -> Double? {
            denominator > 0 ? ProbeJSON.round(Double(numerator) / Double(denominator), 4) : nil
        }
        return ReportSummary(
            actionsPlanned: results.count, actionsSent: results.filter(\.dispatch.sent).count, actionsMeasured: measured.count,
            statusCounts: statusCounts, deliveryRate: rate(delivered, measured.count),
            contactsExpected: expectedContacts, contactsDelivered: deliveredContacts,
            contactDeliveryRate: rate(deliveredContacts, expectedContacts),
            startError: Distribution.of(starts.map(\.distance)), startDx: Distribution.of(starts.map(\.dx)),
            startDy: Distribution.of(starts.map(\.dy)),
            endError: Distribution.of(contacts.compactMap { $0.endError?.distance }),
            holdError: Distribution.of(holds), holdErrorAbsolute: Distribution.of(holds.map(abs)),
            byKind: byKind, contactCounts: contactCounts, anomalyCounts: anomalyCounts)
    }

    static func facts(_ log: ParsedProbeLog?) -> LogFacts {
        guard let log else {
            return LogFacts(available: false, sessions: [], malformedLines: 0, incompleteFinalLine: false, sequenceBreaks: 0)
        }
        return LogFacts(
            available: true,
            sessions: log.sessions.map {
                LogSessionFacts(session: $0.session, reason: $0.header?.reason, events: $0.events.count,
                                contiguousThrough: $0.contiguousThrough, firstDroppedSeq: $0.truncation?.firstDroppedSeq)
            },
            malformedLines: log.malformedLines.count, incompleteFinalLine: log.incompleteFinalLine,
            sequenceBreaks: log.sequenceBreaks)
    }
}
