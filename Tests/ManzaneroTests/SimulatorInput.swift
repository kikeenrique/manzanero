import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

/// Simulator touch, buttons, keys and typing against injected bridge calls.
struct SimulatorInputTests {
    static let uuid = SimulatorDeviceTests.uuid

    final class Sent: @unchecked Sendable {
        var touches: [[ADCTouchSample]] = []
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
