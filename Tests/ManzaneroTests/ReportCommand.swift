import Testing
@testable import Manzanero

struct ReportCommandTests {
    @Test func reportListingCannotReadAnotherDomain() throws {
        let command = try DeviceCommand.plan(physical: true, device: "device", operation: "reports")
        #expect(command.arguments == ["devicectl", "device", "info", "files", "--domain-type", "systemCrashLogs", "--subdirectory", ".", "--no-recurse", "--device", "device", "--timeout", "60", "--json-output", "-"])
    }

    @Test func reportDownloadTargetsSelectedFile() throws {
        let command = try DeviceCommand.plan(physical: true, device: "device", operation: "report", operands: ["Retired/My App.ips", "tmp/My App.ips"])
        #expect(command.arguments.prefix(4) == ["devicectl", "device", "copy", "from"])
        let source = try #require(command.arguments.firstIndex(of: "--source"))
        #expect(command.arguments[source + 1] == "Retired/My App.ips")
        let destination = try #require(command.arguments.firstIndex(of: "--destination"))
        #expect(command.arguments[destination + 1] == "tmp/My App.ips")
        #expect(command.arguments.contains("systemCrashLogs"))
    }

    @Test(arguments: [["reports", "../"], ["reports", "/"], ["report", "../../x", "tmp/x"],
                      ["reports", "a", "b"], ["report", "x", "-"], ["report", "x"]])
    func rejectsInvalidPaths(_ args: [String]) {
        #expect(throws: CommandFailure.self) {
            try DeviceCommand.plan(physical: true, device: "device", operation: args[0], operands: Array(args.dropFirst()))
        }
    }
}
