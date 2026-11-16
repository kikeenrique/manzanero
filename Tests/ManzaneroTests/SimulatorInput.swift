import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

/// Simulator touch, buttons, keys and typing against injected bridge calls.
struct SimulatorInputTests {
    static let uuid = SimulatorDeviceTests.uuid

    final class Sent: @unchecked Sendable {
        var touches: [[ADCTouchSample]] = []
        var twoContacts: [(first: [ADCTouchSample], second: [ADCTouchPoint])] = []
        var keyboards: [[ADCKeyboardSample]] = []
        var keys: [UInt64] = []
        var buttons: [(usage: UInt64, hold: UInt32)] = []
        var lookups = 0
        var failure: CommandFailure?
        var onSend: (() -> Void)?
    }

    static func environment(_ sent: Sent, state: String = "Booted") -> SimulatorEnvironment {
        var environment = SimulatorEnvironment(
            lookup: { _ in sent.lookups += 1; return SimulatorDeviceTests.info(state) },
            accessibility: { _, _ in Issue.record("Input opened accessibility"); return SimulatorAXFixture().session() })
        environment.touch = { device, samples in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.touches.append(samples)
        }
        environment.twoContactTouch = { device, samples, second in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.twoContacts.append((samples, second))
        }
        environment.keyboard = { device, samples in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.keyboards.append(samples)
        }
        environment.key = { _, usage in
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.keys.append(usage)
        }
        environment.button = { _, usage, hold in
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.buttons.append((usage, hold))
        }
        return environment
    }

    static func service(_ sent: Sent, state: String = "Booted", leases: DeviceLeaseRegistry = SimulatorAccessibilityTests.usableLeases()) -> CommandService {
        CommandService(leases: leases, simulator: environment(sent, state: state),
                       readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    static func json(_ output: CommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    // MARK: - Parsing

    @Test func touchOperandsAreValidatedLikePhysical() throws {
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.25"])?.operands == ["0.5", "0.25"])
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "long-press", "0.5", "0.5", "1"])?.operands == ["0.5", "0.5", "1.0"])
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "swipe", "0.5", "0.8", "0.5", "0.2", "0.6"]) != nil)
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "drag", "0", "0", "1", "1", "10"]) != nil)
        let invalid: [([String], String)] = [
            (["tap", "2", "0.5"], "Simulator input coordinates must be normalized numbers from 0 to 1."),
            (["tap", "0.5"], "tap expects 2 operands. See --help."),
            (["swipe", "0.5", "0.8", "0.5", "0.2", "0.01"], "Simulator drag/swipe duration must be 0.03...10 seconds."),
            (["long-press", "0.5", "0.5", "0.05"], "Simulator long-press requires normalized x/y in 0...1 and duration 0.1...10 seconds."),
            (["tap", "nan", "0"], "Simulator input coordinates must be normalized numbers from 0 to 1.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
        // The physical wording is unchanged by the shared validator.
        let physical = try #require(throws: CommandFailure.self) { try PhysicalInputOperands.validate("tap", ["2", "0.5"]) }
        #expect(physical.description == "Physical input coordinates must be normalized numbers from 0 to 1.")
    }

    @Test func simulatorInputRunsUnderTheSignalScope() {
        #expect(CLIInputSignals.applies(to: ["simulator", Self.uuid, "tap", "0.5", "0.5"], dryRun: false))
        #expect(CLIInputSignals.context(for: ["simulator", Self.uuid, "tap", "0.5", "0.5"]) == "simulator input")
        #expect(CLIInputSignals.context(for: ["physical", "00008110-000A1B2C3D4E5F60", "tap", "0.5", "0.5"]) == "physical input")
        #expect(!CLIInputSignals.applies(to: ["simulator", Self.uuid, "tap", "0.5", "0.5"], dryRun: true))
        #expect(!CLIInputSignals.applies(to: ["simulator", Self.uuid, "apps"], dryRun: false))
        #expect(!CLIInputSignals.applies(to: ["simulator", "booted", "tap", "0.5", "0.5"], dryRun: false))
    }

    // MARK: - Geometry and schedules

    @Test func normalizedCoordinatesReachTheDigitizerUnchanged() throws {
        let info = SimulatorDeviceTests.info()
        let tap = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.711"])), info: info)
        #expect(tap.first?.x == 0.5 && tap.first?.y == 0.711 && tap.first?.phase == 0 && tap.last?.phase == 2)
        #expect(tap.last?.nanoseconds == 80_000_000 && tap.allSatisfy { $0.second == nil })
        // Another screen size changes nothing: the space is the interface's 0...1.
        let large = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.711"])),
                                                          info: SimulatorDeviceTests.info(width: 1032, height: 1376, scale: 2))
        #expect(large == tap)
        let swipe = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "swipe", "0.2", "0.8", "0.8", "0.2", "0.5"])), info: info)
        #expect(swipe.count == 32 && swipe.first?.x == 0.2 && swipe.last?.x == 0.8 && swipe.last?.y == 0.2)
        #expect(swipe.last?.nanoseconds == 501_000_000)
        let hold = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "long-press", "0.4", "0.55", "0.8"])), info: info)
        #expect(hold.last?.nanoseconds == 800_000_000 && Set(hold.map(\.x)) == [0.4])
    }

    // MARK: - Execution

    @Test(arguments: [["tap", "0.5", "0.45"], ["long-press", "0.4", "0.55", "0.8"], ["swipe", "0.5", "0.65", "0.5", "0.35", "0.5"], ["drag", "0.3", "0.55", "0.7", "0.55", "0.8"]])
    func touchDispatchesOneScheduleUnderTheLease(_ operands: [String]) async throws {
        let sent = Sent()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var holder = ""
        sent.onSend = { holder = SimulatorAccessibilityTests.leaseHolder(directory) }
        let receipt = try Self.json(await Self.service(sent, leases: SimulatorAccessibilityTests.usableLeases(directory))
            .execute(["simulator", Self.uuid] + operands))
        #expect(sent.touches.count == 1 && sent.lookups == 1)
        #expect(holder.contains(operands[0]))
        #expect(receipt["backend"] as? String == "coresimulator-dtuhid" && receipt["operation"] as? String == operands[0])
        #expect(receipt["status"] as? String == "dispatched" && receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
        #expect(receipt["platform"] as? String == "simulator" && receipt["contactCount"] as? Int == 1)
        #expect(receipt["sampleCount"] as? Int == sent.touches[0].count)
        #expect(receipt["coordinateSpace"] as? String == "normalized-current-interface")
        #expect((receipt["screen"] as? [String: Any])?["orientation"] as? String == "portrait-assumed")
        #expect((receipt["holdSeconds"] as? Double) == (operands[0] == "long-press" ? 0.8 : nil))
        #expect(sent.touches[0].first?.phase == 0 && sent.touches[0].last?.phase == 2)
    }

    // MARK: - Two contacts

    @Test func pinchAndTwoPathMultiDragAreValidatedLikePhysical() throws {
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "pinch", "0.5", "0.5", "0.2", "0.5", "0.6"])?.operation == "pinch")
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]) != nil)
        let invalid: [([String], CommandFailure.Code, String)] = [
            (["pinch", "0.5", "0.5", "0.2", "0.2", "0.6"], .usage, "Pinch requires different positive start/end spans and 0.03...10 seconds. Spans are fractions of screen width."),
            (["pinch", "0.5", "0.5", "0.2", "1.5", "0.6"], .usage, "Simulator input coordinates must be normalized numbers from 0 to 1."),
            // Crossing paths are refused at parse time, before any lookup.
            (["multi-drag", "0.6", "0.3", "0.6", "0.7", "0.6", "0.7", "0.6", "0.3", "0.6"], .usage, "Two-contact paths overlap or cross; no input sent."),
            (["multi-drag", "20", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4"], .usage, "Usage: multi-drag <seconds: 0.03...10> <start-x> <start-y> <end-x> <end-y> ... (two to five contact paths)"),
            (["multi-drag", "0.6", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4", "0.7", "0.6", "0.7", "0.4"], .unsupportedOperation,
             "Simulator multi-drag with three to five paths is not implemented yet; two paths use the digitizer's two contacts. No input sent.")
        ]
        for (operands, code, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == code && failure.inputSent == .none)
        }
    }

    @Test(arguments: [["pinch", "0.5", "0.5", "0.2", "0.5", "0.6"], ["multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]])
    func twoContactsTravelInOneDigitizerSchedule(_ operands: [String]) async throws {
        let sent = Sent()
        let receipt = try Self.json(await Self.service(sent).execute(["simulator", Self.uuid] + operands))
        #expect(sent.touches.isEmpty && sent.twoContacts.count == 1)
        let (first, second) = try #require(sent.twoContacts.first)
        // The physical paired plan: down, 30 moves, release 1 ms after the duration.
        #expect(first.count == 32 && second.count == 32 && first.first?.phase == 0 && first.last?.phase == 2)
        #expect(first.last?.nanoseconds == (operands[0] == "pinch" ? 601_000_000 : 501_000_000))
        if operands[0] == "pinch" {
            #expect(abs(first[0].x - 0.4) < 1e-9 && abs(second[0].x - 0.6) < 1e-9 && first[0].y == 0.5 && second[0].y == 0.5)
            #expect(abs(first[31].x - 0.25) < 1e-9 && abs(second[31].x - 0.75) < 1e-9)
        } else {
            #expect(first[0].y == 0.25 && second[0].y == 0.75 && first[31].y == 0.1 && second[31].y == 0.9)
        }
        #expect(receipt["contactCount"] as? Int == 2 && receipt["sampleCount"] as? Int == 32)
        #expect(receipt["backend"] as? String == "coresimulator-dtuhid" && receipt["operation"] as? String == operands[0])
        #expect(receipt["status"] as? String == "dispatched" && receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
    }

    @Test func twoContactDryRunNamesBothContacts() async throws {
        let sent = Sent()
        let plan = try Self.json(await Self.service(sent, state: "Shutdown").execute(["simulator", Self.uuid, "pinch", "0.5", "0.5", "0.5", "0.2", "0.4"], dryRun: true))
        #expect(plan["contactCount"] as? Int == 2 && plan["sampleCount"] as? Int == 32)
        #expect((plan["execution"] as? String)?.contains("pointTwo") == true)
        #expect(sent.lookups == 0 && sent.twoContacts.isEmpty)
    }

    @Test func unbootedSimulatorSendsNothingAndTakesNoLease() async throws {
        let sent = Sent()
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent, state: "Shutdown", leases: try SimulatorAccessibilityTests.unusableLeases())
                .execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
        })
        // The lookup refusal comes before the (unusable) lease.
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none && sent.touches.isEmpty)
    }

    @Test func busySimulatorIsRefusedBeforeInput() async throws {
        let sent = Sent()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = open(directory.appendingPathComponent("\(Self.uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
        defer { _ = close(owner) }
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent, leases: DeviceLeaseRegistry(directory: directory)).execute(["simulator", Self.uuid, "drag", "0.3", "0.5", "0.7", "0.5", "0.4"])
        })
        #expect(failure.code == .deviceBusy && failure.inputSent == .none && failure.action == .wait && sent.touches.isEmpty)
    }

    @Test func bridgeStatusesKeepThePhysicalClassification() async throws {
        for (status, code, inputSent) in [(ADCInputOutcomeUnknown, CommandFailure.Code.inputOutcomeUnknown, CommandFailure.InputSent.possible),
                                          (1, .transportFailed, .none)] {
            let sent = Sent()
            sent.failure = CommandFailure.inputDispatch(status: status, message: "fixture")
            let failure = try #require(await #expect(throws: CommandFailure.self) {
                _ = try await Self.service(sent).execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
            })
            #expect(failure.code == code && failure.inputSent == inputSent)
        }
    }

    @Test func touchDryRunPlansWithoutLookingTheSimulatorUp() async throws {
        let sent = Sent()
        let plan = try Self.json(await Self.service(sent, state: "Shutdown").execute(["simulator", Self.uuid, "swipe", "0.5", "0.8", "0.5", "0.2", "0.6"], dryRun: true))
        #expect(plan["backend"] as? String == "coresimulator-dtuhid" && plan["operation"] as? String == "swipe")
        #expect(plan["operands"] as? [String] == ["0.5", "0.8", "0.5", "0.2", "0.6"] && plan["sampleCount"] as? Int == 32)
        #expect(plan["deviceLease"] as? String == "simulator UUID" && plan["liveVerified"] as? Bool == false)
        #expect((plan["execution"] as? String)?.contains("dtuhidd") == true)
        #expect(sent.lookups == 0 && sent.touches.isEmpty)
    }

    // MARK: - Buttons, keys and typing

    @Test func buttonsKeysAndTypingAreValidatedForTheSimulator() throws {
        for args in [["button", "home"], ["button", "lock"], ["key", "backspace"], ["key", "return"], ["type", "Wi-Fi 5\tok\n"]] {
            #expect(try SimulatorInput.parse(["simulator", Self.uuid] + args)?.operation == args[0])
        }
        let invalid: [([String], String)] = [
            (["button", "volume-up"], "Supported simulator buttons: home, lock. Volume buttons are untested on the simulator and refused; no input sent."),
            (["button"], "Supported simulator buttons: home, lock. Volume buttons are untested on the simulator and refused; no input sent."),
            (["key", "f1"], "Unknown simulator keyboard key. See --help."),
            (["type", "mañana"], "Simulator typing requires 1...512 printable US-layout ASCII characters, tab or LF newline. Unicode entry is not implemented on the simulator yet. No input sent."),
            (["type", String(repeating: "a", count: 513)], "Simulator typing requires 1...512 printable US-layout ASCII characters, tab or LF newline. Unicode entry is not implemented on the simulator yet. No input sent."),
            (["type", "a", "b"], "Simulator typing expects one text operand.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
    }

    @Test func buttonsUseThePhysicalUsagesAndHolds() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let home = try Self.json(await service.execute(["simulator", Self.uuid, "button", "home"]))
        _ = try await service.execute(["simulator", Self.uuid, "button", "lock"])
        #expect(sent.buttons.map(\.usage) == [64, 48] && sent.buttons.map(\.hold) == [80_000, 400_000])
        #expect(home["backend"] as? String == "coresimulator-dtuhid" && home["button"] as? String == "home")
        #expect(home["status"] as? String == "dispatched" && home["verified"] as? Bool == false && home["releaseVerified"] as? Bool == false)
    }

    @Test func keysAndTypingUseThePhysicalTable() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let key = try Self.json(await service.execute(["simulator", Self.uuid, "key", "backspace"]))
        #expect(sent.keys == [42] && key["key"] as? String == "backspace" && key["usage"] as? Int == 42)
        let typed = try Self.json(await service.execute(["simulator", Self.uuid, "type", "Wi"]))
        let schedule = try #require(sent.keyboards.first)
        // Shift down, W down/up, shift up, i down/up: the physical US-layout table.
        #expect(schedule.map(\.usage) == [225, 26, 26, 225, 12, 12] && schedule.map(\.state) == [1, 1, 2, 2, 1, 2])
        #expect(schedule.map(\.nanoseconds) == (0..<6).map { UInt64($0) * 10_000_000 })
        #expect(typed["insertionVerified"] as? Bool == false && typed["layout"] as? String == "US")
        #expect(typed["characterCount"] as? Int == 2 && typed["sampleCount"] as? Int == 6)
    }

    @Test func buttonKeyAndTypeDryRunsNameTheirService() async throws {
        let sent = Sent()
        let service = Self.service(sent, state: "Shutdown")
        let button = try Self.json(await service.execute(["simulator", Self.uuid, "button", "lock"], dryRun: true))
        #expect(button["usage"] as? Int == 48 && button["holdMilliseconds"] as? Int == 400)
        #expect((button["execution"] as? String)?.contains("remote.hid.button") == true)
        let type = try Self.json(await service.execute(["simulator", Self.uuid, "type", "hello"], dryRun: true))
        #expect(type["sampleCount"] as? Int == 10 && type["layout"] as? String == "US")
        #expect((type["execution"] as? String)?.contains("remote.hid.keyboard") == true)
        let key = try Self.json(await service.execute(["simulator", Self.uuid, "key", "return"], dryRun: true))
        #expect(key["usage"] as? Int == 40 && key["backend"] as? String == "coresimulator-dtuhid")
        #expect(sent.lookups == 0 && sent.keys.isEmpty && sent.buttons.isEmpty && sent.keyboards.isEmpty)
    }

    @Test func interruptedTypingIsAnUnknownOutcome() async throws {
        let sent = Sent()
        sent.failure = CommandFailure.inputDispatch(status: ADCInputOutcomeUnknown, message: "Input stopped after cancellation or transport failure")
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent).execute(["simulator", Self.uuid, "type", "hello"])
        })
        #expect(failure.code == .inputOutcomeUnknown && failure.inputSent == .possible && failure.retry == .afterInspection)
    }

    @Test func handoffPausesSimulatorInputButNotObservations() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let gate = HandoffCommandTests.Gate()
        let pending = Task { try await service.execute(["simulator", Self.uuid, "handoff", "fixture"], handoffConfirmation: { _ in await gate.wait() }) }
        try #require(await gate.entered.wait())
        let paused = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await service.execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
        })
        #expect(paused.code == .handoffPending && sent.touches.isEmpty && sent.lookups == 0)
        await gate.finish()
        _ = try await pending.value
    }
}
