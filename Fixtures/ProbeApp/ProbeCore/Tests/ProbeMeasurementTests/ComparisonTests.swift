import Foundation
import Testing
@testable import ProbeAnalysis
@testable import ProbeCore

@Suite struct ComparisonTests {
    private func compare(_ run: (baseline: ProbeReadback, attempts: [ActionAttempt], simulator: ProbeSimulator),
                         log: Data? = nil, useLog: Bool = true) -> TouchReport {
        TouchComparison.compare(ComparisonInput(
            planName: "test", tolerances: defaultTolerances, baseline: run.baseline, attempts: run.attempts,
            log: useLog ? ParsedProbeLog.parse(log ?? run.simulator.logData()) : nil))
    }

    /// The same run as an older probe build without `probe.touch.recent-gestures` would report it.
    private func withoutRecent(_ run: (baseline: ProbeReadback, attempts: [ActionAttempt], simulator: ProbeSimulator))
        -> (baseline: ProbeReadback, attempts: [ActionAttempt], simulator: ProbeSimulator) {
        var copy = run
        copy.baseline.recentGestures = nil
        for index in copy.attempts.indices { copy.attempts[index].readback?.recentGestures = nil }
        return copy
    }

    @Test func perfectDeliveryOfEveryKind() {
        let actions = TouchPlan.builtIn.actions.map(\.action)
        let report = compare(simulatedRun(actions))
        #expect(report.actions.allSatisfy { $0.status == .delivered && $0.source == .log })
        #expect(report.actions.allSatisfy { $0.anomalies.isEmpty })
        #expect(report.summary.deliveryRate == 1)
        #expect(report.summary.contactsExpected == 29)
        #expect(report.summary.contactsDelivered == 29)
        #expect(report.summary.startError?.max == 0)
        #expect(report.summary.contactCounts.map(\.expected) == [1, 2, 3, 4, 5])
        #expect(report.summary.contactCounts.allSatisfy { $0.reached == $0.actions })
        #expect(report.unattributed == UnattributedEvents())
        let double = report.actions.first { $0.kind == "gesture" && $0.expectedGestures == 2 }
        #expect(double?.receivedGestures == 2)
    }

    @Test func coordinateAndHoldErrorsAreMeasuredNotJudgedAsLoss() throws {
        let actions: [TouchAction] = [.tap(NormalizedPoint(0.5, 0.5)), .longPress(NormalizedPoint(0.5, 0.5), seconds: 0.8)]
        let report = compare(simulatedRun(actions, deliveries: [0: .init(dx: 0.04, dy: -0.03), 1: .init(holdDelta: 0.3)]))
        let tap = report.actions[0]
        #expect(tap.status == .delivered)
        let error = try #require(tap.contacts[0].startError)
        #expect(abs(error.dx - 0.04) < 1e-4)
        #expect(abs(error.dy + 0.03) < 1e-4)
        #expect(abs(error.distance - 0.05) < 1e-4)
        #expect(tap.anomalies == [.positionOutOfTolerance])
        let press = report.actions[1]
        #expect(press.status == .delivered)
        #expect(abs((press.contacts[0].holdError ?? 0) - 0.3) < 1e-6)
        #expect(press.anomalies == [.durationOutOfTolerance])
        #expect(abs((report.summary.holdError?.max ?? 0) - 0.3) < 1e-6)
    }

    @Test func swipeWithoutMovementIsFlagged() {
        let swipe = TouchAction.swipe(from: NormalizedPoint(0.5, 0.7), to: NormalizedPoint(0.5, 0.3), seconds: 0.5)
        let report = compare(simulatedRun([swipe, swipe], deliveries: [1: .init(noMoves: true)]))
        #expect(report.actions[0].anomalies.isEmpty)
        #expect(report.actions[0].contacts[0].endError?.distance == 0)
        #expect(report.actions[1].anomalies.contains(.noMovement))
    }

    @Test func multiContactShortfallsAreReported() {
        let three = TouchAction.multiTap([NormalizedPoint(0.3, 0.4), NormalizedPoint(0.5, 0.55), NormalizedPoint(0.7, 0.4)])
        let report = compare(simulatedRun([three, three, three, three], deliveries: [
            0: .init(drop: [2]),
            1: .init(serialize: true),
            2: .init(cancel: [1]),
        ]))
        let dropped = report.actions[0]
        #expect(dropped.status == .partial)
        #expect(dropped.receivedContacts == 2)
        #expect(dropped.receivedMaxActive == 2)
        #expect(Set(dropped.anomalies) == [.missingContacts, .maxActiveShort])
        #expect(dropped.contacts.filter { $0.received == nil }.map(\.expected.start) == [NormalizedPoint(0.7, 0.4)])

        // All three arrived, one at a time: three gestures of one contact each.
        let serial = report.actions[1]
        #expect(serial.status == .partial)
        #expect(serial.receivedMaxActive == 1)
        #expect(serial.receivedGestures == 3)
        #expect(Set(serial.anomalies) == [.maxActiveShort, .gestureCountMismatch])

        let cancelled = report.actions[2]
        #expect(cancelled.status == .partial)
        #expect(cancelled.anomalies == [.cancelledContacts])
        #expect(cancelled.contactsDelivered == 2)

        #expect(report.actions[3].status == .delivered)
        let row = report.summary.contactCounts.first { $0.expected == 3 }
        #expect(row?.actions == 4)
        #expect(row?.reached == 2)
        #expect(report.summary.contactsDelivered == 2 + 3 + 2 + 3)
    }

    @Test func nothingReceivedAndStrayEvents() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        // Action 1 never arrives; action 2 arrives with a stray tap in its window; a stray tap follows the run.
        let report = compare(simulatedRun([tap, tap], deliveries: [0: .init(drop: [0])], afterAction: [
            1: { $0.strayTap(NormalizedPoint(0.3, 0.3)) },
        ]))
        #expect(report.actions[0].status == .missing)
        #expect(report.actions[0].receivedContacts == 0)
        let second = report.actions[1]
        #expect(second.status == .partial)
        #expect(second.extraContacts.count == 1)
        // The pattern also fits a late first tap, so both are flagged as a suspicion only.
        #expect(Set(second.anomalies) == [.extraContacts, .gestureCountMismatch, .lateDeliverySuspected])
        #expect(report.summary.deliveryRate == 0)
        #expect(report.summary.statusCounts == ["missing": 1, "partial": 1])
    }

    @Test func eventsArrivingAfterTheirReadbackAreFlaggedNotReassigned() {
        let first = TouchAction.tap(NormalizedPoint(0.3, 0.4))
        let second = TouchAction.tap(NormalizedPoint(0.7, 0.6))
        // Action 1's tap lands only after its readback, inside action 2's window.
        let report = compare(simulatedRun([first, second], deliveries: [0: .init(drop: [0])],
                                          beforeAction: [1: { $0.deliver(first) }]))
        #expect(report.actions[0].status == .missing)
        #expect(report.actions[0].anomalies == [.lateDeliverySuspected])
        #expect(report.actions[1].status == .partial)
        #expect(Set(report.actions[1].anomalies) == [.extraContacts, .gestureCountMismatch, .lateDeliverySuspected])
        #expect(report.actions[1].contacts[0].startError?.distance == 0)
        #expect(report.notes.contains { $0.contains("longer --settle") })
    }

    @Test func eventsOutsideEveryWindowAreUnattributed() {
        // A reset press delivered as a tap before the baseline, and a touch after the final readback.
        var simulator = ProbeSimulator()
        simulator.reset(session: "bbbbbbbbbbbbbbbb")
        simulator.strayTap(NormalizedPoint(0.5, 0.87))
        let baseline = simulator.readback()
        simulator.deliver(.tap(NormalizedPoint(0.5, 0.5)))
        let attempt = ActionAttempt(sequence: 1, round: 1, planned: PlannedAction(id: "a1", action: .tap(NormalizedPoint(0.5, 0.5))),
                                    dispatch: DispatchOutcome(state: .dispatched), readback: simulator.readback())
        simulator.strayTap(NormalizedPoint(0.4, 0.4))
        let report = TouchComparison.compare(ComparisonInput(planName: "t", tolerances: defaultTolerances, baseline: baseline,
                                                             attempts: [attempt], log: ParsedProbeLog.parse(simulator.logData())))
        #expect(report.actions[0].status == .delivered)
        #expect(report.unattributed.beforeRun == 2)
        #expect(report.unattributed.afterRun == 2)
    }

    @Test func sessionChangeMidRunFallsBackToReadouts() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        // The app relaunches after action 2 delivered; action 3 lands in the new session.
        let run = simulatedRun([tap, tap, tap, tap], afterAction: [
            1: { $0.relaunch(session: "eeeeeeeeeeeeeeee"); $0.deliver(.tap(NormalizedPoint(0.5, 0.5))) },
        ])
        let report = compare(run)
        // The log was replaced at relaunch: action 1 is read from its recent-gestures readout.
        #expect(report.actions[0].status == .delivered)
        #expect(report.actions[0].source == .recentGestures)
        #expect(report.actions[0].anomalies == [.logUnusable])
        // Without that readout (an older probe build), the last-gesture readout stands in as before.
        let lastOnly = compare(withoutRecent(run))
        #expect(lastOnly.actions[0].status == .delivered)
        #expect(lastOnly.actions[0].source == .readout)
        #expect(lastOnly.actions[0].anomalies == [.logUnusable])
        #expect(report.actions[1].status == .sessionChanged)
        #expect(report.actions[1].source == EvidenceSource.none)
        #expect(report.actions[2].source == .log)
        #expect(report.actions[2].status == .delivered)
        #expect(report.sessions == ["bbbbbbbbbbbbbbbb", "eeeeeeeeeeeeeeee"])
        #expect(report.unattributed.afterSessionChange == 2)
        #expect(report.summary.actionsMeasured == 3)
    }

    @Test func truncatedLogFallsBackPerWindow() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        let double = TouchPlan.builtIn.actions.first { $0.id == "sequence-double-tap" }!.action
        let run = simulatedRun([tap, tap, double])
        // Keep header and the first action's two events, then the truncation marker.
        var lines = Array(run.simulator.lines.prefix(3))
        lines.append(ProbeJSON.encode(TruncationRecord(session: run.simulator.session, firstDroppedSeq: 3, limitBytes: 4096)))
        let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let report = compare(run, log: data)
        #expect(report.actions[0].source == .log)
        #expect(report.actions[1].source == .recentGestures)
        #expect(report.actions[1].status == .delivered)
        // Two gestures in one window: the recent readout lists both, so contacts are measured.
        #expect(report.actions[2].source == .recentGestures)
        #expect(report.actions[2].status == .delivered)
        #expect(report.actions[2].receivedGestures == 2)
        #expect(report.actions[2].contacts.count == 2)
        #expect(report.actions[2].contacts.allSatisfy { $0.startError?.distance == 0 && $0.holdError == 0 })
        #expect(report.log.sessions[0].firstDroppedSeq == 3)

        // Without the recent readout: the last-gesture readout, then summary counters, as before.
        let lastOnly = compare(withoutRecent(run), log: data)
        #expect(lastOnly.actions[1].source == .readout)
        #expect(lastOnly.actions[1].status == .delivered)
        // The last-gesture readout shows only the second of the two gestures.
        #expect(lastOnly.actions[2].source == .summary)
        #expect(lastOnly.actions[2].status == .delivered)
        #expect(lastOnly.actions[2].contacts.isEmpty)
    }

    @Test func sharedWindowsAreSplitByOrderOrDeclaredInseparable() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        var run = simulatedRun([tap, tap, tap, tap], deliveries: [3: .init(drop: [0])])
        // Readbacks after actions 1 and 3 failed: (1,2) share a window, and so do (3,4).
        run.attempts[0].readback = nil
        run.attempts[2].readback = nil
        let report = compare(run)
        #expect(report.actions[0].status == .delivered)
        #expect(report.actions[0].anomalies == [.assignedByOrder])
        #expect(report.actions[0].window?.actions == [1, 2])
        #expect(report.actions[1].status == .delivered)
        // One gesture for two expected: no honest split.
        #expect(report.actions[2].status == .inseparable)
        #expect(report.actions[3].status == .inseparable)
        #expect(report.summary.actionsMeasured == 2)

        // Without a log, the recent readout splits a shared window by the same order rule.
        let noLog = compare(run, useLog: false)
        #expect(noLog.actions[0].status == .delivered)
        #expect(noLog.actions[0].source == .recentGestures)
        #expect(noLog.actions[0].anomalies == [.assignedByOrder])
        #expect(noLog.actions[1].status == .delivered)
        #expect(noLog.actions[2].status == .inseparable)
        #expect(noLog.actions[3].status == .inseparable)
        #expect(noLog.notes.contains { $0.contains("No log") })

        // Without a log or the recent readout, a shared window cannot be split at all.
        let countsOnly = compare(withoutRecent(run), useLog: false)
        #expect(countsOnly.actions.allSatisfy { $0.status == .inseparable })
    }

    @Test func openFinalWindowIsClosedByTheLog() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        var run = simulatedRun([tap, tap])
        run.attempts[1].readback = nil
        let report = compare(run)
        #expect(report.actions[1].status == .delivered)
        #expect(report.actions[1].anomalies == [.openWindow])
        #expect(report.actions[1].window?.throughSeq == nil)
        let withoutLog = compare(run, useLog: false)
        #expect(withoutLog.actions[1].status == .noData)
    }

    @Test func dispatchFailuresAndUnsentActions() {
        let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
        var run = simulatedRun([tap, tap, tap], deliveries: [1: .init(cancel: [0])])
        run.attempts[0].dispatch = DispatchOutcome(state: .failed, exitCode: 1, message: "Primary display is off.")
        run.attempts[1].dispatch = DispatchOutcome(state: .failed, exitCode: 1)
        run.attempts[2] = ActionAttempt(sequence: 3, round: 1, planned: run.attempts[2].planned,
                                        dispatch: DispatchOutcome(state: .notSent), readback: nil)
        let report = compare(run)
        // The device received action 1 although the command failed.
        #expect(report.actions[0].status == .delivered)
        #expect(Set(report.actions[0].anomalies) == [.dispatchFailed, .receivedDespiteDispatchFailure])
        #expect(Set(report.actions[1].anomalies) == [.dispatchFailed, .receivedDespiteDispatchFailure, .cancelledContacts])
        #expect(report.actions[2].status == .notSent)
        #expect(report.summary.actionsSent == 2)
        #expect(report.summary.actionsPlanned == 3)
        // Events of the unsent action's would-be window are after the run.
        #expect(report.unattributed.afterRun == 2)
    }

    @Test func stuckContactAndUnmatchedCallbacks() {
        let press = TouchAction.longPress(NormalizedPoint(0.5, 0.5), seconds: 0.5)
        let run = simulatedRun([press], deliveries: [0: .init(keepDown: [0])])
        let report = compare(run)
        let result = report.actions[0]
        #expect(result.status == .partial)
        #expect(Set(result.anomalies) == [.unfinishedContacts, .contactsStillDown])
        #expect(result.contacts[0].holdError == nil)
        #expect(report.summary.contactsDelivered == 0)
    }

    @Test func distributionStatistics() throws {
        let d = try #require(Distribution.of([0.3, 0.1, 0.2, 0.4]))
        #expect(d.count == 4)
        #expect(d.min == 0.1)
        #expect(d.median == 0.25)
        #expect(d.mean == 0.25)
        #expect(d.max == 0.4)
        #expect(Distribution.of([]) == nil)
        #expect(Distribution.of([.nan, 1])?.count == 1)
    }

    @Test func reportEncodesAndSummarises() throws {
        let report = compare(simulatedRun([.tap(NormalizedPoint(0.5, 0.5))], deliveries: [0: .init(dx: 0.01)]))
        let object = try #require(try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
        #expect(Set(object.keys) == ["v", "plan", "tolerances", "sessions", "summary", "actions", "log", "unattributed", "notes"])
        let decoded = try JSONDecoder().decode(TouchReport.self, from: report.json())
        #expect(decoded == report)
        let text = report.text()
        #expect(text.contains("Delivery rate: 100.0% of measured actions; contacts 1/1"))
        #expect(text.contains("#1 r1 a1 [tap] delivered via log"))
        #expect(text.contains("worst start error 0.0100"))
    }
}
