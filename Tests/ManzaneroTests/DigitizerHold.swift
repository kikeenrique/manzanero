import AppleDeviceBridge
import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

/// The contacts of one 58-byte report: whether each is down, and where.
private func contacts(_ report: [UInt8]) -> [(active: Bool, x: Int, y: Int)] {
    (0..<Int(report[1])).map { id in
        let offset = 3 + id * 5
        return (report[offset] & 0xc0 != 0, Int(report[offset + 1]) | Int(report[offset + 2]) << 8,
                Int(report[offset + 3]) | Int(report[offset + 4]) << 8)
    }
}

private func position(_ value: Double) -> Int { Int((value * 65535).rounded()) }

/// `hold` and `release` as a batch builds them: every refusal comes before
/// anything runs.
struct HoldBatchBuildTests {
    static let udid = "00008110-000A11112222801E"
    static let target = Target(platform: .physical, identifier: udid)

    @Test func spansNameTheHeldStepsTheMergedTouchStepsAndTheContactCount() throws {
        let batch = try BatchCommand(target: Self.target, steps: [
            ["hold", "0.5", "0.6"], ["swipe", "0.9", "0.0", "0.9", "0.15", "0.25"], ["wait", "--label", "Wi-Fi", "--until", "visible"],
            ["press", "--label", "Wi-Fi"], ["release"], ["hold", "0.1", "0.1"], ["multi-drag", "0.5", "0.1", "0.1", "0.2", "0.2",
            "0.3", "0.3", "0.4", "0.4", "0.5", "0.5", "0.6", "0.6", "0.7", "0.7", "0.8", "0.8"], ["button", "home"]])
        #expect(batch.holds.count == 2)
        let first = batch.holds[0], second = batch.holds[1]
        #expect(first.step == 1 && first.releaseStep == 5 && first.stepsWhileHeld == [2, 3, 4] && first.mergedSteps == [2] && first.contactSlots == 2)
        // A four-path multi-drag fills the digitizer's five contacts; the
        // second hold is released when the batch ends.
        #expect(second.step == 6 && second.releaseStep == nil && second.stepsWhileHeld == [7, 8] && second.mergedSteps == [7] && second.contactSlots == 5)
        #expect(batch.hold(containing: 3)?.step == 1 && batch.hold(containing: 5) == nil && batch.hold(containing: 8)?.step == 6)
    }

    @Test(arguments: [
        ([["hold", "0.5", "0.5"], ["hold", "0.4", "0.4"], ["release"]], "One hold at a time"),
        ([["release"]], "release without a hold"),
        ([["hold", "0.5", "0.5"], ["release"], ["release"]], "release without a hold"),
        // Five paths beside a held contact would be six contacts.
        ([["hold", "0.5", "0.5"], ["multi-drag", "0.5", "0.1", "0.1", "0.2", "0.2", "0.3", "0.3", "0.4", "0.4", "0.5", "0.5", "0.6",
          "0.6", "0.7", "0.7", "0.8", "0.8", "0.9", "0.9", "0.95", "0.95"]], "at most 4 beside a hold"),
        ([["hold", "0.5", "0.5"], ["multi-tap", "0.1", "0.1", "0.2", "0.2", "0.3", "0.3", "0.4", "0.4", "0.5", "0.5"]], "at most 4 beside a hold"),
        ([["hold", "1.5", "0.5"]], "normalized x and y"),
    ])
    func refusedBeforeAnythingRuns(steps: [[String]], message: String) {
        let failure = #expect(throws: CommandFailure.self) { try BatchCommand(target: Self.target, steps: steps) }
        #expect(failure?.code == .usage && failure?.inputSent == CommandFailure.InputSent.none)
        #expect(failure?.description.contains(message) == true && failure?.description.contains("Nothing was run") == true)
    }

    @Test func holdIsRefusedOnASimulator() {
        let simulator = Target(platform: .simulator, identifier: SimulatorDeviceTests.uuid)
        let failure = #expect(throws: CommandFailure.self) { try BatchCommand(target: simulator, steps: [["hold", "0.5", "0.5"], ["release"]]) }
        #expect(failure?.code == .unsupportedOperation && failure?.description.contains("physical device only") == true)
    }

    @Test(arguments: [["hold", "0.5", "0.5"], ["release"]])
    func standaloneStepsAreRefused(words: [String]) async {
        let service = CommandService(readinessQuery: { _ in
            Issue.record("A standalone \(words[0]) queried the device")
            return Data()
        })
        for dryRun in [false, true] {
            let failure = await #expect(throws: CommandFailure.self) {
                _ = try await service.run(words + ["--device", Self.udid], dryRun: dryRun)
            }
            #expect(failure?.code == .usage && failure?.description.contains("batch steps") == true)
            #expect(failure?.inputSent == CommandFailure.InputSent.none)
        }
    }

    @Test func holdAndReleaseRunUnderTheSignalScopeAndAreNotReadOnly() throws {
        let batch = try BatchCommand(target: Self.target, steps: [["hold", "0.5", "0.5"], ["wait", "--id", "x"], ["release"]])
        #expect(CommandRequest.batch(batch).signalContext == "batch" && !CommandRequest.batch(batch).isReadOnly)
        #expect(batch.requests[0].signalContext == "physical input" && batch.requests[2].signalContext == "physical input")
    }

    @Test func mcpRunBatchCarriesHoldAndReleaseAsSteps() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "run_batch" })
        #expect(tool.description.contains("hold"))
        let steps: Value = .array([.array(["hold", "0.5", "0.6"]), .array(["press", "--label", "Wi-Fi"]), .array(["release"])])
        let args = try tool.command(["device": .string(Self.udid), "platform": "physical", "steps": steps])
        let invocation = try CLI.invocation(args)
        #expect(invocation.request == .batch(try BatchCommand(target: Self.target, steps: [["hold", "0.5", "0.6"], ["press", "--label", "Wi-Fi"], ["release"]])))
    }

    @Test func segmentsUseTheSamePlannersAsAlone() throws {
        func segment(_ operation: String, _ operands: [String]) throws -> HoldSegment {
            try HoldSegment(CoreDeviceInput.validated(device: Self.udid, operation: operation, operands: operands))
        }
        let tap = try segment("tap", ["0.2", "0.3"])
        #expect(tap.contactCount == 1 && tap.frames.first?.active == [0] && tap.frames.last?.active == [])
        #expect(tap.frames.first?.positions == [[position(0.2), position(0.3)]] && tap.durationNanoseconds == 80_000_000)
        let pinch = try segment("pinch", ["0.5", "0.5", "0.2", "0.4", "0.3"])
        #expect(pinch.contactCount == 2 && pinch.frames.count == 32)
        let doubleTap = try segment("gesture", [GesturePresets.doubleTap(x: 0.4, y: 0.4)])
        #expect(doubleTap.contactCount == 1 && doubleTap.frames.map(\.active) == [[0], [], [0], []])
        #expect(doubleTap.frames.map(\.nanoseconds) == [0, 60_000_000, 160_000_000, 220_000_000])
        // The rotation applies as for a touch sent alone.
        let rotated = try DirectTouchDisplay(DirectPhysicalTouchTests().display(rotation: "rot90"))
        let turned = try HoldSegment(CoreDeviceInput.validated(device: Self.udid, operation: "tap", operands: ["0.2", "0.3"]), display: rotated)
        #expect(turned.frames.first?.positions == [[position(0.3), position(0.8)]])
    }
}

/// The stream's state, driven with a clock the test moves: no thread, no bridge.
struct HoldStreamTests {
    private let held = [position(0.5), position(0.6)]
    private func tap() throws -> HoldSegment {
        try HoldSegment(CoreDeviceInput.validated(device: HoldBatchBuildTests.udid, operation: "tap", operands: ["0.2", "0.3"]))
    }

    @Test func theHeldContactGoesDownAtOnceAndIsSentAgainEvery250Milliseconds() throws {
        let stream = HoldStream(slots: 2, held: held)
        guard case .send(let first, let delay) = stream.next(now: 0) else { Issue.record("No first report"); return }
        #expect(delay == 0 && contacts(first).map(\.active) == [true, false] && contacts(first)[0].x == held[0] && contacts(first)[0].y == held[1])
        // Nothing due: the bridge polls.
        #expect(stream.next(now: 1_000_000) == .idle(HoldStream.pollNanoseconds))
        guard case .send(let refresh, let wait) = stream.next(now: 245_000_000) else { Issue.record("No refresh"); return }
        #expect(refresh == first && wait == 5_000_000)
        _ = stream.next(now: 260_000_000)
        #expect(stream.statistics.reports == 2 && stream.statistics.refreshes == 1)
    }

    @Test func aMergedTapRunsBesideTheHeldContactAndLeavesItDown() throws {
        let stream = HoldStream(slots: 2, held: held)
        _ = stream.next(now: 0)
        let tap = try tap()
        let id = try #require(stream.enqueue(tap))
        var now: UInt64 = 1_000_000, sent: [[UInt8]] = []
        while !stream.isCompleted(id) {
            switch stream.next(now: now) {
            case .send(let report, let delay):
                sent.append(report)
                now += delay + 100_000
            case .idle(let wait): now += wait
            case .end: Issue.record("Ended during the tap"); return
            }
        }
        #expect(sent.count == tap.frames.count)
        // Contact 0 stays down at its place in every report.
        #expect(sent.allSatisfy { contacts($0)[0].active && contacts($0)[0].x == held[0] })
        #expect(contacts(sent[0])[1].active && contacts(sent[0])[1].x == position(0.2) && contacts(sent[0])[1].y == position(0.3))
        // The tap's contact lifts where it was.
        let last = contacts(try #require(sent.last))
        #expect(!last[1].active && last[1].x == position(0.2))
        stream.stop()
        #expect(stream.next(now: now) == .end)
        #expect(stream.enqueue(tap) == nil)
    }

    @Test func aLongGapInAMergedStepIsRefreshedWithBothContactsDown() throws {
        let gesture = #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.2,"y":0.2}]},{"ms":1000,"touches":[]}]}"#
        let segment = try HoldSegment(CoreDeviceInput.validated(device: HoldBatchBuildTests.udid, operation: "gesture", operands: [gesture]))
        let stream = HoldStream(slots: 2, held: held)
        _ = stream.next(now: 0)
        let id = try #require(stream.enqueue(segment))
        var now: UInt64 = 1_000_000, sent: [[UInt8]] = []
        while !stream.isCompleted(id) {
            switch stream.next(now: now) {
            case .send(let report, let delay): sent.append(report); now += delay
            case .idle(let wait): now += wait
            case .end: return
            }
        }
        // Down, three refreshes of both contacts, then the step's release.
        #expect(sent.count == 5 && sent.dropLast().allSatisfy { contacts($0).allSatisfy(\.active) })
        #expect(contacts(sent[4]).map(\.active) == [true, false] && stream.statistics.refreshes == 3)
    }
}

/// The C live scheduler with a local sink, on a thread of its own.
@Suite(.dedicatedThread)
struct LiveDigitizerSchedulerTests {
    private static func report(_ points: [(Bool, Int, Int)]) -> [UInt8] {
        NativeTouchFrames.report(positions: points.map { [$0.1, $0.2] }, active: Set(points.indices.filter { points[$0].0 }))
    }

    /// Runs the scheduler over a list of answers (nil is the end) and
    /// returns its status and what the sink received.
    private func run(_ answers: [(Int32, [UInt8], UInt64)?], stopAfter: Int = .max) -> (Int32, [[UInt8]]) {
        var remaining = answers, sent: [[UInt8]] = []
        let status = ADCRunLiveDigitizer({ report, delay in
            guard !remaining.isEmpty, let answer = remaining.removeFirst() else { return ADCLiveDigitizerEnd }
            answer.1.withUnsafeBufferPointer { report!.update(from: $0.baseAddress!, count: 58) }
            delay!.pointee = answer.2
            return answer.0
        }, { sent.count >= stopAfter ? 1 : 0 }, { report in
            if let report { sent.append(Array(UnsafeBufferPointer(start: report, count: 58))) }
        })
        return (status, sent)
    }

    @Test func theEndReleasesEveryActiveContactOnce() {
        let down = Self.report([(true, 100, 200), (true, 300, 400)])
        let lifted = Self.report([(true, 100, 200), (false, 300, 400)])
        let (status, sent) = run([(ADCLiveDigitizerSend, down, 0), (ADCLiveDigitizerIdle, [UInt8](repeating: 0, count: 58), 1_000),
                                  (ADCLiveDigitizerSend, lifted, 0), nil])
        #expect(status == 0 && sent.count == 3 && Array(sent.prefix(2)) == [down, lifted])
        #expect(sent[2] == Self.report([(false, 100, 200), (false, 300, 400)]))
    }

    @Test func aStopReleasesWhatWasDown() {
        let down = Self.report([(true, 100, 200)])
        let (status, sent) = run(Array(repeating: (ADCLiveDigitizerSend, down, 0), count: 10), stopAfter: 2)
        #expect(status == 1 && sent == [down, down, Self.report([(false, 100, 200)])])
    }

    @Test func invalidReportsEndTheStream() {
        let down = Self.report([(true, 100, 200)])
        // A first report with nothing down sends nothing.
        #expect(run([(ADCLiveDigitizerSend, Self.report([(false, 1, 1)]), 0)]) == (2, []))
        // A changed contact count, an inactive contact that moves, a wait
        // past the limit or an unknown answer stop it, with the release.
        for bad in [(ADCLiveDigitizerSend, Self.report([(true, 100, 200), (true, 5, 5)]), UInt64(0)),
                    (ADCLiveDigitizerIdle, down, ADCLiveDigitizerMaximumDelayNanoseconds + 1), (Int32(7), down, 0)] {
            let (status, sent) = run([(ADCLiveDigitizerSend, down, 0), bad])
            #expect(status == 3 && sent == [down, Self.report([(false, 100, 200)])])
        }
        var moved = Self.report([(true, 100, 200), (false, 300, 400)])
        let movedInactive = Self.report([(true, 100, 200), (false, 301, 400)])
        #expect(run([(ADCLiveDigitizerSend, moved, 0), (ADCLiveDigitizerSend, movedInactive, 0)]).0 == 3)
        moved[3] = 0
        #expect(run([(ADCLiveDigitizerSend, moved, 0)]).0 == 2)
    }

    @Test func thePerformFunctionRefusesBeforeAnyTransport() {
        var error = [CChar](repeating: 0, count: 256), surface: UInt64 = 9
        #expect(ADCPerformLiveDigitizerReports("invalid", "1", { _, _ in ADCLiveDigitizerEnd }, { 1 }, &surface, &error, error.count) == 1)
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(surface == 0 && message.contains("cancelled before transport"))
    }
}

/// Holds run by the command service, with the C live scheduler and a local
/// sink in place of the device.
@Suite(.dedicatedThread)
struct HoldServiceTests {
    static let udid = HoldBatchBuildTests.udid
    static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    final class Device: Sendable {
        let reports = Mutex<[[UInt8]]>([])
        let displayReads = Mutex(0)
        /// The display read from which on the screen is rotated.
        let rotateAt: Int
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/hold-test-\(UUID().uuidString)")
        init(rotateAt: Int = .max) { self.rotateAt = rotateAt }
        deinit { try? FileManager.default.removeItem(at: directory) }

        var sent: [[UInt8]] { reports.withLock { $0 } }

        func service(transport: HoldTransport? = nil) throws -> CommandService {
            let details = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
                "identifier": HoldServiceTests.uuid, "properties": ["state": ["developerModeStatus": "enabled"], "hardware": ["udid": HoldServiceTests.udid]]]])
            let upright = try DirectPhysicalTouchTests().display(), turned = try DirectPhysicalTouchTests().display(rotation: "rot90")
            return CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in details },
                uiReadinessQuery: { [self] plan in
                    guard plan.arguments.contains("displays") else { throw CommandFailure(.toolFailed, "No lock state here.", inputSent: .none) }
                    let read = displayReads.withLock { $0 += 1; return $0 }
                    return read >= rotateAt ? turned : upright
                }, holdTransport: transport ?? .local { [self] report in reports.withLock { $0.append(report) } })
        }
    }

    private func receipt(_ output: CommandOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    @Test(.timeLimit(.minutes(1))) func aTapInsideAHoldJoinsTheHeldStreamAndReleaseLiftsBoth() async throws {
        let device = Device()
        let output = try await device.service().run(["batch", "--device", Self.udid, #"[["hold","0.5","0.6"],["tap","0.2","0.3"],["release"]]"#])
        let receipt = try receipt(output)
        #expect(output.exitCode == 0 && receipt["status"] as? String == "completed")
        let sent = device.sent
        try #require(sent.count >= 7)
        #expect(sent.allSatisfy { $0[1] == 2 })
        #expect(contacts(sent[0]).map(\.active) == [true, false] && contacts(sent[0])[0].x == position(0.5) && contacts(sent[0])[0].y == position(0.6))
        // Contact 0 is down in every report but the last, which lifts all.
        #expect(sent.dropLast().allSatisfy { contacts($0)[0].active })
        #expect(sent.contains { contacts($0)[1].active && contacts($0)[1].x == position(0.2) && contacts($0)[1].y == position(0.3) })
        #expect(contacts(try #require(sent.last)).allSatisfy { !$0.active })
        let steps = try #require(receipt["steps"] as? [[String: Any]])
        let tap = try #require(steps[1]["output"] as? [String: Any]), release = try #require(steps[2]["output"] as? [String: Any])
        #expect(tap["mergedIntoHold"] as? Bool == true && tap["contactIDs"] as? [Int] == [1] && tap["holdStep"] as? Int == 1)
        #expect(release["status"] as? String == "released" && release["release"] as? String == "confirmed-by-barrier")
        let hold = try #require((receipt["holds"] as? [[String: Any]])?.first)
        #expect(hold["releasedBy"] as? String == "release-step" && hold["releaseStep"] as? Int == 3)
        #expect(hold["stepsWhileHeld"] as? [Int] == [2] && hold["mergedSteps"] as? [Int] == [2])
    }

    @Test(.timeLimit(.minutes(1))) func aBatchThatEndsWhileHoldingReleasesAtTheEnd() async throws {
        let device = Device()
        let output = try await device.service().run(["batch", "--device", Self.udid, #"[["hold","0.5","0.5"],["tap","0.5","0.2"]]"#])
        let receipt = try receipt(output)
        #expect(output.exitCode == 0 && (receipt["holdNote"] as? String)?.contains("released when the batch ends") == true)
        let hold = try #require((receipt["holds"] as? [[String: Any]])?.first)
        #expect(hold["releasedBy"] as? String == "end-of-batch" && hold["release"] as? String == "confirmed-by-barrier")
        #expect(contacts(try #require(device.sent.last)).allSatisfy { !$0.active })
    }

    @Test(.timeLimit(.minutes(1))) func aFailedStepReleasesTheHoldWithoutQuarantine() async throws {
        // The hold reads the display twice; the tap's read finds it turned.
        let device = Device(rotateAt: 3)
        let service = try device.service()
        let output = try await service.run(["batch", "--device", Self.udid, #"[["hold","0.5","0.5"],["tap","0.5","0.2"],["release"]]"#])
        let receipt = try receipt(output)
        #expect(output.exitCode == 1 && receipt["failedStep"] as? Int == 2)
        let error = try #require((receipt["steps"] as? [[String: Any]])?[1]["error"] as? [String: Any])
        #expect(error["code"] as? String == CommandFailure.Code.preconditionChanged.rawValue && error["inputSent"] as? String == "none")
        let hold = try #require((receipt["holds"] as? [[String: Any]])?.first)
        #expect(hold["releasedBy"] as? String == "failed-step 2" && hold["release"] as? String == "confirmed-by-barrier")
        // Only the held contact was ever down.
        #expect(device.sent.allSatisfy { !contacts($0)[1].active })
        #expect(contacts(try #require(device.sent.last)).allSatisfy { !$0.active })
    }

    @Test(.timeLimit(.minutes(1))) func aTransportFailureWhileHoldingIsAnUnknownOutcomeAndQuarantines() async throws {
        let device = Device()
        // The connection fails once three reports are out, during the tap.
        let failing = HoldTransport { _, _, next, shouldStop in
            let status = ADCRunLiveDigitizer(next, { shouldStop() != 0 || device.sent.count >= 3 ? 1 : 0 }) { report in
                if let report { device.reports.withLock { $0.append(Array(UnsafeBufferPointer(start: report, count: 58))) } }
            }
            return HoldStream.Outcome(status: status == 0 ? 0 : ADCInputOutcomeUnknown, surface: 0, message: "Transport failed while holding.")
        }
        let service = try device.service(transport: failing)
        let output = try await service.run(["batch", "--device", Self.udid, #"[["hold","0.5","0.5"],["long-press","0.2","0.2","1"],["release"]]"#])
        let receipt = try receipt(output)
        #expect(output.exitCode == 1 && receipt["failedStep"] as? Int == 2)
        let error = try #require((receipt["steps"] as? [[String: Any]])?[1]["error"] as? [String: Any])
        #expect(error["code"] as? String == CommandFailure.Code.inputOutcomeUnknown.rawValue && error["inputSent"] as? String == "possible")
        #expect(((receipt["holds"] as? [[String: Any]])?.first)?["release"] as? String == "unknown")
        // The release was still attempted for both contacts.
        #expect(contacts(try #require(device.sent.last)).allSatisfy { !$0.active })
        let refused = await #expect(throws: CommandFailure.self) { _ = try await service.run(["tap", "0.5", "0.5", "--device", Self.udid]) }
        #expect(refused?.code == .deviceQuarantined)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationStopsTheStreamReleasesAndQuarantines() async throws {
        let device = Device(), pressed = TestSignal()
        let transport = HoldTransport.local { report in
            device.reports.withLock { $0.append(report) }
            if report[1] == 2, contacts(report)[1].active { pressed.signal() }
        }
        let service = try device.service(transport: transport)
        let task = Task {
            try await service.run(["batch", "--device", Self.udid, #"[["hold","0.5","0.5"],["long-press","0.3","0.3","10"],["release"]]"#])
        }
        await pressed.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let last = contacts(try #require(device.sent.last))
        #expect(last.allSatisfy { !$0.active })
        let refused = await #expect(throws: CommandFailure.self) { _ = try await service.run(["tap", "0.5", "0.5", "--device", Self.udid]) }
        #expect(refused?.code == .deviceQuarantined)
    }

    @Test func aDryRunPlansTheHoldAndItsMergedStepsWithoutContactingAnything() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("A dry run queried the device"); return Data() },
                                     uiReadinessQuery: { _ in Issue.record("A dry run read the display"); return Data() },
                                     holdTransport: HoldTransport { _, _, _, _ in
                                         Issue.record("A dry run started a stream")
                                         return HoldStream.Outcome(status: 1, surface: 0, message: "")
                                     })
        let steps = #"[["hold","0.5","0.6"],["swipe","0.9","0.0","0.9","0.15","0.25"],["wait","--label","Wi-Fi","--until","visible"],["press","--label","Wi-Fi"],["release"]]"#
        let output = try await service.run(["batch", "--device", Self.udid, "--dry-run", steps])
        let receipt = try receipt(output)
        #expect(output.exitCode == 0 && receipt["status"] as? String == "planned")
        let plan = try #require((receipt["holds"] as? [[String: Any]])?.first)
        #expect(plan["contactSlots"] as? Int == 2 && plan["mergedSteps"] as? [Int] == [2] && plan["stepsWhileHeld"] as? [Int] == [2, 3, 4])
        #expect(plan["releaseStep"] as? Int == 5 && plan["refreshMilliseconds"] as? Int == 250)
        let outputs = try #require(receipt["steps"] as? [[String: Any]]).compactMap { $0["output"] as? [String: Any] }
        #expect([0, 1, 4].map { outputs[$0]["operation"] as? String } == ["hold", "swipe", "release"])
        #expect(outputs[1]["mergedIntoHold"] as? Bool == true && outputs[1]["contactIDs"] as? [Int] == [1] && outputs[4]["holdStep"] as? Int == 1)
    }
}
