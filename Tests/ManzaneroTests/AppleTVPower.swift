import CoreGraphics
import Foundation
import MCP
import Testing
@testable import Manzanero

/// `remote sleep` and `remote wake` on a physical Apple TV: what is pressed,
/// and what is not, for each thing the screenshots can say.
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

        func environment(regions: [ScreenText.Region] = [AppleTVPowerTests.powerOff],
                         tile: AppleTVPower.Tile = .init(background: 1, darkest: 0.1)) -> AppleTVPower.Environment {
            AppleTVPower.Environment(
                capture: {
                    self.captures += 1
                    let awake = self.awake.count > 1 ? self.awake.removeFirst() : self.awake[0]
                    return awake ? URL(fileURLWithPath: "/nonexistent/power.png") : nil
                },
                recognize: { _ in regions },
                tile: { _, _ in tile },
                press: { self.pressed.append($0) },
                settle: { _ in })
        }
    }

    private static let powerOff = ScreenText.Region(text: "Power Off", confidence: 1, x: 0.76, y: 0.28, width: 0.06, height: 0.02)

    private static func run(_ name: String, _ environment: AppleTVPower.Environment, type: String = "appleTV",
                            isolation: isolated (any Actor)? = #isolation) async throws -> [String: Any] {
        let input = try CoreDeviceInput.validated(device: uuid, operation: "remote", operands: [name])
        let data = try await AppleTVPower.execute(input, details: try details(type: type), environment: environment)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sleepGoesHomeOpensControlCentreAndSelectsPowerOff() async throws {
        // Awake before, awake with Control Centre open, then asleep.
        let device = Device(awake: [true, true, false])
        let result = try await Self.run("sleep", device.environment())
        #expect(device.pressed == ["home", "lock", "select"])
        #expect(result["status"] as? String == "asleep" && result["verified"] as? Bool == true && result["exitCode"] as? Int == 0)
        #expect(result["pressed"] as? [String] == ["home", "lock", "select"])
    }

    @Test func sleepSendsNoSelectUnlessThePictureShowsPowerOffInFocus() async throws {
        // Control Centre did not open, or the language is another.
        let other = ScreenText.Region(text: "Apagar", confidence: 1, x: 0.76, y: 0.28, width: 0.06, height: 0.02)
        let unseen = Device(awake: [true])
        let first = try await Self.run("sleep", unseen.environment(regions: [other]))
        #expect(unseen.pressed == ["home", "lock"] && first["status"] as? String == "control-centre-not-seen" && first["exitCode"] as? Int == 1)
        // Power Off is there with the focus elsewhere: a grey tile, white text.
        let unfocused = Device(awake: [true])
        let second = try await Self.run("sleep", unfocused.environment(tile: .init(background: 0.6, darkest: 0.55)))
        #expect(unfocused.pressed == ["home", "lock"] && second["status"] as? String == "power-off-not-in-focus" && second["exitCode"] as? Int == 1)
        #expect((second["powerOffTile"] as? [String: Any])?["focused"] as? Bool == false)
    }

    @Test func sleepPressesNothingOnASleepingDeviceAndSaysWhenItStaysAwake() async throws {
        let asleep = Device(awake: [false])
        let first = try await Self.run("sleep", asleep.environment())
        #expect(asleep.pressed.isEmpty && asleep.captures == 1 && first["status"] as? String == "already-asleep")
        // The select went out and the device still gives screenshots: said,
        // and nothing pressed again.
        let stubborn = Device(awake: [true])
        let second = try await Self.run("sleep", stubborn.environment())
        #expect(stubborn.pressed == ["home", "lock", "select"] && second["status"] as? String == "not-asleep")
        #expect(second["verified"] as? Bool == false && second["exitCode"] as? Int == 1)
        #expect(stubborn.captures == 2 + AppleTVPower.checks)
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
        environment.recognize = { _ in throw CommandFailure(.toolFailed, "OCR failed.", inputSent: .none) }
        let failure = await #expect(throws: CommandFailure.self) { _ = try await Self.run("sleep", environment) }
        #expect(device.pressed == ["home", "lock"] && failure?.inputSent != CommandFailure.InputSent.none)
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

    /// The tile in focus is white with dark text; another is grey with white text.
    @Test func aTileInFocusIsWhiteWithDarkText() throws {
        func image(background: CGFloat, text: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 60, height: 20, bitsPerComponent: 8, bytesPerRow: 60,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: background, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
            context.setFillColor(gray: text, alpha: 1)
            context.fill(CGRect(x: 10, y: 8, width: 40, height: 3))
            return try #require(context.makeImage())
        }
        #expect(try AppleTVPower.tile(image(background: 1, text: 0.1)).focused)
        #expect(try !AppleTVPower.tile(image(background: 0.6, text: 1)).focused)
        #expect(try !AppleTVPower.tile(image(background: 1, text: 1)).focused)
    }

    @Test func theDryRunPlanNamesThePressesAndTheMCPToolTakesTheNames() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        for (name, presses) in [("sleep", ["home": 1, "lock": 1, "select": 1]), ("wake", ["home": 1])] {
            let output = try await service.run(["remote", name, "--device", Self.uuid], dryRun: true)
            let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["remote"] as? String == name && plan["maximumPresses"] as? [String: Int] == presses)
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "platform": "physical", "button": "sleep"])
        #expect(args == ["remote", "--device=\(Self.uuid)", "--", "sleep"])
    }
}
