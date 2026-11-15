import Foundation
import Testing
@testable import ProbeAnalysis
import ProbeCore
@testable import ProbeTouchRunner

/// End-to-end runner logic against a fake device: canned tree output, receipts and pulled logs.
@Suite struct RunnerTests {
    let device = "00008000-TESTDEVICE"

    private func setup(plan: TouchPlan = .builtIn, configure: (inout RunOptions) -> Void = { _ in })
        -> (TouchRunner, FakeDevice, MemoryFileSystem, FakeClock) {
        let fs = MemoryFileSystem()
        var options = RunOptions(device: device)
        options.outputDirectory = "tmp/probe-touch/test-run"
        configure(&options)
        if let path = options.planPath { fs.files[path] = try? JSONEncoder().encode(plan) }
        let fake = FakeDevice(fileSystem: fs, device: device, actions: plan.actions.map(\.action))
        let clock = FakeClock()
        return (TouchRunner(options: options, invoker: fake, fileSystem: fs, clock: clock), fake, fs, clock)
    }

    private func operations(_ fake: FakeDevice) -> [String] { fake.invocations.map { $0.count > 2 ? $0[2] : "?" } }

    @Test func fullRunWithPerfectDelivery() throws {
        let (runner, fake, fs, clock) = setup()
        let outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        let count = TouchPlan.builtIn.actions.count
        var expected = ["tree", "press-id", "tree"]
        for action in TouchPlan.builtIn.actions { expected += [action.action.kind, "tree"] }
        expected.append("pull")
        #expect(operations(fake) == expected)
        #expect(fake.invocations.allSatisfy { $0.first == "physical" && $0[1] == device })
        #expect(fake.invocations.last == ["physical", device, "pull", RunOptions.defaultBundleID,
                                          "Documents/touch-log.jsonl", "tmp/probe-touch/test-run/touch-log.jsonl"])
        #expect(clock.sleeps == Array(repeating: TouchPlan.defaultSettleSeconds, count: count))

        let report = try #require(outcome.report)
        #expect(report.summary.deliveryRate == 1)
        #expect(report.actions.allSatisfy { $0.source == .log })
        for file in ["plan.json", "run.json", "report.json", "summary.txt", "touch-log.jsonl"] {
            #expect(fs.files["tmp/probe-touch/test-run/\(file)"] != nil, "missing \(file)")
        }
        #expect(fs.files["tmp/probe-touch/test-run/raw/001-preflight.stdout"] != nil)
        let record = try JSONDecoder().decode(RunRecord.self, from: try #require(fs.files["tmp/probe-touch/test-run/run.json"]))
        #expect(record.completed)
        #expect(record.attempts.count == count)
        #expect(record.baseline?.summary.session == "bbbbbbbbbbbbbbbb")
        #expect(record.preflight?.summary.session == "aaaaaaaaaaaaaaaa")
        #expect(record.steps.count == expected.count)
        #expect(record.deviceStateLeft.contains { $0.contains("presses no button") })
        #expect(outcome.output.contains("Run directory: tmp/probe-touch/test-run"))

        // `compare` rebuilds the same report from the run directory.
        let again = TouchRunner.compare(directory: "tmp/probe-touch/test-run", fileSystem: fs)
        #expect(again.report == report)
    }

    @Test func refusesWhenTheProbeIsNotForeground() {
        let (runner, fake, fs, _) = setup()
        fake.foreground = false
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(operations(fake) == ["tree"])
        #expect(outcome.record?.stop?.reason.contains("not the foreground app") == true)
        #expect(outcome.report == nil)
        #expect(fs.files["tmp/probe-touch/test-run/report.json"] == nil)
        #expect(outcome.record?.attempts.allSatisfy { !$0.dispatch.sent } == true)
    }

    @Test func stopsWhenTheResetIsNotObserved() {
        let (runner, fake, _, _) = setup()
        fake.resetTakesEffect = false
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(operations(fake) == ["tree", "press-id", "tree"])
        #expect(outcome.record?.stop?.reason.contains("reset was not observed") == true)
    }

    @Test func stopsWhenAContactIsDownBeforeInput() {
        let (runner, fake, _, _) = setup()
        fake.simulator.deliver(.longPress(NormalizedPoint(0.5, 0.5), seconds: 1), .init(keepDown: [0]))
        let outcome = runner.execute()
        #expect(operations(fake) == ["tree"])
        #expect(outcome.record?.stop?.reason.contains("contact(s) are down") == true)
    }

    @Test func dispatchFailuresAreRecordedNeverRetriedAndStopAfterThree() throws {
        let plan = TouchPlan(name: "taps", actions: (1...6).map {
            PlannedAction(id: "tap-\($0)", action: .tap(NormalizedPoint(0.2 + Double($0) * 0.1, 0.5)))
        })
        let (runner, fake, _, _) = setup(plan: plan) { $0.planPath = "tmp/plan.json" }
        fake.actionExitCodes = [0: 1, 2: 1, 3: 1, 4: 1]
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        // Each action is invoked at most once; the readback still follows each failure.
        let actionCalls = fake.invocations.filter { $0[2] == "tap" }
        #expect(actionCalls.count == 5)
        #expect(Set(actionCalls.map { $0 }).count == 5)
        #expect(outcome.record?.stop?.reason.contains("3 consecutive dispatch failures") == true)
        let report = try #require(outcome.report)
        #expect(report.actions.map(\.dispatch.state) == [.failed, .dispatched, .failed, .failed, .failed, .notSent])
        #expect(report.actions[0].status == .missing)
        #expect(report.actions[0].anomalies == [.dispatchFailed])
        #expect(report.actions[5].status == .notSent)
        #expect(report.summary.actionsSent == 5)
    }

    @Test func stopsAfterAStuckContact() throws {
        let (runner, fake, _, _) = setup()
        fake.deliveries = [1: .init(keepDown: [0])]
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(fake.sentActions == 2)
        #expect(outcome.record?.stop?.reason.contains("still down") == true)
        #expect(outcome.record?.deviceStateLeft.contains { $0.contains("release is unverified") } == true)
        let report = try #require(outcome.report)
        #expect(report.actions[1].anomalies.contains(.contactsStillDown))
        #expect(report.actions.dropFirst(2).allSatisfy { $0.status == .notSent })
        // The log is still pulled: reading it sends no input.
        #expect(fake.invocations.last?[2] == "pull")
    }

    @Test func stopsWhenAReadbackFailsAndKeepsTheEvidence() throws {
        let (runner, fake, _, _) = setup()
        fake.failingTrees = [5]   // preflight, baseline, readback 1, readback 2, readback 3 fails
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(fake.sentActions == 3)
        let report = try #require(outcome.report)
        #expect(report.actions[0].status == .delivered)
        #expect(report.actions[2].status == .delivered)
        #expect(report.actions[2].anomalies == [.openWindow])
        #expect(report.actions[3].status == .notSent)
        #expect(operations(fake).suffix(2) == ["tree", "pull"])
    }

    @Test func relaunchMidRunIsReportedAndTheRunContinues() throws {
        let (runner, fake, _, _) = setup()
        // Before readback 3 (tree call 5) the app relaunched and someone tapped it.
        fake.beforeTree = [5: { $0.relaunch(session: "ffffffffffffffff"); $0.strayTap(NormalizedPoint(0.5, 0.5)) }]
        let outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        let report = try #require(outcome.report)
        #expect(report.actions[2].status == .sessionChanged)
        #expect(report.actions[0].source == .recentGestures)
        #expect(report.actions[1].source == .recentGestures)
        #expect(report.actions.dropFirst(3).allSatisfy { $0.status == .delivered && $0.source == .log })
        #expect(report.sessions == ["bbbbbbbbbbbbbbbb", "ffffffffffffffff"])
        #expect(report.unattributed.afterSessionChange == 2)
    }

    @Test func endReadbackModeSplitsByGestureOrder() throws {
        let (runner, fake, _, clock) = setup { $0.readback = .end }
        let outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        #expect(operations(fake).filter { $0 == "tree" }.count == 3)
        #expect(clock.sleeps.count == TouchPlan.builtIn.actions.count)
        let report = try #require(outcome.report)
        #expect(report.actions.allSatisfy { $0.status == .delivered && $0.anomalies == [.assignedByOrder] })

        // One lost tap in end mode makes the whole shared window inseparable.
        let (lossy, lossyFake, _, _) = setup { $0.readback = .end; $0.outputDirectory = "tmp/probe-touch/lossy" }
        lossyFake.deliveries = [0: .init(drop: [0])]
        let lossyReport = try #require(lossy.execute().report)
        #expect(lossyReport.actions.allSatisfy { $0.status == .inseparable })
    }

    @Test func endModeStopsAtTheFirstDispatchFailureWithAClosingRead() throws {
        let (runner, fake, _, _) = setup { $0.readback = .end }
        fake.actionExitCodes = [1: 1]
        let outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitStopped)
        #expect(fake.sentActions == 2)
        #expect(operations(fake).suffix(2) == ["tree", "pull"])
        // One gesture for two actions in the shared window: no honest split.
        let report = try #require(outcome.report)
        #expect(report.actions[0].status == .inseparable)
        #expect(report.actions[1].status == .inseparable)
        #expect(report.actions[1].anomalies.contains(.dispatchFailed))
        #expect(report.actions[2].status == .notSent)
    }

    @Test func timedOutActionIsRecorded() throws {
        let (runner, fake, _, _) = setup()
        fake.timedOutActions = [0]
        let report = try #require(runner.execute().report)
        #expect(report.actions[0].dispatch.state == .timedOut)
        #expect(Set(report.actions[0].anomalies) == [.dispatchFailed, .receivedDespiteDispatchFailure])
    }

    @Test func failedOrDirectoryPulls() throws {
        let (runner, fake, _, _) = setup()
        fake.pullExitCode = 1
        let outcome = runner.execute()
        let report = try #require(outcome.report)
        #expect(outcome.exitCode == 0)
        #expect(report.log.available == false)
        // Every per-action window is covered by its recent-gestures readout.
        #expect(report.actions.allSatisfy { $0.source == .recentGestures && $0.status == .delivered })
        #expect(report.summary.sourceCounts == ["recent-gestures": TouchPlan.builtIn.actions.count])
        #expect(report.notes.contains { $0.contains("Log pull failed") })

        let (second, secondFake, _, _) = setup { $0.outputDirectory = "tmp/probe-touch/dir-pull" }
        secondFake.pullCreatesDirectory = true
        let directoryReport = try #require(second.execute().report)
        #expect(directoryReport.log.available)
        #expect(directoryReport.actions.allSatisfy { $0.source == .log })
    }

    @Test func refusesAnExistingRunDirectoryAndInvalidPlans() {
        let (runner, fake, fs, _) = setup()
        try? fs.createDirectory("tmp/probe-touch/test-run")
        #expect(runner.execute().exitCode == TouchRunner.exitUsage)
        #expect(fake.invocations.isEmpty)

        let bad = TouchPlan(name: "bad", actions: [PlannedAction(id: "x", action: .tap(NormalizedPoint(2, 0.5)))])
        let (badRunner, badFake, _, _) = setup(plan: bad) { $0.planPath = "tmp/bad.json"; $0.dryRun = true }
        let outcome = badRunner.execute()
        #expect(outcome.exitCode == TouchRunner.exitUsage)
        #expect(outcome.output.contains("invalid"))
        #expect(badFake.invocations.isEmpty)
    }

    @Test func dryRunContactsNoDevice() {
        let (runner, fake, fs, _) = setup { $0.dryRun = true; $0.repeatCount = 2 }
        // Without the Manzanero binary nothing at all is invoked.
        var outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        #expect(fake.invocations.isEmpty)
        #expect(fs.files.isEmpty)
        #expect(outcome.output.contains("28 sent action(s)"))
        #expect(outcome.output.contains(".build/debug/manzanero physical \(device) tap 0.5 0.45"))
        #expect(outcome.output.contains("press-id probe.touch.reset"))
        #expect(outcome.output.contains("CLI check skipped"))

        // With it, every distinct command is checked through `--dry-run` only.
        fs.files[".build/debug/manzanero"] = Data()
        outcome = runner.execute()
        #expect(outcome.exitCode == 0)
        #expect(!fake.invocations.isEmpty)
        #expect(fake.invocations.allSatisfy { $0.first == "--dry-run" })
        #expect(fake.invocations.count == TouchPlan.builtIn.actions.count + 3)
        #expect(outcome.output.contains("17/17 distinct commands accepted"))

        fake.rejectDryRun = { $0.contains("multi-tap") }
        outcome = runner.execute()
        #expect(outcome.exitCode == TouchRunner.exitUsage)
        #expect(outcome.output.contains("rejected: physical \(device) multi-tap"))
    }

    @Test func simulatorPlatformAddressesTheSimulatorAndSkipsThePull() throws {
        let simulator = "11111111-2222-3333-4444-555555555555"
        let command = try RunnerArguments.parse(["run", simulator, "--platform", "simulator"])
        guard case .run(var options) = command else { Issue.record("expected run"); return }
        #expect(options.platform == "simulator" && !options.pull)
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--platform", "simulator"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", simulator, "--platform", "tvos"]) }
        #expect(try RunnerArguments.parse(["run", device]) == .run(RunOptions(device: device)))

        let fs = MemoryFileSystem()
        options.outputDirectory = "tmp/probe-touch/simulator-run"
        let fake = FakeDevice(fileSystem: fs, device: simulator, actions: TouchPlan.builtIn.actions.map(\.action))
        fake.platform = "simulator"
        let outcome = TouchRunner(options: options, invoker: fake, fileSystem: fs, clock: FakeClock()).execute()
        #expect(outcome.exitCode == 0)
        #expect(fake.invocations.allSatisfy { $0.first == "simulator" && $0[1] == simulator })
        #expect(!operations(fake).contains("pull") && fs.files["tmp/probe-touch/simulator-run/touch-log.jsonl"] == nil)
        let report = try #require(outcome.report)
        #expect(report.summary.deliveryRate == 1)
        #expect(!report.actions.contains { $0.source == .log })

        options.dryRun = true
        let dry = TouchRunner(options: options, invoker: fake, fileSystem: MemoryFileSystem(), clock: FakeClock()).execute()
        #expect(dry.output.contains("Platform: simulator; no log pull"))
        #expect(dry.output.contains(".build/debug/manzanero simulator \(simulator) tap 0.5 0.45"))
        #expect(!dry.output.contains(" pull "))
    }

    @Test func argumentParsing() throws {
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", "--dry-run"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", "<UDID>"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--repeat", "0"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--readback", "sometimes"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--bundle-id", "noDots"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--plan"]) }
        #expect(throws: RunnerError.self) { try RunnerArguments.parse(["run", device, "--retry"]) }
        let command = try RunnerArguments.parse(["run", device, "--dry-run", "--repeat", "3", "--readback", "end",
                                                 "--settle", "1", "--bundle-id", "com.example.probe", "--no-pull", "--no-reset",
                                                 "--plan", "tmp/p.json", "--out", "tmp/out", "--manzanero", "bin/m"])
        guard case .run(let options) = command else { Issue.record("expected run"); return }
        #expect(options.dryRun && !options.pull && !options.reset)
        #expect(options.repeatCount == 3)
        #expect(options.readback == .end)
        #expect(options.settleOverride == 1)
        #expect(options.bundleID == "com.example.probe")
        #expect(options.planPath == "tmp/p.json")
        #expect(options.outputDirectory == "tmp/out")
        #expect(options.manzanero == "bin/m")
        #expect(try RunnerArguments.parse([]) == .help)
        #expect(try RunnerArguments.parse(["compare", "tmp/x"]) == .compare(directory: "tmp/x"))
        #expect(try RunnerArguments.parse(["plan"]) == .printPlan)
    }

    @Test func treeParsing() throws {
        let simulator = ProbeSimulator()
        let observation = try ProbeTree.observe(simulator.treeJSON())
        #expect(observation.readback.summary.session == simulator.session)
        #expect(observation.readback.lastGesture?.gesture == 0)
        #expect(observation.portrait)
        #expect(observation.pid == 4242)
        #expect(throws: RunnerError.self) { try ProbeTree.observe(otherAppTree) }
        #expect(throws: RunnerError.self) { try ProbeTree.observe(Data("[]".utf8)) }
        let badValue = treeDocument(nodes: [["id": "0", "identifier": "probe.touch.summary", "value": "{\"v\":2}"]])
        #expect(throws: RunnerError.self) { try ProbeTree.observe(badValue) }
        let duplicate = treeDocument(nodes: [["id": "0", "identifier": "probe.touch.summary", "value": "{}"],
                                             ["id": "1", "identifier": "probe.touch.summary", "value": "{}"]])
        #expect(throws: RunnerError.self) { try ProbeTree.observe(duplicate) }
        #expect(ProbeTree.receiptStatus(Data(#"{"status":"dispatched"}"#.utf8)) == "dispatched")
        #expect(ProbeTree.receiptStatus(Data("oops".utf8)) == nil)
        #expect(shellQuoted(["a", "b c", "it's", #"{"x":1}"#]) == #"a 'b c' 'it'\''s' '{"x":1}'"#)
    }
}
