import Foundation

struct CommandOutput: Sendable {
    let data: Data
    var exitCode: Int32 = 0
}

/// CLI and MCP share validation, backend selection, and execution. Synchronous
/// actions serialize here; asynchronous observations/recording can interleave.
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
        if args.count >= 2, args[0] == "--physical-backend", args[1] == "idevice" {
            if !dryRun { try DeviceExecutablePolicy.validate("/usr/bin/env", arguments: ["appledevices-idevice"]) }
            let forwarded = Array(args.dropFirst(2))
            let target = forwarded.first == "--pairing-file" ? Array(forwarded.dropFirst(2)) : forwarded
            guard target.count >= 3, target[0] == "physical" else { throw CommandFailure(description: "--physical-backend requires a physical input command.") }
            return try json(["backend": "idevice", "executionAvailable": false, "arguments": forwarded,
                "limitation": "The explicitly selected non-Apple executable backend is disabled; no fallback will run."])
        }
        let nativeArguments = args.count >= 3 && args[0] == "physical" && (["button", "key"] + DirectPhysicalTouch.operations).contains(args[2])
            ? ["--physical-backend", "coredevice"] + args : args
        if let native = try CoreDeviceInput.parse(nativeArguments) {
            if dryRun {
                let identity = try native.identityPlan()
                if native.operation == "multi-drag", native.operands.count != 9 {
                    return try json(["backend": "coredevice-direct", "executionAvailable": false,
                        "limitation": "Direct multi-drag currently supports exactly two paths; three-to-five-contact input awaits direct migration."])
                }
                if (["button", "key"] + DirectPhysicalTouch.operations).contains(native.operation) {
                    return try json(["backend": "coredevice-direct", "identityArguments": identity.arguments,
                        "operation": native.operation, "operands": native.operands,
                        "execution": "In-process Apple CoreDevice/RemoteXPC; fresh display checks for touch; no helper executable."])
                }
                let action = try native.actionPlan("<resolved CoreDevice UUID>", surface: "<discovered HID surface ID>")
                var plan: [String: Any] = ["backend": "coredevice-ipb", "executionAvailable": false,
                    "limitation": "Historical helper plan only; non-Apple executables are disabled pending the direct implementation.", "identityArguments": identity.arguments,
                    "executable": action.executable, "actionArguments": action.arguments,
                    "discovery": "Touch/keyboard operations discover exactly one matching HID surface before input; dry run queries nothing."]
                if native.operation == "paste" {
                    plan["clipboardArguments"] = native.clipboardPlan("<resolved CoreDevice UUID>").arguments
                    plan["clipboardEffect"] = "Replace device clipboard; then paste once at the focused caret/selection. Clipboard is not restored."
                    plan["stdinUTF8Bytes"] = native.operands[0].utf8.count
                }
                return try json(plan)
            }
            try checkHandoffPause(Array(nativeArguments.dropFirst(2)))
            let identity = try native.identityPlan()
            let query: (DeviceCommand) throws -> Data = { plan in
                if plan.executable == identity.executable, plan.arguments == identity.arguments {
                    return try self.readinessQuery(native.device)
                }
                return try self.runner.run(plan.arguments, executable: plan.executable, timeout: 40)
            }
            if native.operation == "key" {
                return CommandOutput(data: try DirectPhysicalKeyboard.execute(native, query: query))
            }
            if native.operation != "button" {
                return CommandOutput(data: try DirectPhysicalTouch.execute(native, query: query))
            }
            return CommandOutput(data: try DirectPhysicalInput.execute(native, query: query))
        }
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
        if let screen = try ScreenCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/screen-\(UUID().uuidString)")
            if dryRun {
                let plan = try screen.capturePlan(image: directory.appendingPathComponent("screen.png"))
                return try json(["executable": plan.executable, "arguments": plan.arguments, "analysisMode": screen.mode.rawValue,
                    "analysis": "Prefer accessibility in auto mode (physical selects the app at primary display centre); fall back to Vision OCR, then explicitly report image-only if analysis fails."])
            }
            if screen.platform == "physical" { try preflight(screen.device, operation: "capture screen") }
            return CommandOutput(data: try await screen.execute(directory: directory, run: { try runner.run($0.arguments, executable: $0.executable) }))
        }
        if args.count == 3, args[0] == "physical", args[2] == "readiness" {
            if dryRun {
                guard let plan = try DeviceCommand.parse(["physical", args[1], "details"]) else { throw CommandFailure(description: "Invalid device.") }
                return try json(["executable": plan.executable, "arguments": plan.arguments + ["--quiet"]])
            }
            return try readiness(args[1]).output()
        }
        if let recording = try RecordingCommand.parse(args) {
            if !dryRun { try checkHandoffPause([recording.physical ? "physical" : "simulator", recording.device, "record"]) }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/recording-\(UUID().uuidString)")
            if dryRun {
                let plan = recording.command(staging: directory.appendingPathComponent("capture.mp4"))
                var output: [String: Any] = ["executable": plan.executable, "arguments": plan.arguments,
                    "destination": recording.destination.path, "durationSeconds": recording.seconds,
                    "stopPolicy": recording.native ? "Timestamped live frames; AVFoundation MP4 encoding; no automatic backend fallback." : (recording.physical ? "devicectl --duration" : "Wait for first frame, then SIGINT after duration; wait for finalization.")]
                if recording.native {
                    output["executionAvailable"] = false
                    output["limitation"] = "Historical video helper plan only; direct Apple capture replacement pending."
                }
                return try json(output)
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
            let targetArgs = args.first == "--pairing-file" ? Array(args.dropFirst(2)) : args
            let archivePath = targetArgs.count == 4 && targetArgs[0] == "physical" && targetArgs[2] == "ax-snapshot" ? targetArgs[3] : nil
            if dryRun {
                var plan: [String: Any] = ["executable": command.executable, "arguments": command.arguments]
                do { try DeviceExecutablePolicy.validate(command.executable, arguments: command.arguments) }
                catch { plan["executionAvailable"] = false; plan["limitation"] = String(describing: error) }
                if let archivePath { plan["archiveDestination"] = archivePath }
                return try json(plan)
            }
            if let archivePath { try AccessibilityArchive.validateDestination(archivePath) }
            if targetArgs.count >= 3, targetArgs[0] == "physical",
               ["tap", "multi-tap", "multi-drag", "pinch", "drag", "swipe", "button", "key", "type", "hid-info", "ax-snapshot", "tree", "press-id", "press-label", "scroll-id", "scroll-label", "launch", "terminate", "processes", "open-url", "screenshot"].contains(targetArgs[2]) {
                try preflight(targetArgs[1], operation: targetArgs[2])
            }
            guard allowInteractive || !command.interactive else {
                throw CommandFailure(description: "Interactive pairing is CLI-only; pair first, then provide the existing pairing file.")
            }
            let data = try runner.run(command.arguments, executable: command.executable, interactive: command.interactive)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            if let archivePath { return CommandOutput(data: try AccessibilityArchive.save(data, to: archivePath)) }
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
        let observations = ["readiness", "details", "apps", "processes", "hid-info", "tree", "screen", "screenshot", "files", "pull", "reports", "report", "logs"]
        guard !observations.contains(args[2]) else { return }
        guard let id = DeviceTarget.identifier(args[1]), args[0] != "physical" || UUID(uuidString: args[1]) == nil else {
            throw CommandFailure(description: "Use an explicit device ID (physical hardware UDID or simulator UUID) while a handoff is pending; aliases cannot be resolved safely for pause coordination.")
        }
        if pendingHandoffs.contains(DeviceTarget(platform: args[0], identifier: id)) {
            throw CommandFailure(description: "Automation is paused for this device while human handoff is pending. Wait for the person's response.")
        }
    }
}
