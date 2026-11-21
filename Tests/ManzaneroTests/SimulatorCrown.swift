import Foundation
import MCP
import Testing
@testable import Manzanero

/// The Digital Crown and the watch side button, against injected bridge calls.
@Suite(.cleansLeaseDirectories)
struct SimulatorCrownTests {
    static let uuid = SimulatorDeviceTests.uuid

    final class Turned: @unchecked Sendable {
        var crowns: [(deltas: [Double], interval: UInt64)] = []
        var consumer: [UInt64] = []
        var pages: [UInt64] = []
        var buttons: [UInt64] = []
        var keys = 0
    }

    static func service(family: String, _ turned: Turned) -> CommandService {
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.lookup = { _ in
            var info = SimulatorDeviceTests.info()
            info.family = family
            return info
        }
        environment.crown = { device, deltas, interval in
            #expect(device == uuid)
            turned.crowns.append((deltas, interval))
        }
        environment.remoteButton = { _, page, usage, _ in
            turned.pages.append(page)
            turned.consumer.append(usage)
        }
        environment.button = { _, usage, _ in turned.buttons.append(usage) }
        environment.key = { _, _ in turned.keys += 1 }
        environment.keyboard = { _, _ in turned.keys += 1 }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    @Test func unitsAreSplitIntoFewSlowEvents() throws {
        #expect(DigitalCrown.steps(200) == [200])
        #expect(DigitalCrown.steps(-2500) == [-834, -833, -833])
        #expect(DigitalCrown.steps(300, events: 3) == [100, 100, 100])
        #expect(DigitalCrown.steps(7, events: 3) == [3, 2, 2])
        #expect(try DigitalCrown.events(nil, units: 10_000) == 10)
        for (units, events) in [(2500, "2"), (5, "6"), (100, "0"), (100, "21"), (100, "x")] {
            #expect(throws: CommandFailure.self) { try DigitalCrown.events(events, units: units) }
        }
        for units in ["0", "10001", "-10001", "1.5", "ten"] {
            let failure = try #require(throws: CommandFailure.self) { try request(["crown", units, "--simulator", Self.uuid]) }
            #expect(failure.code == .usage && failure.inputSent == .none)
        }
        #expect(try simulatorInput(["crown", "--simulator", Self.uuid, "--", "-300"])?.operands == ["-300", "1"])
        #expect(try simulatorInput(["crown", "300", "--events", "3", "--simulator", Self.uuid])?.operands == ["300", "3"])
    }

    @Test func crownSendsTheStepsOneSecondApartOnAWatch() async throws {
        let turned = Turned()
        let receipt = try SimulatorInputTests.json(await Self.service(family: "Apple Watch", turned)
            .run(["crown", "300", "--events", "3", "--simulator", Self.uuid]))
        #expect(turned.crowns.count == 1 && turned.crowns[0].deltas == [100, 100, 100] && turned.crowns[0].interval == 1_000_000_000)
        let crown = try #require(receipt["crown"] as? [String: Any])
        #expect(crown["units"] as? Int == 300 && crown["events"] as? Int == 3 && crown["durationMilliseconds"] as? Int == 2000)
    }

    @Test func crownAndSideButtonAreRefusedOffTheWatch() async throws {
        let turned = Turned()
        for family in ["iPhone", "Apple TV", ""] {
            for args in [["crown", "100"], ["button", "side"], ["button", "action"]] {
                let failure = await #expect(throws: CommandFailure.self) {
                    _ = try await Self.service(family: family, turned).run(args + ["--simulator", Self.uuid])
                }
                #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
            }
        }
        #expect(turned.crowns.isEmpty && turned.consumer.isEmpty)
        let physical = try #require(throws: CommandFailure.self) { try request(["crown", "100", "--device", "watch"]) }
        #expect(physical.code == .unsupportedOperation)
    }

    /// detect-layout types its probe, so a watch refuses it as it refuses
    /// key and type; on a watch simulator it had changed the field.
    @Test func detectLayoutIsRefusedOnAWatchBeforeAnyKey() async throws {
        let turned = Turned()
        let service = Self.service(family: "Apple Watch", turned)
        let refusal = await #expect(throws: CommandFailure.self) {
            try await service.run(["detect-layout", "--id", "probe.text.field", "--simulator", Self.uuid])
        }
        #expect(refusal?.description.contains("Keyboard events do not reach watchOS") == true)
        #expect(turned.keys == 0)
    }

    @Test func sideButtonIsConsumerUsage0x95AndOtherButtonsAreUnchanged() async throws {
        let turned = Turned()
        let service = Self.service(family: "Apple Watch", turned)
        let side = try SimulatorInputTests.json(await service.run(["button", "side", "--simulator", Self.uuid]))
        _ = try await service.run(["button", "home", "--simulator", Self.uuid])
        #expect(side["button"] as? String == "side" && turned.consumer == [0x95] && turned.buttons == [64])
        let plan = try SimulatorInputTests.json(await service.run(["button", "side", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["usage"] as? Int == 0x95 && plan["usagePage"] as? Int == 12)
    }

    @Test func actionButtonIsVendorPage0xFF01Usage0x200() async throws {
        let turned = Turned()
        let service = Self.service(family: "Apple Watch", turned)
        let receipt = try SimulatorInputTests.json(await service.run(["button", "action", "--simulator", Self.uuid]))
        #expect(receipt["button"] as? String == "action" && turned.pages == [0xFF01] && turned.consumer == [0x200] && turned.buttons.isEmpty)
        let plan = try SimulatorInputTests.json(await service.run(["button", "action", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["usage"] as? Int == 0x200 && plan["usagePage"] as? Int == 0xFF01)
        let home = try SimulatorInputTests.json(await service.run(["button", "home", "--simulator", Self.uuid], dryRun: true))
        #expect(home["usage"] as? Int == 64 && home["usagePage"] as? Int == 12)
    }

    @Test func keyIsRefusedOnAWatchAndTypeSendsNoKeyboardEvents() async throws {
        let turned = Turned()
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(family: "Apple Watch", turned).run(["key", "return", "--simulator", Self.uuid])
        }
        #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
        // type goes to the on-screen keyboard; text it cannot type is refused before anything.
        let accent = await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(family: "Apple Watch", turned).run(["type", "Gómez", "--simulator", Self.uuid])
        }
        #expect(accent?.inputSent == CommandFailure.InputSent.none && accent?.description.contains("on-screen keyboard") == true)
        #expect(turned.keys == 0)
    }

    @Test func dryRunAndMCPToolDescribeTheTurn() async throws {
        let turned = Turned()
        let plan = try SimulatorInputTests.json(await Self.service(family: "Apple Watch", turned)
            .run(["crown", "--simulator", Self.uuid, "--", "-2500"], dryRun: true))
        #expect(plan["service"] as? String == "com.apple.coredevice.feature.remote.hid.scroll" && plan["events"] as? Int == 3)
        #expect(plan["unitsPerEvent"] as? [Int] == [-834, -833, -833] && turned.crowns.isEmpty)
        let tool = try #require(MCPTools.definitions.first { $0.name == "rotate_crown" })
        let args = try tool.command(["device": .string(Self.uuid), "units": -300, "events": 3])
        #expect(args == ["crown", "--simulator=\(Self.uuid)", "--events=3", "--", "-300"])
        #expect(try simulatorInput(args)?.operands == ["-300", "3"])
    }
}
