import Foundation

struct CommandOutput: Sendable {
    let data: Data
    var exitCode: Int32 = 0
}

/// CLI and MCP share validation, backend selection, and execution. Synchronous
/// actions serialize here; asynchronous observations/recording can interleave.
actor CommandService {
    // Device operations block: child processes, XPC replies and timed input
    // schedules. Running them on the shared cooperative pool would hold one of
    // its few threads for a whole gesture or query and starve unrelated work,
    // such as the MCP server's request handling. This actor therefore runs on a
    // thread of its own queue; `Task.isCancelled` still reaches its callbacks.
    private let queue = DispatchSerialQueue(label: "manzanero.command-service")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let runner = ToolRunner()
    private let readinessQuery: @Sendable (String) throws -> Data
    private let uiReadinessQuery: @Sendable (DeviceCommand) throws -> Data
    private var pendingHandoffs: Set<DeviceTarget> = []
    private let leases: DeviceLeaseRegistry

    init(leases: DeviceLeaseRegistry = .shared, readinessQuery: @escaping @Sendable (String) throws -> Data = { device in
        guard let plan = try DeviceCommand.parse(["physical", device, "details"]) else {
            throw CommandFailure(description: "Cannot plan device readiness query.")
        }
        return try ToolRunner().run(plan.arguments + ["--quiet"])
    }, uiReadinessQuery: @escaping @Sendable (DeviceCommand) throws -> Data = { plan in
        try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 15)
    }) {
        self.leases = leases
        self.readinessQuery = readinessQuery
        self.uiReadinessQuery = uiReadinessQuery
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
        try Task.checkCancellation()
        if let device = try NativeMediaInspection.parse(args) {
            if dryRun {
                return try json(["backend": "coredevice-direct", "operation": "media-status", "readOnly": true,
                    "execution": "Read native Apple media support/status only; no stream start/stop, negotiation or decoding."])
            }
            return CommandOutput(data: try NativeMediaInspection.execute(device: device, query: { plan in
                try self.runner.run(plan.arguments, executable: plan.executable, timeout: 20)
            }))
        }
        if args.first == "decode-ax-archive" {
            guard args.count == 2, !args[1].isEmpty else { throw CommandFailure(description: "Usage: decode-ax-archive <local-plist>") }
            if dryRun { return try json(["backend": "foundation", "operation": "decode-ax-archive", "path": args[1], "execution": "In-process structural inspection; no device query or helper executable."]) }
            return CommandOutput(data: try KeyedArchiveInspector.inspectFile(args[1]))
        }
        if args.count >= 2, args[0] == "--physical-backend", args[1] == "idevice" {
            if !dryRun { try DeviceExecutablePolicy.validate("/usr/bin/env", arguments: ["manzanero-idevice"]) }
            let forwarded = Array(args.dropFirst(2))
            let target = forwarded.first == "--pairing-file" ? Array(forwarded.dropFirst(2)) : forwarded
            guard target.count >= 3, target[0] == "physical" else { throw CommandFailure(description: "--physical-backend requires a physical input command.") }
            return try json(["backend": "idevice", "executionAvailable": false, "arguments": forwarded,
                "limitation": "The explicitly selected non-Apple executable backend is disabled; no fallback will run."])
        }
        let nativeArguments = CoreDeviceInput.selectDefaultBackend(args)
        if let native = try CoreDeviceInput.parse(nativeArguments) {
            if dryRun {
                let identity = try native.identityPlan()
                if ["press-id", "press-label", "scroll-id", "scroll-label"].contains(native.operation) {
                    let press = try DirectAccessibilityAction(native)
                    return try json(["backend": "coredevice-direct", "operation": press.operation, "selector": ["by": press.by, "text": press.text],
                        "identityArguments": identity.arguments, "liveVerified": false,
                        "execution": "Native AX: primary portrait display selection, two unique snapshots and live state/frame guards before one action. Press checks exact hit; scroll follows with fresh visibility/frame/hit and selection checks. No fallback or replay."])
                }
                if native.operation == "tree" {
                    return try json(["backend": "coredevice-direct", "operation": "tree", "pid": native.operands.first.flatMap(Int.init).map { $0 as Any } ?? NSNull(),
                        "identityArguments": identity.arguments, "liveVerified": false,
                        "execution": "Native Apple tunnel assertion, exact-address RSD discovery, Apple Network/RemoteXPC directory, raw AX DTX reads and application identity recheck. Omitted PID selects/rechecks primary portrait display-centre process and Apple display geometry; no helper or fallback."])
                }
                if DirectPhysicalGesture.handles(native) {
                    let sequence = try DirectPhysicalGesture.sequence(for: native)
                    return try json(["backend": "coredevice-direct", "operation": native.operation, "identityArguments": identity.arguments,
                        "frameCount": sequence.times.count, "contactSlots": sequence.contactCount,
                        "durationMilliseconds": sequence.times.last ?? 0,
                        "execution": "In-process Apple Universal HID; fresh display checks and touchscreen discovery; no helper executable or automatic replay."])
                }
                if native.operation == "paste" {
                    return try json(["backend": "coredevice-direct", "operation": "paste", "identityArguments": identity.arguments,
                        "clipboardArguments": native.clipboardPlan("<resolved CoreDevice UUID>").arguments,
                        "stdinUTF8Bytes": native.operands[0].utf8.count,
                        "clipboardEffect": "Replace device clipboard; paste once at current focus; clipboard is not restored; no automatic replay.",
                        "execution": "Apple devicectl clipboard write followed by in-process Indigo Command+V; no helper executable."])
                }
                if native.operation == "type" {
                    return try json(["backend": "coredevice-direct", "operation": "type", "identityArguments": identity.arguments,
                        "layout": "US", "characterCount": native.operands[0].utf8.count,
                        "sampleCount": try DirectPhysicalTyping.samples(native.operands[0]).count,
                        "execution": "In-process Apple Indigo keyboard at current focus; no clipboard operation or helper executable."])
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
            // Input and AX actions own the device across processes for their
            // duration; a tree read is an observation and takes no lease.
            // Readiness and identity are checked first, so preparation errors
            // keep their meaning and the lease is keyed by the resolved CoreDevice
            // identifier, whichever alias the caller used. The operation then
            // reuses these details for its own first identity read instead of
            // querying the device a second time.
            var details: Data? = try readinessQuery(native.device)
            let lease: DeviceLease?
            if native.operation == "tree" {
                lease = nil
            } else {
                let resolved = try DirectPhysicalInput.identity(native, query: { _ in details ?? Data() })
                lease = try leases.acquire(device: resolved.uuid, operation: native.operation)
            }
            defer { lease?.release() }
            let query: (DeviceCommand) throws -> Data = { plan in
                if plan.executable == identity.executable, plan.arguments == identity.arguments {
                    if let prefetched = details {
                        details = nil
                        return prefetched
                    }
                    return try self.readinessQuery(native.device)
                }
                return try self.runner.run(plan.arguments, executable: plan.executable, timeout: 40)
            }
            if ["tree", "press-id", "press-label", "scroll-id", "scroll-label"].contains(native.operation) {
                return CommandOutput(data: try await DirectPhysicalAccessibility.executeNativeRSD(native, query: query))
            }
            if native.operation == "key" {
                return CommandOutput(data: try DirectPhysicalKeyboard.execute(native, query: query))
            }
            if DirectPhysicalGesture.handles(native) {
                return CommandOutput(data: try DirectPhysicalGesture.execute(native, query: query))
            }
            if native.operation == "type" {
                return CommandOutput(data: try DirectPhysicalTyping.execute(native, query: query))
            }
            if native.operation == "paste" {
                return CommandOutput(data: try DirectPhysicalPaste.execute(native, query: query, copy: { plan, data in
                    try self.runner.run(plan.arguments, executable: plan.executable, timeout: 40, inputData: data)
                }))
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
            return CommandOutput(data: try await screen.execute(directory: directory,
                run: { try runner.run($0.arguments, executable: $0.executable) },
                hierarchy: { try await self.execute([screen.platform, screen.device, "tree"]).data }))
        }
        if args.count == 3, args[0] == "physical", args[2] == "readiness" {
            guard !args[1].isEmpty, !args[1].hasPrefix("-") else { throw CommandFailure(description: "Provide a valid device identifier.") }
            if dryRun {
                guard let plan = try DeviceCommand.parse(["physical", args[1], "details"]) else { throw CommandFailure(description: "Invalid device.") }
                return try json(["executable": plan.executable, "arguments": plan.arguments + ["--quiet"],
                    "additionalReadOnlyQueries": ["displays", "lockState"],
                    "targetResolution": "Additional UI observations use the UUID resolved from fresh details; no queries are performed in dry run."] as [String: Any])
            }
            let details = try readinessQuery(args[1])
            var report = try DeviceReadiness.decode(details, device: args[1])
            report.ui = try DeviceUIReadiness.observe(details: details, device: args[1], query: uiReadinessQuery)
            return try report.output()
        }
        if let recording = try RecordingCommand.parse(args) {
            if !dryRun { try checkHandoffPause([recording.physical ? "physical" : "simulator", recording.device, "record"]) }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/recording-\(UUID().uuidString)")
            if dryRun {
                if recording.native {
                    return try json(["execution": "in-process", "backend": "coredevice-videotoolbox",
                        "frameworks": ["AVConference", "VideoToolbox", "AVFoundation"], "destination": recording.destination.path,
                        "durationSeconds": recording.seconds, "codec": recording.codec,
                        "stopPolicy": "Owned stream stop and fresh absence check, VideoToolbox invalidation, tunnel assertion release; publish only after artifact validation."] as [String: Any])
                }
                let plan = try recording.command(staging: directory.appendingPathComponent("capture.mp4"))
                let output: [String: Any] = ["executable": plan.executable, "arguments": plan.arguments,
                    "destination": recording.destination.path, "durationSeconds": recording.seconds,
                    "stopPolicy": recording.native ? "Timestamped live frames; AVFoundation MP4 encoding; no automatic backend fallback." : (recording.physical ? "devicectl --duration" : "Wait for first frame, then SIGINT after duration; wait for finalization.")]
                return try json(output)
            }
            if recording.physical { try preflight(recording.device, operation: "record screen") }
            // The native stream is owned for the whole capture. This process
            // may still send input meanwhile; another process may not.
            let lease = recording.native
                ? try leases.acquire(device: CoreDeviceInput.resolve(readinessQuery(recording.device), requested: recording.device), operation: "record")
                : nil
            defer { lease?.release() }
            return CommandOutput(data: try await recording.execute(directory: directory, runner: runner))
        }
        if var command = try BuildRunCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/build-run-\(UUID().uuidString)")
            if dryRun { return try json(command.dryRunPlan(directory: directory)) }
            if command.physical { try preflight(command.device, operation: "build and run") }
            if command.requiresDestinationResolution {
                let details = try? readinessQuery(command.device)
                command = try command.resolvingDestination(details: details ?? Data())
            }
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
            guard values.count == 2 else { throw CommandFailure(description: "Usage: manzanero ocr <image-path>") }
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
            throw CommandFailure(description: "Unknown command. Run manzanero --help.")
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
