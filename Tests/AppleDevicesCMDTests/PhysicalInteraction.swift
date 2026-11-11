import Foundation
import Testing
@testable import AppleDevicesCMD

struct PhysicalInteractionTests {
    @Test func physicalTypingPreservesLiteralTextAndPairingPath() throws {
        let text = "--literal 'text'; $(touch sentinel)\tOK\n"
        let command = try #require(try DeviceCommand.parse(["--pairing-file", "tmp/My Phone.pairing.plist", "physical", "test-udid", "type", text]))
        #expect(command.arguments == ["appledevices-idevice", "--pairing-file", "tmp/My Phone.pairing.plist", "test-udid", "type", text])
        #expect(command.jsonOutput)
    }

    @Test(arguments: ["", "é", "🙂", "\0", "\r", "\u{1b}", String(repeating: "a", count: 513)])
    func rejectsUnsupportedPhysicalTextBeforeBackendPlanning(_ text: String) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "test-udid", "type", text]) }
    }

    @Test func accessibilitySnapshotUsesProtocolBackend() throws {
        let command = try #require(try DeviceCommand.parse(["physical", "test-udid", "ax-snapshot"]))
        #expect(command.arguments == ["appledevices-idevice", "test-udid", "ax-snapshot"])
        #expect(command.jsonOutput)
        #expect(command.interactive == false)
    }
    @Test func convertsNormalizedCoordinateBoundaries() throws {
        let command = try #require(try DeviceCommand.parse(["physical", "test-udid", "multi-tap", "0", "1", "0.5", "0.5"]))
        #expect(command.arguments == ["appledevices-idevice", "test-udid", "multi-tap", "0", "65535", "32768", "32768"])
        #expect(command.jsonOutput)
    }

    @Test func swipeUsesTouchDragAndConvertsSeconds() throws {
        let command = try #require(try DeviceCommand.parse(["physical", "test-udid", "swipe", "0", "0.9", "0", "0.1", "0.5"]))
        #expect(command.arguments == ["appledevices-idevice", "test-udid", "drag", "0", "58982", "0", "6554", "500"])
    }

    @Test(arguments: [
        ["tap", "nan", "0"], ["tap", "1.1", "0"], ["tap", "-0.1", "0"],
        ["tap", "0"], ["multi-tap", "0", "0", "1"],
        ["drag", "0", "0", "1", "1", "inf"], ["drag", "0", "0", "1", "1", "0"],
        ["button", "--help"], ["key", "unknown"], ["hid-info", "extra"]
    ]) func rejectsInvalidInput(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "test-udid"] + args) }
    }
}
