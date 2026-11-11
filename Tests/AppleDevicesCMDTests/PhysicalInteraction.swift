import Foundation
import Testing
@testable import AppleDevicesCMD

struct PhysicalInteractionTests {
    @Test func plansCoordinatedPathsAndHorizontalPinchWithPairing() throws {
        let command = try #require(try DeviceCommand.parse(["--pairing-file", "tmp/fixture.pairing.plist", "physical", "fixture", "pinch", "0.5", "0.5", "0.5", "1", "0.5"]))
        #expect(command.arguments == ["appledevices-idevice", "--pairing-file", "tmp/fixture.pairing.plist", "fixture", "multi-drag", "500", "16384", "32768", "0", "32768", "49151", "32768", "65535", "32768"])
        let multi = try #require(try DeviceCommand.parse(["physical", "fixture", "multi-drag", "0.03", "0", "0", "1", "1", "1", "1", "0", "0"]))
        #expect(multi.arguments == ["appledevices-idevice", "fixture", "multi-drag", "30", "0", "0", "65535", "65535", "65535", "65535", "0", "0"])
    }

    @Test(arguments: [
        ["pinch", "0", "0.5", "0.5", "1", "1"],
        ["pinch", "0.5", "1.1", "0.5", "1", "1"],
        ["pinch", "0.5", "0.5", "0", "1", "1"],
        ["pinch", "0.5", "0.5", "0.5", "0.5", "1"],
        ["pinch", "nan", "0.5", "0.5", "1", "1"],
        ["pinch", "0.5", "0.5", "0.00000001", "0.00000002", "1"],
        ["pinch", "0.5", "0.5", "0.5", "1", "11"],
        ["multi-drag", "1", "0", "0", "1", "1"],
        ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "0", "0"],
        ["multi-drag", "0", "0", "0", "1", "1", "1", "1", "0", "0"],
        ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "inf"]
    ]) func rejectsInvalidCoordinatedGestures(_ operands: [String]) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "fixture"] + operands) }
    }

    @Test func acceptsFivePathsAndRejectsSix() throws {
        let path = ["0", "0", "1", "1"]
        let five = Array(repeating: path, count: 5).flatMap { $0 }
        #expect(try DeviceCommand.parse(["physical", "fixture", "multi-drag", "10"] + five) != nil)
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "fixture", "multi-drag", "10"] + five + path) }
    }
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
