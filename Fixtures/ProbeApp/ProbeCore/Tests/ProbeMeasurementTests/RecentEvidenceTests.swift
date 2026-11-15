import Foundation
import Testing
@testable import ProbeAnalysis
@testable import ProbeCore
@testable import ProbeTouchRunner

private typealias Run = (baseline: ProbeReadback, attempts: [ActionAttempt], simulator: ProbeSimulator)

/// The evidence order (log, recent-gestures readout, last-gesture readout, summary counts) and the
/// coverage proof for the recent-gestures readout.
@Suite struct RecentEvidenceTests {
    private let tap = TouchAction.tap(NormalizedPoint(0.5, 0.5))
    private let double = TouchPlan.builtIn.actions.first { $0.id == "sequence-double-tap" }!.action

    private func compare(_ run: Run, log: Bool = false, expectedBundleID: String? = nil) -> TouchReport {
        TouchComparison.compare(ComparisonInput(
            planName: "test", tolerances: defaultTolerances, baseline: run.baseline, attempts: run.attempts,
            log: log ? ParsedProbeLog.parse(run.simulator.logData()) : nil, expectedBundleID: expectedBundleID))
    }

    private func replacingRecent(_ run: Run, at index: Int, _ change: (RecentGesturesReadout) -> RecentGesturesReadout?) -> Run {
        var copy = run
        if let recent = copy.attempts[index].readback?.recentGestures {
            copy.attempts[index].readback?.recentGestures = change(recent)
        }
        return copy
    }

    @Test func theLogStaysFirstWhenItCoversTheWindow() {
        let report = compare(simulatedRun([tap, double]), log: true)
        #expect(report.actions.map(\.source) == [.log, .log])
        #expect(report.summary.sourceCounts == ["log": 2])
    }

    @Test func aMultiGestureActionIsMeasuredFromTheRecentReadoutWithoutALog() throws {
        let report = compare(simulatedRun([tap, double]))
        let result = report.actions[1]
        #expect(result.source == .recentGestures)
        #expect(result.status == .delivered)
        #expect(result.receivedGestures == 2)
        #expect(result.contacts.count == 2)
        #expect(result.contacts.map(\.gesture) == [0, 1])
        #expect(result.contacts.allSatisfy { $0.startError?.distance == 0 && $0.holdError == 0 })
        #expect(result.anomalies.isEmpty)
        #expect(report.summary.sourceCounts == ["recent-gestures": 2])
        #expect(report.text().contains("Evidence: recent-gestures 2"))
        #expect(report.text().contains("delivered via recent-gestures"))
    }

    @Test func errorsAndShortfallsAreMeasuredFromTheRecentReadout() {
        let three = TouchAction.multiTap([NormalizedPoint(0.3, 0.4), NormalizedPoint(0.5, 0.55), NormalizedPoint(0.7, 0.4)])
        let report = compare(simulatedRun([three, three], deliveries: [0: .init(dx: 0.05, drop: [2]), 1: .init(cancel: [0])]))
        #expect(report.actions.allSatisfy { $0.source == .recentGestures })
        #expect(report.actions[0].status == .partial)
        #expect(Set(report.actions[0].anomalies) == [.missingContacts, .maxActiveShort, .positionOutOfTolerance])
        #expect(report.actions[1].status == .partial)
        #expect(report.actions[1].anomalies == [.cancelledContacts])
    }

    @Test func droppedGesturesInTheWindowFallBackWithAReason() throws {
        // 33 stray taps inside one window: 34 gestures, but the readout lists only the newest 32.
        let run = simulatedRun([tap, tap], afterAction: [1: { simulator in
            for n in 0..<33 { simulator.strayTap(NormalizedPoint(0.3 + Double(n % 10) * 0.04, 0.4)) }
        }])
        let readout = try #require(run.attempts[1].readback?.recentGestures)
        #expect(readout.dropped == 3)
        let report = compare(run)
        #expect(report.actions[0].source == .recentGestures)
        // Gesture 2 of the window was dropped, so the proof fails; one action, many gestures: counts only.
        #expect(report.actions[1].source == .summary)
        #expect(report.actions[1].notes.contains { $0.contains("not all listed; the oldest listed is 4") })
    }

    @Test func gesturesDroppedBeforeTheWindowDoNotMatter() throws {
        // 40 earlier gestures in the session overflow the readout, but the window's own gesture is listed.
        var simulator = ProbeSimulator()
        simulator.reset(session: "bbbbbbbbbbbbbbbb")
        for n in 0..<40 { simulator.strayTap(NormalizedPoint(0.3 + Double(n % 10) * 0.04, 0.4)) }
        let baseline = simulator.readback()
        simulator.deliver(double)
        let attempt = ActionAttempt(sequence: 1, round: 1, planned: PlannedAction(id: "d", action: double),
                                    dispatch: DispatchOutcome(state: .dispatched), readback: simulator.readback())
        #expect((attempt.readback?.recentGestures?.dropped ?? 0) == 10)
        let report = compare((baseline, [attempt], simulator))
        #expect(report.actions[0].source == .recentGestures)
        #expect(report.actions[0].status == .delivered)
        #expect(report.actions[0].receivedGestures == 2)
    }

    @Test func inconsistentNumberingIsNeverTrusted() {
        let run = simulatedRun([tap, tap])
        // The newest entry claims to be listed after a gap: the readout does not prove coverage.
        let gapped = replacingRecent(run, at: 1) { recent in
            RecentGesturesReadout(session: recent.session, gestures: recent.gestures, dropped: 0,
                                  recent: Array(recent.recent.dropFirst()))
        }
        let report = compare(gapped)
        #expect(report.actions[1].source == .readout, "falls back to the last-gesture readout")
        #expect(report.actions[1].status == .delivered)
        #expect(report.actions[1].notes.contains { $0.contains("inconsistent") })
    }

    @Test func aReadoutDisagreeingWithTheSummaryIsNotUsed() {
        let run = simulatedRun([tap, tap])
        // Taken a moment later than the summary: one more gesture than the summary counted.
        let ahead = replacingRecent(run, at: 1) { recent in
            RecentGesturesReadout(session: recent.session, gestures: recent.gestures + 1, dropped: recent.dropped,
                                  recent: recent.recent + [RecentGesture(gesture: recent.gestures + 1, maxActive: 1, duration: 0.08,
                                                                         contacts: recent.recent[0].contacts)])
        }
        #expect(compare(ahead).actions[1].source == .readout)
        #expect(compare(ahead).actions[1].notes.contains { $0.contains("the summary 2") })

        // Contacts that do not account for the phase counters (a moved event the summary did not see).
        let altered = replacingRecent(run, at: 1) { recent in
            var entries = recent.recent
            let c = entries[1].contacts[0]
            entries[1] = RecentGesture(gesture: 2, maxActive: 1, duration: entries[1].duration, contacts: [
                GestureContact(c: c.c, from: c.from, to: c.to, began: c.began, duration: c.duration, end: c.end, moves: 1),
            ])
            return RecentGesturesReadout(session: recent.session, gestures: recent.gestures, dropped: recent.dropped, recent: entries)
        }
        let report = compare(altered)
        #expect(report.actions[1].source == .readout)
        #expect(report.actions[1].notes.contains { $0.contains("1 moved") && $0.contains("0 moved") })

        // Another session's readout.
        let foreign = replacingRecent(run, at: 1) { recent in
            RecentGesturesReadout(session: "ffffffffffffffff", gestures: recent.gestures, dropped: recent.dropped, recent: recent.recent)
        }
        #expect(compare(foreign).actions[1].source == .readout)
    }

    @Test func aContactDownAtTheWindowEndBlocksTheRecentReadout() {
        let press = TouchAction.longPress(NormalizedPoint(0.5, 0.5), seconds: 0.5)
        let report = compare(simulatedRun([tap, press], deliveries: [1: .init(keepDown: [0])]))
        #expect(report.actions[0].source == .recentGestures)
        #expect(report.actions[1].source == .summary)
        #expect(report.actions[1].notes.contains { $0.contains("still down when the window closed") })
    }

    @Test func absentReadoutFallsBackSilently() {
        let run = replacingRecent(simulatedRun([tap, tap]), at: 1) { _ in nil }
        let report = compare(run)
        #expect(report.actions[0].source == .recentGestures)
        #expect(report.actions[1].source == .readout)
        #expect(!report.actions[1].notes.contains { $0.contains("Recent-gestures") })
    }

    @Test func sharedWindowsAreSplitByOrderFromTheRecentReadout() {
        // Readbacks after actions 1 and 2 failed: actions 1-3 share the window closed by readback 3.
        var run = simulatedRun([tap, double, tap])
        run.attempts[0].readback = nil
        run.attempts[1].readback = nil
        let report = compare(run)
        #expect(report.actions.allSatisfy { $0.status == .delivered && $0.source == .recentGestures })
        #expect(report.actions.allSatisfy { $0.anomalies == [.assignedByOrder] })
        #expect(report.actions.map { $0.receivedGestures } == [1, 2, 1])
        #expect(report.actions[0].window?.actions == [1, 2, 3])
    }

    @Test func theBuiltInPlanFitsInOneReadoutWithRoomToSpare() throws {
        let run = simulatedRun(TouchPlan.builtIn.actions.map(\.action))
        let recent = try #require(run.attempts.last?.readback?.recentGestures)
        #expect(recent.gestures == 15)
        #expect(recent.dropped == 0)
        // Measured 3,815 bytes for the whole value (15 gestures, 29 contacts); a one-contact tap entry is 150.
        #expect(ProbeJSON.encode(recent).count < 4500)
        #expect((recent.recent.map { ProbeJSON.encode($0).count }.min() ?? 0) < 200)
    }

    @Test func identityIsReportedPerReadback() throws {
        var run = simulatedRun([tap, tap, tap])
        run.baseline.bundleID = "com.example.probe"
        run.attempts[0].readback?.bundleID = "com.example.probe"
        // Readback 2 reported no attribute; readback 3 another bundle (only a hand-edited record has this).
        run.attempts[2].readback?.bundleID = "com.apple.Preferences"
        let report = compare(run, expectedBundleID: "com.example.probe")
        #expect(report.actions.map(\.identity) == [.matched, .notChecked, .mismatched])
        #expect(report.identity == IdentityFacts(expectedBundleID: "com.example.probe", readbacks: 4, matched: 2,
                                                 notChecked: 1, mismatched: 1))
        #expect(report.notes.contains { $0.contains("1 of 4 readback(s) reported no nativeAttributes") })
        #expect(report.notes.contains { $0.contains("other than com.example.probe") })
        #expect(report.text().contains("Foreground identity (com.example.probe): matched 2, not checked 1, mismatched 1 of 4 readback(s)"))

        // Without an expected identifier, identity stays out of the report.
        let plain = compare(run)
        #expect(plain.identity == nil)
        #expect(plain.actions.allSatisfy { $0.identity == nil })
        let object = try #require(try JSONSerialization.jsonObject(with: plain.json()) as? [String: Any])
        #expect(object["identity"] == nil)
    }
}

/// The runner's foreground identity check and its use of the recent-gestures readout.
@Suite struct RunnerIdentityTests {
    let device = "00008000-TESTDEVICE"

    private func setup(configure: (inout RunOptions) -> Void = { _ in }) -> (TouchRunner, FakeDevice, MemoryFileSystem) {
        let fs = MemoryFileSystem()
        var options = RunOptions(device: device)
        options.outputDirectory = "tmp/probe-touch/identity-run"
        configure(&options)
        let fake = FakeDevice(fileSystem: fs, device: device, actions: TouchPlan.builtIn.actions.map(\.action))
        return (TouchRunner(options: options, invoker: fake, fileSystem: fs, clock: FakeClock()), fake, fs)
    }

    private func operations(_ fake: FakeDevice) -> [String] { fake.invocations.map { $0.count > 2 ? $0[2] : "?" } }

    @Test func treeParsingReadsTheBundleAttributeAndTheRecentReadout() throws {
        var simulator = ProbeSimulator()
        simulator.deliver(.tap(NormalizedPoint(0.5, 0.5)))
        let observed = try ProbeTree.observe(simulator.treeJSON(bundleID: "com.example.probe"))
        #expect(observed.readback.bundleID == "com.example.probe")
        #expect(observed.readback.recentGestures == simulator.recorder.recentGestures)
        #expect(observed.readback.recentGestures?.recent.count == 1)

        let bare = try ProbeTree.observe(simulator.treeJSON(includeRecent: false))
        #expect(bare.readback.bundleID == nil)
        #expect(bare.readback.recentGestures == nil)

        // Metadata without 3003 is not an identity.
        let other = treeDocument(nodes: [["id": "0", "identifier": "probe.touch.summary",
                                          "value": ProbeJSON.string(simulator.readback().summary),
                                          "nativeAttributes": ["5003": "UIAccessibilityElement"]]])
        #expect(try ProbeTree.observe(other).readback.bundleID == nil)

        // Two recent-gestures elements: neither is used.
        let summary = ProbeJSON.string(simulator.readback().summary)
        let recent = ProbeJSON.string(simulator.recorder.recentGestures)
        let twice = treeDocument(nodes: [["id": "0", "identifier": "probe.touch.summary", "value": summary],
                                         ["id": "1", "identifier": "probe.touch.recent-gestures", "value": recent],
                                         ["id": "2", "identifier": "probe.touch.recent-gestures", "value": recent]])
        #expect(try ProbeTree.observe(twice).readback.recentGestures == nil)

        let readback = observed.readback
        #expect(ProbeTree.identityProblem(readback, expected: "com.example.probe") == nil)
        #expect(ProbeTree.identityProblem(readback, expected: "com.example.other")?.contains("belongs to com.example.probe") == true)
        #expect(ProbeTree.identityProblem(bare.readback, expected: "com.example.other") == nil)
    }

    @Test func matchingIdentityIsRecordedForEveryReadback() throws {
        let (runner, fake, _) = setup()
        fake.treeBundleID = RunOptions.defaultBundleID
        let outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        let report = try #require(outcome.report)
        let count = TouchPlan.builtIn.actions.count
        #expect(report.identity == IdentityFacts(expectedBundleID: RunOptions.defaultBundleID, readbacks: count + 1,
                                                 matched: count + 1, notChecked: 0, mismatched: 0))
        #expect(report.actions.allSatisfy { $0.identity == .matched })
        #expect(outcome.record?.preflight?.bundleID == RunOptions.defaultBundleID)
        #expect(!report.notes.contains { $0.contains("nativeAttributes") })
    }

    @Test func absentAttributeIsNotCheckedAndSaysSo() throws {
        let (runner, fake, _) = setup()
        var progress: [String] = []
        let noting = TouchRunner(options: runner.options, invoker: fake, fileSystem: runner.fs, clock: FakeClock()) { progress.append($0) }
        let outcome = noting.execute()
        #expect(outcome.exitCode == 0)
        let report = try #require(outcome.report)
        #expect(report.identity?.notChecked == TouchPlan.builtIn.actions.count + 1)
        #expect(report.identity?.matched == 0)
        #expect(report.actions.allSatisfy { $0.identity == .notChecked })
        #expect(report.notes.contains { $0.contains("was not checked") })
        #expect(progress.filter { $0.contains("is not checked") }.count == 1)
    }

    @Test func aDifferentBundleAtPreflightStopsBeforeAnyInput() {
        let (runner, fake, fs) = setup()
        fake.treeBundleID = "com.apple.Preferences"
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(operations(fake) == ["tree"])
        #expect(outcome.record?.stop?.reason.contains("belongs to com.apple.Preferences") == true)
        #expect(outcome.record?.stop?.reason.contains("Nothing was sent") == true)
        #expect(outcome.record?.preflight == nil)
        #expect(fs.files["tmp/probe-touch/identity-run/report.json"] == nil)
    }

    @Test func aDifferentBundleAtTheBaselineStopsBeforeTouchInput() {
        let (runner, fake, _) = setup()
        fake.treeBundleID = RunOptions.defaultBundleID
        fake.treeBundleIDOverrides = [2: "com.example.other"]
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(operations(fake) == ["tree", "press-id", "tree"])
        #expect(outcome.record?.stop?.reason.hasPrefix("baseline: probe.touch.summary belongs to com.example.other") == true)
    }

    @Test func aDifferentBundleAfterAnActionStopsFurtherInput() throws {
        let (runner, fake, _) = setup()
        fake.treeBundleID = RunOptions.defaultBundleID
        // Tree calls: 1 preflight, 2 baseline, 3 readback 1, 4 readback 2.
        fake.treeBundleIDOverrides = [4: "com.apple.Preferences"]
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(fake.sentActions == 2)
        #expect(outcome.record?.stop?.reason.hasPrefix("readback 2: probe.touch.summary belongs to com.apple.Preferences") == true)
        // Like a missing probe: no closing readback, the mismatched readback is not kept, the log is still pulled.
        #expect(operations(fake).suffix(2) == ["tree", "pull"])
        #expect(outcome.record?.attempts[1].readback == nil)
        let report = try #require(outcome.report)
        #expect(report.actions[0].identity == .matched)
        #expect(report.actions[1].identity == nil)
        #expect(report.actions[1].anomalies == [.openWindow])
        #expect(report.identity?.mismatched == 0)
    }

    @Test func endModeWithoutALogUsesTheRecentReadout() throws {
        let (runner, _, _) = setup { $0.readback = .end; $0.pull = false }
        let report = try #require(runner.execute().report)
        #expect(report.actions.allSatisfy { $0.status == .delivered && $0.source == .recentGestures })
        #expect(report.actions.allSatisfy { $0.anomalies == [.assignedByOrder] })

        // Three rounds are 45 gestures: more than the readout lists, so the window is inseparable.
        let (repeated, _, _) = setup { $0.readback = .end; $0.pull = false; $0.repeatCount = 3; $0.outputDirectory = "tmp/probe-touch/r3" }
        let repeatedReport = try #require(repeated.execute().report)
        #expect(repeatedReport.actions.allSatisfy { $0.status == .inseparable })
        #expect(repeatedReport.actions[0].notes.contains { $0.contains("not all listed") })
    }
}
