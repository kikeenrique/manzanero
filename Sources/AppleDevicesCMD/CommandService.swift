import Foundation

struct CommandOutput: Sendable {
    let data: Data
    var exitCode: Int32 = 0
}

/// CLI and MCP share validation, backend selection, and execution. Device actions
/// have no suspension points, so actor isolation serializes them within a server.
actor CommandService {
    private let runner = ToolRunner()
    private let readinessQuery: @Sendable (String) throws -> Data
    private var pendingHandoffs: Set<DeviceTarget> = []

    init(readinessQuery: @escaping @Sendable (String) throws -> Data = { device in
        guard let plan = try DeviceCommand.parse(["physical", device, "details"]) else {
            throw CommandFailure(description: "Cannot plan device readiness query.")
        }
        return try ToolRunner().run(plan.arguments + ["--quiet"])
    }) {
        self.readinessQuery = readinessQuery
    }

    private func readiness(_ device: String) throws -> DeviceReadiness {
        guard !device.isEmpty, !device.hasPrefix("-") else { throw CommandFailure(description: "Provide a valid device identifier.") }
        return try DeviceReadiness.decode(readinessQuery(device), device: device)
    }

    private func preflight(_ device: String, operation: String) throws {
        let report: DeviceReadiness
        do { report = try readiness(device) }
        catch {
            // Independent idevice pairing can work without a CoreDevice identity.
            FileHandle.standardError.write(Data("Unable to determine CoreDevice readiness: \(error). The selected backend will enforce its own prerequisites.\n".utf8))
            return
        }
        try report.requireDeveloperMode(operation: operation)
    }

    func execute(_ args: [String], dryRun: Bool = false, allowInteractive: Bool = false,
                 handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)? = nil) async throws -> CommandOutput {
        if let handoff = try HandoffCommand.parse(args) {
            if dryRun { return try json(["platform": handoff.platform, "device": handoff.device, "message": handoff.message, "action": "Request human completion; no device action or prompt is executed by this dry run."]) }
            guard pendingHandoffs.insert(handoff.target).inserted else { throw CommandFailure(description: "A handoff is already pending for this device.") }
            defer { pendingHandoffs.remove(handoff.target) }
            if let handoffConfirmation {
                let status = try await handoffConfirmation(handoff)
                return try handoff.output(status, mechanism: "mcp-form")
            }
            guard allowInteractive else { throw CommandFailure(description: "Handoff requires a terminal or an MCP host with form elicitation.") }
            return try handoff.output(TerminalHandoff.confirm(handoff), mechanism: "terminal")
        }
        if !dryRun { try checkHandoffPause(args) }
        if args.count == 3, args[0] == "physical", args[2] == "readiness" {
            if dryRun {
                guard let plan = try DeviceCommand.parse(["physical", args[1], "details"]) else { throw CommandFailure(description: "Invalid device.") }
                return try json(["executable": plan.executable, "arguments": plan.arguments + ["--quiet"]])
            }
            return try readiness(args[1]).output()
        }
        if let recording = try RecordingCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/recording-\(UUID().uuidString)")
            if dryRun {
                let plan = recording.command(staging: directory.appendingPathComponent("capture.mp4"))
                return try json(["executable": plan.executable, "arguments": plan.arguments,
                    "destination": recording.destination.path, "durationSeconds": recording.seconds,
                    "stopPolicy": recording.physical ? "devicectl --duration" : "Wait for first frame, then SIGINT after duration; wait for finalization."])
            }
            if recording.physical { try preflight(recording.device, operation: "record screen") }
            return CommandOutput(data: try await recording.execute(directory: directory, runner: runner))
        }
        if let command = try BuildRunCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/build-run-\(UUID().uuidString)")
            if dryRun {
                return try json(["executable": "/usr/bin/xcrun",
                    "buildSettingsArguments": command.xcodeArguments(directory: directory) + ["-showBuildSettings", "-json"],
                    "buildArguments": command.xcodeArguments(directory: directory) + ["build"],
                    "deployment": "After a successful build, resolve the application from build settings, install it, and launch its bundle identifier."])
            }
            if command.physical { try preflight(command.device, operation: "build and run") }
            return CommandOutput(data: try command.execute(directory: directory, run: {
                try runner.run($0.arguments, executable: $0.executable)
            }, build: { try runner.build($0, log: $1) }))
        }
        if let command = try DeviceCommand.parse(args) {
            if dryRun { return try json(["executable": command.executable, "arguments": command.arguments]) }
            let targetArgs = args.first == "--pairing-file" ? Array(args.dropFirst(2)) : args
            if targetArgs.count >= 3, targetArgs[0] == "physical",
               ["tap", "multi-tap", "drag", "swipe", "button", "key", "type", "hid-info", "ax-snapshot", "launch", "terminate", "processes", "open-url", "screenshot"].contains(targetArgs[2]) {
                try preflight(targetArgs[1], operation: targetArgs[2])
            }
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

    private func checkHandoffPause(_ args: [String]) throws {
        let args = args.first == "--pairing-file" ? Array(args.dropFirst(2)) : args
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), pendingHandoffs.contains(where: { $0.platform == args[0] }) else { return }
        let observations = ["readiness", "details", "apps", "processes", "hid-info", "tree", "screenshot", "files", "pull", "reports", "report", "logs"]
        guard !observations.contains(args[2]) else { return }
        guard let id = DeviceTarget.identifier(args[1]), args[0] != "physical" || UUID(uuidString: args[1]) == nil else {
            throw CommandFailure(description: "Use an explicit device ID (physical hardware UDID or simulator UUID) while a handoff is pending; aliases cannot be resolved safely for pause coordination.")
        }
        if pendingHandoffs.contains(DeviceTarget(platform: args[0], identifier: id)) {
            throw CommandFailure(description: "Automation is paused for this device while human handoff is pending. Wait for the person's response.")
        }
    }
}
