import Foundation
import Testing
@testable import AppleDevicesCMD

struct SimulatorInteractionTests {
    let device = "1DCC0F91-CF8C-4774-BD9C-BC94AF982632"

    @Test func literalTextPreserved() throws {
        let text = "--help $(touch tmp/unwanted); `echo x`\nhello"
        let command = try #require(try DeviceCommand.parse(["simulator", device, "type", text]))
        #expect(command.executable == "/usr/bin/env")
        #expect(command.arguments == ["axe", "type", "--udid", device, "--", text])
        #expect(command.actionReceipt)
    }

    @Test func selectorBeginningWithDashIsLiteral() throws {
        let command = try #require(try DeviceCommand.parse(["simulator", device, "tap-label", "--help"]))
        #expect(command.arguments == ["axe", "tap", "--label=--help", "--udid", device])
    }

    @Test(arguments: [
        ["booted", "tree"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "tap", "nan", "10"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "tap", "-1", "10"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "swipe", "0", "0", "10", "10", "inf"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "type", "é"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "button", "--help"],
        ["1DCC0F91-CF8C-4774-BD9C-BC94AF982632", "tree", "extra"]
    ]) func invalidInputRejected(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["simulator"] + args) }
    }

    @Test func treeReturnsJSONWithoutActionReceipt() throws {
        let command = try #require(try DeviceCommand.parse(["simulator", device, "tree"]))
        #expect(command.jsonOutput)
        #expect(command.actionReceipt == false)
    }
}
