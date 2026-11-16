import Foundation
import Synchronization
import Testing
@testable import Manzanero

struct DirectPhysicalWakeTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"
    private static let input = CoreDeviceInput(device: uuid, operation: "wake", operands: [])

    private static func details(mode: String = "enabled") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": mode]]]])
    }

    /// Scripted device: each `displays` read consumes the next power state and
    /// every button press is recorded with the reads that preceded it.
    private final class Device: Sendable {
        private struct State {
            var powers: [String]
            var reads = 0
            var presses: [String] = []
            var readsBeforePress: [Int] = []
        }
        private let state: Mutex<State>
        let passcodeRequired: Bool?

        init(powers: [String], passcodeRequired: Bool? = false) {
            state = Mutex(State(powers: powers))
            self.passcodeRequired = passcodeRequired
        }

        var presses: [String] { state.withLock { $0.presses } }
        var readsBeforePress: [Int] { state.withLock { $0.readsBeforePress } }
        var reads: Int { state.withLock { $0.reads } }

        func query(_ plan: DeviceCommand) throws -> Data {
            if plan.arguments.contains("details") { return try DirectPhysicalWakeTests.details() }
            if plan.arguments.contains("displays") {
                let power = state.withLock { state -> String in
                    state.reads += 1
                    return state.powers.count > 1 ? state.powers.removeFirst() : (state.powers.first ?? "unknown")
                }
                return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": [
                    "deviceIdentifier": DirectPhysicalWakeTests.uuid,
                    "displays": [["primary": true, "backlightState": power]]]])
            }
            var lock: [String: Any] = ["deviceIdentifier": DirectPhysicalWakeTests.uuid, "unlockedSinceBoot": true]
            if let passcodeRequired { lock["passcodeRequired"] = passcodeRequired }
            return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": lock])
        }

        func press(_ button: CoreDeviceInput, _: Data) {
            state.withLock { $0.presses.append(button.operands[0]); $0.readsBeforePress.append($0.reads) }
        }
    }

    private func run(_ device: Device, operands: [String] = []) throws -> [String: Any] {
        let data = try DirectPhysicalWake.execute(CoreDeviceInput(device: Self.uuid, operation: "wake", operands: operands),
                                                  query: device.query, press: device.press, settle: { _ in })
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func offDisplayIsWokenOnceThenLockScreenIsLeft() throws {
        let device = Device(powers: ["off", "off", "activeOn"])
        let result = try run(device)
        #expect(result["status"] as? String == "awake")
        #expect(device.presses == ["lock", "home"])
        // Two off readings precede the side button; one on reading precedes Home.
        #expect(device.readsBeforePress == [2, 3])
        #expect(result["sideButtonPressed"] as? Bool == true && result["homePressed"] as? Bool == true)
        #expect(result["displayPowerBefore"] as? String == "off" && result["displayPower"] as? String == "on")
        #expect(result["exitCode"] as? Int == 0)
    }

    @Test func awakeDisplayIsNeverPressed() throws {
        let device = Device(powers: ["activeOn"])
        let result = try run(device)
        #expect(result["status"] as? String == "already-awake")
        #expect(device.presses.isEmpty)
        #expect(result["exitCode"] as? Int == 0)
    }

    @Test(arguments: ["dimmed", "unknown", ""])
    func unrecognizedDisplayStateIsNeverPressed(power: String) throws {
        let device = Device(powers: [power])
        let result = try run(device)
        #expect(result["status"] as? String == "unknown-display-state")
        #expect(device.presses.isEmpty)
        #expect(result["exitCode"] as? Int == 1)
    }

    @Test func displayThatTurnsOnBetweenReadingsIsNotPressed() throws {
        let device = Device(powers: ["off", "activeOn"])
        let result = try run(device)
        #expect(result["status"] as? String == "already-awake")
        #expect(device.presses.isEmpty)
    }

    @Test func displayThatBecomesUnreadableBetweenReadingsIsNotPressed() throws {
        let device = Device(powers: ["off", "dimmed"])
        let result = try run(device)
        #expect(result["status"] as? String == "unknown-display-state")
        #expect(device.presses.isEmpty)
        #expect(result["exitCode"] as? Int == 1)
    }

    @Test func sideButtonIsNotRepeatedWhenTheDisplayStaysOff() throws {
        let device = Device(powers: ["off", "off", "off"])
        let result = try run(device)
        #expect(result["status"] as? String == "not-awake")
        #expect(device.presses == ["lock"])
        #expect(result["exitCode"] as? Int == 1)
        #expect((result["action"] as? String)?.contains("not pressed again") == true)
    }

    @Test(arguments: [true as Bool?, nil])
    func passcodeOrUnknownLockStateLeavesTheLockScreenAlone(passcode: Bool?) throws {
        let device = Device(powers: ["off", "off", "activeOn"], passcodeRequired: passcode)
        let result = try run(device)
        #expect(result["status"] as? String == "awake-locked")
        #expect(device.presses == ["lock"])
        #expect(result["homePressed"] as? Bool == false)
        #expect(result["exitCode"] as? Int == 1)
    }

    @Test func noDismissWakesWithoutHome() throws {
        let device = Device(powers: ["off", "off", "activeOn"])
        let result = try run(device, operands: ["--no-dismiss"])
        #expect(result["status"] as? String == "awake")
        #expect(device.presses == ["lock"])
    }

    @Test func disabledDeveloperModeStopsBeforeAnyRead() throws {
        let device = Device(powers: ["off"])
        let disabled = try Self.details(mode: "disabled")
        #expect(throws: CommandFailure.self) {
            _ = try DirectPhysicalWake.execute(Self.input, query: { plan in
                plan.arguments.contains("details") ? disabled : try device.query(plan)
            }, press: device.press, settle: { _ in })
        }
        #expect(device.reads == 0 && device.presses.isEmpty)
    }

    @Test func failedSideButtonDispatchIsReportedAndNothingElseIsSent() throws {
        let device = Device(powers: ["off", "off", "activeOn"])
        #expect(throws: CommandFailure.self) {
            _ = try DirectPhysicalWake.execute(Self.input, query: device.query, press: { _, _ in
                throw CommandFailure(description: "fixture dispatch failure")
            }, settle: { _ in })
        }
        #expect(device.presses.isEmpty)
    }

    @Test func operandsAndPlanAreValidated() async throws {
        #expect(throws: CommandFailure.self) { try DirectPhysicalWake.validate(["--force"]) }
        #expect(throws: CommandFailure.self) { try DirectPhysicalWake.validate(["--no-dismiss", "--no-dismiss"]) }
        #expect(try physicalInput(["wake", "--device", Self.uuid])?.operation == "wake")
        #expect(try request(["wake", "--device", Self.uuid]).signalContext == "physical input")
        let output = try await CommandService().run(["wake", "--device", Self.uuid], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["operation"] as? String == "wake" && plan["maximumSideButtonPresses"] as? Int == 1)
        #expect(plan["dismissLockScreen"] as? Bool == true)
    }

    @Test func serviceReturnsTheStatusWithItsExitCodeAndTakesTheLease() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Another process owns the device: a wake is input, so it is refused.
        let owner = open(directory.appendingPathComponent("\(Self.uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { _ = close(owner) }
        try #require(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
        let data = try Self.details()
        let service = CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in data })
        do {
            _ = try await service.run(["wake", "--device", Self.uuid])
            Issue.record("Wake reached the device while another process owned it")
        } catch {
            #expect(String(describing: error).contains("another manzanero process"))
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "wake_device" })
        #expect(try tool.command(["device": .string(Self.uuid)]) == ["wake", "--device=\(Self.uuid)"])
        #expect(try tool.command(["device": .string(Self.uuid), "dismiss_lock_screen": .bool(false)]) == ["wake", "--device=\(Self.uuid)", "--no-dismiss"])
        #expect(summary(try request(["wake", "--device=\(Self.uuid)", "--no-dismiss"])) == ["physical", Self.uuid, "wake", "--no-dismiss"])
        #expect(!tool.readOnly && tool.answerExitCodes == [0, 1])
        let unwrapped = try DirectPhysicalWake.output(JSONSerialization.data(withJSONObject: ["status": "not-awake", "exitCode": 1]))
        #expect(unwrapped.exitCode == 1)
        #expect(!String(decoding: unwrapped.data, as: UTF8.self).contains("exitCode"))
    }
}
