import Foundation
import MCP
import Testing
@testable import Manzanero

/// `remote sleep` and `remote wake` on a physical Apple TV: what is pressed,
/// and what is not, for each thing the device can answer.
struct AppleTVPowerTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    private static func details(type: String = "appleTV") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": "enabled"], "hardware": ["deviceType": type]]]])
    }

    /// A device that is awake or asleep by turns: each capture takes the
    /// next answer, and the last one repeats.
    private final class Device: @unchecked Sendable {
        var awake: [Bool]
        var pressed: [String] = []
        var captures = 0
        init(awake: [Bool]) { self.awake = awake }

        /// `controlCentre`: whether the system UI's tree shows Power Off.
        func environment(controlCentre: Bool = true) -> AppleTVPower.Environment {
            AppleTVPower.Environment(
                capture: {
                    self.captures += 1
                    let awake = self.awake.count > 1 ? self.awake.removeFirst() : self.awake[0]
                    return awake ? URL(fileURLWithPath: "/nonexistent/power.png") : nil
                },
                pressPowerOff: {
                    if controlCentre { self.pressed.append("power-off") }
                    return controlCentre
                },
                press: { self.pressed.append($0) },
                settle: { _ in })
        }
    }

    private static func run(_ name: String, _ environment: AppleTVPower.Environment, type: String = "appleTV",
                            isolation: isolated (any Actor)? = #isolation) async throws -> [String: Any] {
        let input = try CoreDeviceInput.validated(device: uuid, operation: "remote", operands: [name])
        let data = try await AppleTVPower.execute(input, details: try details(type: type), environment: environment)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sleepOpensControlCentreAndPressesPowerOffByAccessibility() async throws {
        // Awake before, then asleep. No Home and no select.
        let device = Device(awake: [true, false])
        let result = try await Self.run("sleep", device.environment())
        #expect(device.pressed == ["lock", "power-off"])
        #expect(result["status"] as? String == "asleep" && result["verified"] as? Bool == true && result["exitCode"] as? Int == 0)
        #expect(result["pressed"] as? [String] == ["lock", "power-off"])
    }

    @Test func sleepPressesNothingMoreWhenControlCentreDoesNotShowPowerOff() async throws {
        let unseen = Device(awake: [true])
        let result = try await Self.run("sleep", unseen.environment(controlCentre: false))
        #expect(unseen.pressed == ["lock"] && result["pressed"] as? [String] == ["lock"])
        #expect(result["status"] as? String == "control-centre-not-seen" && result["exitCode"] as? Int == 1)
        // No screenshot is taken to wait for a sleep that was not asked for.
        #expect(unseen.captures == 1)
    }

    @Test func sleepPressesNothingOnASleepingDeviceAndSaysWhenItStaysAwake() async throws {
        let asleep = Device(awake: [false])
        let first = try await Self.run("sleep", asleep.environment())
        #expect(asleep.pressed.isEmpty && asleep.captures == 1 && first["status"] as? String == "already-asleep")
        // Power Off was pressed and the device still gives screenshots:
        // said, and nothing pressed again.
        let stubborn = Device(awake: [true])
        let second = try await Self.run("sleep", stubborn.environment())
        #expect(stubborn.pressed == ["lock", "power-off"] && second["status"] as? String == "not-asleep")
        #expect(second["verified"] as? Bool == false && second["exitCode"] as? Int == 1)
        #expect(stubborn.captures == 1 + AppleTVPower.checks)
    }

    @Test func wakePressesHomeOnceOnlyOnASleepingDevice() async throws {
        let awake = Device(awake: [true])
        let first = try await Self.run("wake", awake.environment())
        #expect(awake.pressed.isEmpty && first["status"] as? String == "already-awake")
        let asleep = Device(awake: [false, false, true])
        let second = try await Self.run("wake", asleep.environment())
        #expect(asleep.pressed == ["home"] && second["status"] as? String == "awake" && second["exitCode"] as? Int == 0)
        let slow = Device(awake: [false])
        let third = try await Self.run("wake", slow.environment())
        #expect(slow.pressed == ["home"] && third["status"] as? String == "not-awake" && third["exitCode"] as? Int == 1)
    }

    @Test func aFailureAfterAPressSaysInputMayHaveGone() async throws {
        let device = Device(awake: [true])
        var environment = device.environment()
        environment.pressPowerOff = { throw CommandFailure(.transportFailed, "The session failed.", inputSent: .none) }
        let failure = await #expect(throws: CommandFailure.self) { _ = try await Self.run("sleep", environment) }
        #expect(device.pressed == ["lock"] && failure?.inputSent != CommandFailure.InputSent.none)
    }

    @Test func anotherDeviceAndOptionsAreRefusedBeforeAnyPress() async throws {
        let device = Device(awake: [true])
        let failure = await #expect(throws: CommandFailure.self) { _ = try await Self.run("sleep", device.environment(), type: "iPhone") }
        #expect(failure?.code == .unsupportedOperation && device.pressed.isEmpty && device.captures == 0)
        for operands in [["sleep", "--hold", "1"], ["wake", "--travel", "0.5"]] {
            let usage = #expect(throws: CommandFailure.self) { try CoreDeviceInput.validated(device: Self.uuid, operation: "remote", operands: operands) }
            #expect(usage?.code == .usage)
        }
    }

    @Test func aSleepingDeviceIsToldByItsRefusedScreenshot() {
        #expect(AppleTVPower.isAsleep(CommandFailure(.toolFailed, "xcrun failed (1): ERROR: Display reports zero-sized native size (com.apple.dt.CoreDeviceError error 25005 (0x61AD))", inputSent: .none)))
        #expect(!AppleTVPower.isAsleep(CommandFailure(.timeout, "devicectl timed out.", inputSent: .none)))
    }

    @Test func theSystemUIProcessIsFoundAmongTheDevicesProcesses() throws {
        let processes = try JSONSerialization.data(withJSONObject: ["result": ["runningProcesses": [
            ["executable": "file:///Applications/PineBoard.app/PineBoard", "processIdentifier": 41],
            ["executable": "file:///Applications/TVSystemUIService.app/TVSystemUIService", "processIdentifier": 10040]]]])
        #expect(AppleTVPower.systemUIProcess(processes) == 10040)
        #expect(AppleTVPower.systemUIProcess(Data("{}".utf8)) == nil)
    }

    @Test func theDryRunPlanNamesThePressesAndTheMCPToolTakesTheNames() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        for (name, presses) in [("sleep", ["lock": 1, "power-off": 1]), ("wake", ["home": 1])] {
            let output = try await service.run(["remote", name, "--device", Self.uuid], dryRun: true)
            let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["remote"] as? String == name && plan["maximumPresses"] as? [String: Int] == presses)
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "platform": "physical", "button": "sleep"])
        #expect(args == ["remote", "--device=\(Self.uuid)", "--", "sleep"])
    }
}
