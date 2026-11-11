import Foundation
import Testing
@testable import AppleDevicesCMD

struct PairingCommandTests {
    @Test func pinIsInteractiveAndPathsRemainLiteral() throws {
        let command = try #require(try DeviceCommand.parse(["pair", "wifi", "phone.local", "1234", "tmp/My Phone.pairing.plist"]))
        #expect(command.interactive)
        #expect(command.arguments == ["appledevices-idevice", "pair-wifi", "phone.local", "1234", "tmp/My Phone.pairing.plist"])
    }

    @Test func recordSelectedOnlyForHIDBackend() throws {
        let command = try #require(try DeviceCommand.parse(["--pairing-file", "tmp/phone.pairing.plist", "physical", "test-udid", "tap", "0", "1"]))
        #expect(command.arguments == ["appledevices-idevice", "--pairing-file", "tmp/phone.pairing.plist", "test-udid", "tap", "0", "65535"])
        #expect(command.interactive == false)
    }

    @Test(arguments: [
        ["pair", "wifi", "phone.local", "0", "tmp/phone.pairing.plist"],
        ["pair", "wifi", "phone.local", "65536", "tmp/phone.pairing.plist"],
        ["pair", "wifi", "phone\nlocal", "1234", "tmp/phone.pairing.plist"],
        ["pair", "wifi", "phone.local", "1234", "tmp/phone.plist"],
        ["--pairing-file", ""],
        ["--pairing-file", "tmp/phone.pairing.plist", "simulator", "booted", "tree"],
        ["--pairing-file", "tmp/phone.pairing.plist", "physical", "test-udid", "apps"]
    ]) func invalidPairingArguments(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(args) }
    }
}
