import Foundation
import Testing
@testable import AppleDevicesCMD

struct AppDataCommandTests {
    @Test func uploadDirectionAndContainerScope() throws {
        let command = try #require(try DeviceCommand.parse(["physical", "test-device", "push", "com.example.app", "tmp/My Data.json", "Documents/My Data.json"]))
        #expect(command.arguments == ["devicectl", "device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", "com.example.app", "--source", "tmp/My Data.json", "--destination", "Documents/My Data.json", "--remove-existing-content", "false", "--device", "test-device", "--timeout", "60", "--json-output", "-"])
    }

    @Test func downloadPreservesLiteralPaths() throws {
        let remote = "Documents/$(touch sentinel);file.txt"
        let command = try #require(try DeviceCommand.parse(["physical", "test-device", "pull", "com.example.app", remote, "tmp/output file.txt"]))
        let source = try #require(command.arguments.firstIndex(of: "--source"))
        let destination = try #require(command.arguments.firstIndex(of: "--destination"))
        #expect(command.arguments[source + 1] == remote)
        #expect(command.arguments[destination + 1] == "tmp/output file.txt")
    }

    @Test(arguments: [
        ["files", "com.example.app", "../Library"], ["files", "com.example.app", "/"],
        ["pull", "com.example.app", "Documents/../../x", "tmp/file"],
        ["push", "com.example.app", "tmp/file", "../x"],
        ["push", "--help", "tmp/file", "."], ["pull", "com.example.app", "."],
        ["terminate", "0"], ["terminate", "-1"], ["terminate", "4294967295"],
        ["terminate", "com.example.app"], ["open-url", "relative/path"]
    ]) func invalidOperands(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "test-device"] + args) }
    }

    @Test func terminateCannotSelectProcessGroupOrForceKill() throws {
        let command = try #require(try DeviceCommand.parse(["physical", "test-device", "terminate", "123"]))
        #expect(command.arguments.contains("--kill") == false)
        let index = try #require(command.arguments.firstIndex(of: "--pid"))
        #expect(command.arguments[index + 1] == "123")
    }
}
