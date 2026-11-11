import Foundation
import Testing
@testable import AppleDevicesCMD

struct PhysicalInteractionTests {
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
