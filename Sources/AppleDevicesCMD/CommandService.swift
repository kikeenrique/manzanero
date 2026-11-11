import Foundation

struct CommandOutput: Sendable {
    let data: Data
    var exitCode: Int32 = 0
}

/// CLI and MCP share validation, backend selection, and execution. Device actions
/// have no suspension points, so actor isolation serializes them within a server.
actor CommandService {
    private let runner = ToolRunner()

    func execute(_ args: [String], dryRun: Bool = false, allowInteractive: Bool = false) async throws -> CommandOutput {
        if let command = try BuildRunCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/build-run-\(UUID().uuidString)")
            if dryRun {
                return try json(["executable": "/usr/bin/xcrun",
                    "buildSettingsArguments": command.xcodeArguments(directory: directory) + ["-showBuildSettings", "-json"],
                    "buildArguments": command.xcodeArguments(directory: directory) + ["build"],
                    "deployment": "After a successful build, resolve the application from build settings, install it, and launch its bundle identifier."])
            }
            return CommandOutput(data: try command.execute(directory: directory, run: {
                try runner.run($0.arguments, executable: $0.executable)
            }, build: { try runner.build($0, log: $1) }))
        }
        if let command = try DeviceCommand.parse(args) {
            if dryRun { return try json(["executable": command.executable, "arguments": command.arguments]) }
            guard allowInteractive || !command.interactive else {
                throw CommandFailure(description: "Interactive pairing is CLI-only; pair first, then provide the existing pairing file.")
            }
            let data = try runner.run(command.arguments, executable: command.executable, interactive: command.interactive)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            if command.actionReceipt {
                FileHandle.standardError.write(data)
                return try json(["status": "dispatched", "backend": "axe", "verified": false])
            }
            return CommandOutput(data: data)
        }
        guard !dryRun else { throw CommandFailure(description: "--dry-run requires a physical or simulator command.") }
        switch args {
        case let values where values.first == "ocr":
            guard values.count == 2 else { throw CommandFailure(description: "Usage: appledevicescmd ocr <image-path>") }
            let result = try await ScreenText.recognize(path: values[1])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return CommandOutput(data: try encoder.encode(result))
        case ["devices", "physical"], ["devices", "simulators"]:
            let command = args[1] == "physical"
                ? ["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-"]
                : ["simctl", "list", "devices", "available", "--json"]
            let data = try runner.run(command)
            _ = try JSONSerialization.jsonObject(with: data)
            return CommandOutput(data: data)
        case ["doctor"]:
            var checks: [[String: String]] = []
            for (name, command) in [
                ("Xcode", ["xcodebuild", "-version"]),
                ("CoreDevice", ["devicectl", "list", "devices", "--timeout", "5", "--json-output", "-"]),
                ("CoreSimulator", ["simctl", "list", "devices", "available", "--json"])
            ] {
                do {
                    _ = try runner.run(command)
                    checks.append(["name": name, "status": "available"])
                } catch {
                    checks.append(["name": name, "status": "unavailable", "detail": String(describing: error)])
                }
            }
            var output = try json(checks)
            if checks.contains(where: { $0["status"] == "unavailable" }) { output.exitCode = 1 }
            return output
        default:
            throw CommandFailure(description: "Unknown command. Run appledevicescmd --help.")
        }
    }

    private func json(_ value: Any) throws -> CommandOutput {
        CommandOutput(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    }
}
