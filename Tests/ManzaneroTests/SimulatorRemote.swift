import AppleDeviceBridge
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
        var held: [[ADCKeyboardSample]] = []
        var swipes: [(times: [UInt64], reports: [UInt8])] = []
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
        environment.keyboard = { _, samples in pressed.held.append(samples) }
        environment.remoteTouch = { _, times, reports in pressed.swipes.append((times, reports)) }
        environment.touch = { _, _ in pressed.touches += 1 }
        environment.digitizerReports = { _, _, _, _ in pressed.touches += 1; return 1 }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    @Test func remoteButtonsMapToKeysAndConsumerButtons() async throws {
        let pressed = Pressed()
        let service = Self.service(family: "Apple TV", pressed)
        // Sleep and wake are a physical Apple TV's: refused here, unsent.
        for name in AppleTVPower.names {
            let failure = await #expect(throws: CommandFailure.self) { try await service.run(["remote", name, "--simulator", Self.uuid]) }
            #expect(failure?.code == .unsupportedOperation && failure?.description == AppleTVPower.simulatorRefusal)
        }
        for name in AppleTVRemote.names where !AppleTVPower.names.contains(name) {
            let receipt = try SimulatorInputTests.json(await service.run(["remote", name, "--simulator", Self.uuid]))
            #expect(receipt["remote"] as? String == name && receipt["status"] as? String == "dispatched")
        }
        #expect(pressed.swipes.count == 4)
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
        // A physical Apple TV takes the remote too (PhysicalAppleTVTests).
        #expect(try request(["remote", "menu", "--device", "tv"]) == .physicalInput(CoreDeviceInput(device: "tv", operation: "remote", operands: ["menu"])))
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

    @Test func aHoldLengthensTheButtonPressOnly() async throws {
        let pressed = Pressed()
        let service = Self.service(family: "Apple TV", pressed)
        let receipt = try SimulatorInputTests.json(await service.run(["remote", "home", "--hold", "1.5", "--simulator", Self.uuid]))
        #expect(receipt["holdMilliseconds"] as? Int == 1500)
        #expect(pressed.remote.count == 1 && pressed.remote[0].usage == 0x40 && pressed.remote[0].hold == 1_500_000)
        // A key is held as its down and its up, that far apart.
        let select = try SimulatorInputTests.json(await service.run(["remote", "select", "--hold", "1", "--simulator", Self.uuid]))
        #expect(select["holdMilliseconds"] as? Int == 1000 && pressed.held.count == 1)
        #expect(pressed.held.first?.map(\.nanoseconds) == [0, 1_000_000_000] && pressed.held.first?.map(\.state) == [1, 2])
        #expect(pressed.held.first?.allSatisfy { $0.usage == 40 } == true)
        // The length is bounded; nothing is sent.
        for args in [["remote", "home", "--hold", "0.01"], ["remote", "home", "--hold", "3.5"],
                     ["remote", "home", "--hold", "long"]] {
            let failure = try #require(throws: CommandFailure.self) { try request(args + ["--simulator", Self.uuid]) }
            #expect(failure.code == .usage && failure.description == AppleTVRemote.holdUsage)
        }
        #expect(pressed.remote.count == 1 && pressed.keys.isEmpty && pressed.held.count == 1)
        let plan = try SimulatorInputTests.json(await service.run(["remote", "menu", "--hold", "2", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["holdMilliseconds"] as? Int == 2000)
        // A physical Apple TV takes the hold too, within the same range.
        // A physical Apple TV takes the hold for the keys, within the same
        // range, and refuses it for home, its one consumer button.
        #expect(throws: Never.self) { try request(["remote", "select", "--hold", "1", "--device", "tv"]) }
        let physical = try #require(throws: CommandFailure.self) { try request(["remote", "select", "--hold", "9", "--device", "tv"]) }
        #expect(physical.code == .usage)
        let home = try #require(throws: CommandFailure.self) { try request(["remote", "home", "--hold", "1", "--device", "tv"]) }
        #expect(home.code == .unsupportedOperation && home.description == AppleTVRemote.physicalHomeHoldRefusal)
        // MCP carries it as an option, before the operands.
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "button": "home", "hold_seconds": 1.5])
        #expect(args == ["remote", "--simulator=\(Self.uuid)", "--hold=1.5", "--", "home"])
        #expect(try request(args) == .simulatorInput(try SimulatorInput(device: Self.uuid, operation: "remote", operands: ["home", "--hold", "1.5"])))
    }

    @Test func aSwipeIsOneContactDrawnThroughTheCentreOfATouchPad() async throws {
        let pressed = Pressed()
        let service = Self.service(family: "Apple TV", pressed)
        let receipt = try SimulatorInputTests.json(await service.run(["remote", "swipe-down", "--simulator", Self.uuid]))
        let route = try #require(receipt["route"] as? [String: Any])
        #expect(route["service"] as? String == "com.apple.coredevice.feature.remote.universalhidservice" && route["usagePage"] as? Int == 13)
        let swipe = try #require(pressed.swipes.first)
        // Twenty-one frames down and one release, 20 ms apart, 58 bytes each (0.4 s by default).
        #expect(swipe.times.count == 22 && swipe.reports.count == 22 * 58 && receipt["frameCount"] as? Int == 22)
        #expect(swipe.times[1] == 20_000_000 && swipe.times == swipe.times.sorted())
        func point(_ frame: Int) -> (active: Bool, x: Int, y: Int) {
            let bytes = Array(swipe.reports[frame * 58..<(frame + 1) * 58])
            return (bytes[3] & 0xc0 != 0, Int(bytes[4]) | Int(bytes[5]) << 8, Int(bytes[6]) | Int(bytes[7]) << 8)
        }
        // x stays at the centre; y runs from a quarter to three quarters; the last frame lifts where it stopped.
        #expect(point(0).active && point(0).x == 32768 && point(0).y == 16384)
        #expect(point(20).active && point(20).y == 49151 && !point(21).active && point(21).y == 49151)
        let left = AppleTVRemote.swipeFrames(dx: -1, dy: 0)
        #expect(left.reports.first?[4...5] == [0xff, 0xbf] && left.reports.last?[4...5] == [0x00, 0x40])
        // No hold and no touch-screen input.
        let held = try #require(throws: CommandFailure.self) { try request(["remote", "swipe-up", "--hold", "1", "--simulator", Self.uuid]) }
        #expect(held.code == .usage && pressed.swipes.count == 1 && pressed.touches == 0 && pressed.keys.isEmpty)
        let plan = try SimulatorInputTests.json(await service.run(["remote", "swipe-left", "--simulator", Self.uuid], dryRun: true))
        #expect((plan["execution"] as? String)?.contains("touch-pad service") == true && pressed.swipes.count == 1)
    }

    @Test func mcpRemoteToolRoutesToTheCommand() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "button": "play-pause"])
        #expect(args == ["remote", "--simulator=\(Self.uuid)", "--", "play-pause"])
        #expect(try request(args) == .simulatorInput(try SimulatorInput(device: Self.uuid, operation: "remote", operands: ["play-pause"])))
        #expect(throws: MCPError.self) { try tool.command(["device": .string(Self.uuid), "button": "siri"]) }
    }
}

/// A swipe of a chosen length and duration.
struct RemoteSwipeShapeTests {
    @Test func travelAndSecondsShapeASwipe() throws {
        let parsed = try AppleTVRemote.parse(["swipe-right", "--travel", "0.8", "--seconds", "0.4"])
        guard case .swipe(let dx, let dy, let shape) = parsed.route else { Issue.record("not a swipe"); return }
        #expect(dx == 1 && dy == 0 && shape == .init(travel: 0.8, milliseconds: 400))
        let frames = AppleTVRemote.swipeFrames(dx: dx, dy: dy, shape: shape)
        func x(_ index: Int) -> Int { Int(frames.reports[index][4]) | Int(frames.reports[index][5]) << 8 }
        // Twenty moves 20 ms apart, from 0.1 to 0.9 of the width, then the lift.
        #expect(frames.times.count == 22 && frames.times.last == 420_000_000)
        #expect(abs(x(0) - 6554) <= 1 && abs(x(20) - 58982) <= 1 && x(21) == x(20))
        // The default is 0.4 s, and either option may come alone.
        #expect(AppleTVRemote.swipeFrames(dx: 1, dy: 0).times.count == 22)
        guard case .swipe(_, _, let short) = try AppleTVRemote.parse(["swipe-up", "--travel", "0.1"]).route else { Issue.record("not a swipe"); return }
        #expect(short == .init(travel: 0.1, milliseconds: AppleTVRemote.swipeMilliseconds))
        // The plan and the physical route carry the shape too.
        let swipe = AppleTVRemote.describe(parsed.route)["swipe"] as? [String: Any]
        #expect(swipe?["travel"] as? Double == 0.8 && swipe?["durationMilliseconds"] as? UInt64 == 400)
        #expect(try AppleTVRemote.parsePhysical(["swipe-right", "--travel", "0.8", "--seconds", "0.4"]).route == parsed.route)
    }

    @Test(arguments: [["swipe-up", "--travel", "0.95"], ["swipe-up", "--travel", "0"], ["swipe-up", "--seconds", "3"], ["swipe-up", "--seconds", "x"],
                      ["select", "--travel", "0.5"], ["home", "--seconds", "0.2"], ["swipe-up", "--travel", "0.5", "--travel", "0.6"],
                      ["swipe-up", "--hold", "1", "--travel", "0.5"], ["swipe-up", "--travel"], ["swipe-up", "--speed", "2"]])
    func aSwipeShapeOutOfRangeOrOnAButtonIsRefused(_ operands: [String]) {
        let failure = #expect(throws: CommandFailure.self) { try AppleTVRemote.parse(operands) }
        #expect(failure?.code == .usage)
    }
}
