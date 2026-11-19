import AppleDeviceBridge
import Foundation
import MCP
import Testing
@testable import Manzanero

/// A physical Apple TV: its external display, which has no backlight state,
/// and the remote over the physical key and button routes. The display JSON
/// is the shape an Apple TV 4K (3rd generation) answered with.
struct PhysicalAppleTVTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    private static func displays(type: String = "external", backlight: String = "off") throws -> Data {
        let display: [String: Any] = ["primary": true, "backlightState": backlight, "type": [type: [String: Any]()],
            "bounds": [[0, 0], [3840, 2160]], "currentOrientation": "rot0", "nativeOrientation": "rot0",
            "displayId": 1, "name": "TVOut", "pointScale": 1]
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"],
            "result": ["deviceIdentifier": uuid, "backlightState": backlight, "displays": [display]]])
    }

    private static func details(type: String? = "appleTV") throws -> Data {
        var hardware: [String: Any] = [:]
        if let type { hardware["deviceType"] = type }
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": "enabled"], "hardware": hardware]]])
    }

    private static func query(_ plan: DeviceCommand) throws -> Data {
        if plan.arguments.contains("details") { return try details() }
        if plan.arguments.contains("displays") { return try displays() }
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": [
            "deviceIdentifier": uuid, "passcodeRequired": false, "unlockedSinceBoot": true]])
    }

    @Test func anExternalDisplayIsNotReportedOff() throws {
        let ui = try DeviceUIReadiness.observe(details: Self.details(), device: Self.uuid, query: Self.query)
        #expect(ui.displayPower == "external" && ui.status == "observed" && ui.actions.isEmpty)
        #expect(ui.diagnostics.contains { $0.hasPrefix("displayExternal:") })
        // An integrated display that is off still reads off.
        let phone = try #require(JSONSerialization.jsonObject(with: Self.displays(type: "integrated")) as? [String: Any])
        #expect(DeviceUIReadiness.displayPower(try #require(phone["result"] as? [String: Any])) == "off")
    }

    @Test func aScreenshotOfAnExternalDisplayGetsNoBlackImageNote() throws {
        let receipt = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"]])
        let annotated = DeviceUIReadiness.annotateScreenshot(receipt, device: Self.uuid, query: Self.query)
        let root = try #require(JSONSerialization.jsonObject(with: annotated) as? [String: Any])
        #expect(root["displayPower"] as? String == "external" && root["displayNote"] == nil)
    }

    @Test func theTreeAcceptsAnExternalDisplayInTVPoints() throws {
        let display = try AccessibilityDisplay(Self.displays())
        #expect(display.external && display.pointScale == 2)
        // Focus-driven: selector actions make no hit test there.
        #expect(display.focusDriven)
        let phone = AccessibilityDisplay(bounds: .init(x: 0, y: 0, width: 375, height: 812), displayId: 1, pointScale: 3, orientation: "rot0")
        #expect(!phone.focusDriven && !phone.external)
        #expect(display.bounds == .init(x: 0, y: 0, width: 1920, height: 1080))
        // The flag is not printed, so a phone's tree keeps its shape.
        let printed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(display)) as? [String: Any])
        #expect(Set(printed.keys) == ["bounds", "displayId", "pointScale", "orientation"])
        let failure = #expect(throws: CommandFailure.self) { try AccessibilityDisplay(Self.displays(type: "integrated")) }
        #expect(failure?.code == .displayOff)
    }

    /// A 4K Apple TV simulator reported what the device did: 3840 pixels at
    /// scale 1, with an interface 1920 points wide.
    @Test func aSimulatedTelevisionListsItsInterfaceAt1920Points() {
        func entry(primary: Bool, kind: String, width: Double, height: Double) -> [String: Any] {
            SimulatorDisplayEntry(id: 1, name: "TVOut", deviceName: "primary", primary: primary, kind: kind, widthPixels: width,
                                  heightPixels: height, pointScale: 1, backlight: "off", active: true, orientation: "rot0").json
        }
        let fourK = entry(primary: true, kind: "external", width: 3840, height: 2160)
        #expect(fourK["widthPoints"] as? Double == 1920 && fourK["heightPoints"] as? Double == 1080 && fourK["pointScale"] as? Double == 2)
        let fullHD = entry(primary: true, kind: "external", width: 1920, height: 1080)
        #expect(fullHD["widthPoints"] as? Double == 1920 && fullHD["pointScale"] as? Double == 1)
        // A phone's television output is external but not primary: unchanged.
        let phoneOutput = entry(primary: false, kind: "external", width: 3840, height: 2160)
        #expect(phoneOutput["widthPoints"] as? Double == 3840 && phoneOutput["pointScale"] as? Double == 1)
    }

    @Test func touchAndCaptureAreRefusedOnAnExternalDisplay() throws {
        let failure = #expect(throws: CommandFailure.self) { try DirectTouchDisplay(Self.displays()) }
        #expect(failure?.code == .unsupportedOperation && failure?.description == AppleTVRemote.touchRefusal)
        // Recording and frames decoded a wrong picture there, so they say so.
        let capture = #expect(throws: CommandFailure.self) { try DirectTouchDisplay(Self.displays(), capture: true) }
        #expect(capture?.code == .unsupportedOperation && capture?.description == DirectTouchDisplay.externalCaptureRefusal)
        // An integrated display that is off is still reported as off.
        let off = #expect(throws: CommandFailure.self) { try DirectTouchDisplay(Self.displays(type: "integrated"), capture: true) }
        #expect(off?.code == .displayOff)
    }

    @Test func wakePressesNothingOnAnExternalDisplay() throws {
        let data = try DirectPhysicalWake.execute(CoreDeviceInput(device: Self.uuid, operation: "wake", operands: []),
            query: Self.query, press: { _, _ in Issue.record("wake pressed a button on an Apple TV") }, settle: { _ in })
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["status"] as? String == "external-display" && result["sideButtonPressed"] as? Bool == false)
        #expect(result["exitCode"] as? Int == 1)
    }

    @Test func remoteUsesKeysAndTheHomeButton() throws {
        var keys: [UInt64] = [], buttons: [(UInt64, UInt32)] = []
        for name in ["select", "up", "down", "left", "right", "menu", "play-pause", "home"] {
            let input = try CoreDeviceInput.validated(device: Self.uuid, operation: "remote", operands: [name])
            let data = try AppleTVRemote.execute(input, query: Self.query, key: { keys.append($0.usage) },
                                                 button: { buttons.append(($0.usage, $0.holdMicroseconds)) })
            let receipt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(receipt["remote"] as? String == name && receipt["status"] as? String == "dispatched")
        }
        // Menu is Escape and play-pause is Space on a physical Apple TV, not the consumer usages.
        #expect(keys == [40, 82, 81, 80, 79, 41, 44])
        #expect(buttons.count == 1 && buttons[0] == (0x40, 80_000))
    }

    /// A held button carries the hold on the button service; a held key is
    /// one key down and one key up the hold apart.
    @Test func aHeldRemoteButtonCarriesItsHold() throws {
        var keys = 0, buttons: [(UInt64, UInt32)] = [], held: [[ADCKeyboardSample]] = []
        for name in ["select", "menu"] {
            let input = try CoreDeviceInput.validated(device: Self.uuid, operation: "remote", operands: [name, "--hold", "1.5"])
            let data = try AppleTVRemote.execute(input, query: Self.query, key: { _ in keys += 1 },
                                                 button: { buttons.append(($0.usage, $0.holdMicroseconds)) },
                                                 heldKey: { held.append($0.samples) })
            let receipt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(receipt["holdMilliseconds"] as? Int == 1500)
            #expect(try AppleTVRemote.plan(input)["holdMilliseconds"] as? UInt32 == 1500)
        }
        #expect(keys == 0 && buttons.isEmpty)
        #expect(throws: CommandFailure.self) {
            try CoreDeviceInput.validated(device: Self.uuid, operation: "remote", operands: ["home", "--hold", "1.5"])
        }
        #expect(held.map { $0.map(\.usage) } == [[40, 40], [41, 41]])
        #expect(held.allSatisfy { $0[0].state == 1 && $0[0].nanoseconds == 0 && $0[1].state == 2 && $0[1].nanoseconds == 1_500_000_000 })
    }

    @Test func remoteIsRefusedForUnknownButtonsAndOtherDevices() throws {
        let unknown = #expect(throws: CommandFailure.self) { try request(["remote", "siri", "--device", Self.uuid]) }
        #expect(unknown?.code == .usage)
        let input = try CoreDeviceInput.validated(device: Self.uuid, operation: "remote", operands: ["home"])
        for type in ["iPhone", nil] {
            let failure = #expect(throws: CommandFailure.self) {
                _ = try AppleTVRemote.execute(input, query: { _ in try Self.details(type: type) },
                    key: { _ in Issue.record("key sent") }, button: { _ in Issue.record("button sent") })
            }
            #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
        }
    }

    @Test func remoteDryRunNamesThePhysicalRoute() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        let output = try await service.run(["remote", "menu", "--device", Self.uuid], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["operation"] as? String == "remote" && plan["usage"] as? Int == 41 && plan["usagePage"] as? Int == 7)
        #expect(plan["service"] as? String == "com.apple.coredevice.feature.remote.hid.keyboard")
    }

    @Test func mcpRemoteToolTakesAPhysicalPlatform() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "platform": "physical", "button": "menu"])
        #expect(args == ["remote", "--device=\(Self.uuid)", "--", "menu"])
    }
}
