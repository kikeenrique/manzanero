import Darwin
import Foundation
import Synchronization
import Testing
@testable import Manzanero

struct CLIInputSignalsTests {
    @Test func scopeMatchesOnlyValidatedDirectPhysicalInput() {
        let target = CoreDeviceInputTests().udid
        for operands in [["button", "home"], ["type", "fixture"], ["paste", "fixture"], ["key", "backspace"],
                         ["tap", "0.5", "0.5"], ["long-press", "0.5", "0.5", "9"],
                         ["multi-tap", "0.25", "0.5", "0.75", "0.5"], ["gesture", NativeGestureSequenceTests().doubleTap]] {
            let args = ["physical", target] + operands
            #expect(CLIInputSignals.applies(to: args, dryRun: false))
            #expect(CLIInputSignals.applies(to: ["--physical-backend", "coredevice"] + args, dryRun: false))
            #expect(!CLIInputSignals.applies(to: args, dryRun: true))
        }
        for args in [["mcp"], ["physical", target, "apps"], ["physical", target, "tap", "nan", "0"],
                     ["simulator", target, "tap", "1", "1"], ["--physical-backend", "idevice", "physical", target, "button", "home"]] {
            #expect(!CLIInputSignals.applies(to: args, dryRun: false))
        }
    }

    @Test(arguments: [SIGINT, SIGTERM]) func cancellationArrivingBeforeTaskBindingIsNotLost(signal: Int32) async {
        let forced = Mutex<[Int32]>([])
        let controller = CLIInputSignals.Controller(queue: DispatchQueue(label: "test.cli.signal"),
            forceExit: { code in forced.withLock { $0.append(code) } }, diagnostic: { _ in })
        controller.receive(signal)
        let task = Task<CommandOutput, any Error> { @concurrent in
            try await Task.sleep(for: .seconds(30))
            return CommandOutput(data: Data("unexpected".utf8))
        }
        defer { task.cancel() }
        controller.bind(task)
        let result = await task.result
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("Early signal cancellation was lost") }
        #expect(controller.finish() == 128 + signal)
        #expect(forced.withLock { $0.isEmpty })
        controller.receive(SIGTERM)
        #expect(forced.withLock { $0.isEmpty })
    }

    @Test func repeatedSignalForcesExitAndCompletedScopeIgnoresLateSignals() {
        let forced = Mutex<[Int32]>([])
        let controller = CLIInputSignals.Controller(queue: DispatchQueue(label: "test.cli.repeated-signal"),
            forceExit: { code in forced.withLock { $0.append(code) } }, diagnostic: { _ in })
        controller.receive(SIGINT)
        controller.receive(SIGTERM)
        #expect(forced.withLock { $0 } == [143])
        #expect(controller.finish() == 130)
        controller.receive(SIGINT)
        #expect(forced.withLock { $0 } == [143])
        let completed = CLIInputSignals.Controller(queue: .global(), forceExit: { _ in Issue.record("Late signal forced exit") }, diagnostic: { _ in })
        #expect(completed.finish() == nil)
        completed.receive(SIGINT)
    }

    // Parks on a signal from the Dispatch timer instead of spinning against a
    // wall-clock limit, which starves the timer on a runner with few cores.
    @Test(.timeLimit(.minutes(1))) func stalledCleanupHasBoundedForceExit() async {
        let forced = Mutex<[Int32]>([]), fired = TestSignal()
        let controller = CLIInputSignals.Controller(queue: DispatchQueue(label: "test.cli.signal-timeout"), grace: .milliseconds(20),
            forceExit: { code in forced.withLock { $0.append(code) }; fired.signal() }, diagnostic: { _ in })
        controller.receive(SIGTERM)
        #expect(await fired.wait())
        #expect(forced.withLock { $0 } == [143])
        #expect(controller.finish() == 143)
    }

    @Test func completionDisarmsCleanupDeadline() async throws {
        let forced = Mutex<[Int32]>([])
        let controller = CLIInputSignals.Controller(queue: DispatchQueue(label: "test.cli.signal-finished"), grace: .milliseconds(10),
            forceExit: { code in forced.withLock { $0.append(code) } }, diagnostic: { _ in })
        controller.receive(SIGINT)
        #expect(controller.finish() == 130)
        try await Task.sleep(for: .milliseconds(30))
        #expect(forced.withLock { $0.isEmpty })
    }
}
