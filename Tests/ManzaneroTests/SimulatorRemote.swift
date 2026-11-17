import Foundation
import MCP
import Testing
@testable import Manzanero

/// The Apple TV remote and the tvOS touch refusal, against injected bridge calls.
@Suite(.cleansLeaseDirectories)
struct SimulatorRemoteTests {
    static let uuid = SimulatorDeviceTests.uuid

    final class Pressed: @unchecked Sendable {
        var keys: [UInt64] = []
        var remote: [(usage: UInt64, hold: UInt32)] = []
        var touches = 0
    }

    static func service(family: String, _ pressed: Pressed) -> CommandService {
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.lookup = { _ in
            var info = SimulatorDeviceTests.info()
            info.family = family
            return info
        }
        environment.key = { _, usage in pressed.keys.append(usage) }
        environment.remoteButton = { device, page, usage, hold in
            #expect(device == uuid && page == 12)
            pressed.remote.append((usage, hold))
        }
        environment.touch = { _, _ in pressed.touches += 1 }
        environment.digitizerReports = { _, _, _, _ in pressed.touches += 1; return 1 }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    @Test func remoteButtonsMapToKeysAndConsumerButtons() async throws {
        let pressed = Pressed()
        let service = Self.service(family: "Apple TV", pressed)
        for name in AppleTVRemote.names {
            let receipt = try SimulatorInputTests.json(await service.run(["remote", name, "--simulator", Self.uuid]))
            #expect(receipt["remote"] as? String == name && receipt["status"] as? String == "dispatched")
        }
        // select, up, down, left, right as keyboard usages (return and arrows).
        #expect(pressed.keys == [40, 82, 81, 80, 79])
        // menu (Menu Escape), home (Menu), play-pause, each held 80 ms.
        #expect(pressed.remote.map(\.usage) == [0x46, 0x40, 0xCD] && pressed.remote.allSatisfy { $0.hold == 80_000 })
    }

    @Test func remoteIsRefusedOnOtherFamiliesAndDevicesBeforeInput() async throws {
        let pressed = Pressed()
        for family in ["iPhone", "Apple Watch", ""] {
            let failure = await #expect(throws: CommandFailure.self) {
                _ = try await Self.service(family: family, pressed).run(["remote", "select", "--simulator", Self.uuid])
            }
            #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
        }
        #expect(pressed.keys.isEmpty && pressed.remote.isEmpty)
        let physical = try #require(throws: CommandFailure.self) { try request(["remote", "menu", "--device", "tv"]) }
        #expect(physical.code == .unsupportedOperation)
        let unknown = try #require(throws: CommandFailure.self) { try request(["remote", "siri", "--simulator", Self.uuid]) }
        #expect(unknown.code == .usage && unknown.description == AppleTVRemote.usage)
    }

    @Test func touchIsRefusedOnAppleTVWithAPointerToRemote() async throws {
        let pressed = Pressed()
        let service = Self.service(family: "Apple TV", pressed)
        for args in [["tap", "0.5", "0.5"], ["swipe", "0.5", "0.8", "0.5", "0.2", "0.3"], ["multi-tap", "0.3", "0.5", "0.6", "0.5"],
                     ["long-press", "0.5", "0.5", "1"]] {
            let failure = await #expect(throws: CommandFailure.self) {
                _ = try await service.run(args + ["--simulator", Self.uuid])
            }
            #expect(failure?.code == .unsupportedOperation && failure?.description == AppleTVRemote.touchRefusal)
        }
        #expect(pressed.touches == 0)
        // Keys, buttons and touch elsewhere are unaffected.
        _ = try await service.run(["key", "down", "--simulator", Self.uuid])
        _ = try await Self.service(family: "iPhone", pressed).run(["tap", "0.5", "0.5", "--simulator", Self.uuid])
        #expect(pressed.keys == [81] && pressed.touches == 1)
    }

    @Test func dryRunNamesTheRouteWithoutLookingTheSimulatorUp() async throws {
        let pressed = Pressed()
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.lookup = { _ in Issue.record("Dry run looked the simulator up"); return SimulatorDeviceTests.info() }
        let service = CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment)
        let play = try SimulatorInputTests.json(await service.run(["remote", "play-pause", "--simulator", Self.uuid], dryRun: true))
        #expect(play["service"] as? String == "com.apple.coredevice.feature.remote.hid.button" && play["usage"] as? Int == 0xCD && play["usagePage"] as? Int == 12)
        let select = try SimulatorInputTests.json(await service.run(["remote", "select", "--simulator", Self.uuid], dryRun: true))
        #expect(select["service"] as? String == "com.apple.coredevice.feature.remote.hid.keyboard" && select["usage"] as? Int == 40)
        #expect(pressed.remote.isEmpty)
    }

    @Test func mcpRemoteToolRoutesToTheCommand() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "button": "play-pause"])
        #expect(args == ["remote", "--simulator=\(Self.uuid)", "--", "play-pause"])
        #expect(try request(args) == .simulatorInput(try SimulatorInput(device: Self.uuid, operation: "remote", operands: ["play-pause"])))
        #expect(throws: MCPError.self) { try tool.command(["device": .string(Self.uuid), "button": "siri"]) }
    }
}
