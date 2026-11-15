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
    private let simulator: SimulatorEnvironment

    init(leases: DeviceLeaseRegistry = .shared, simulator: SimulatorEnvironment = .live, readinessQuery: @escaping @Sendable (String) throws -> Data = { device in
        guard let plan = try DeviceCommand.parse(["physical", device, "details"]) else {
            throw CommandFailure(.internal, "Cannot plan device readiness query.", inputSent: .none)
        }
        return try ToolRunner().run(plan.arguments + ["--quiet"])
    }, uiReadinessQuery: @escaping @Sendable (DeviceCommand) throws -> Data = { plan in
        try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 15)
    }) {
        self.leases = leases
        self.simulator = simulator
        self.readinessQuery = readinessQuery
        self.uiReadinessQuery = uiReadinessQuery
    }

    private func readiness(_ device: String) throws -> DeviceReadiness {
        guard !device.isEmpty, !device.hasPrefix("-") else { throw CommandFailure.usage("Provide a valid device identifier.") }
        return try DeviceReadiness.decode(readinessQuery(device), device: device)
    }

    private func preflight(_ device: String, operation: String) throws {
        let report: DeviceReadiness
        do { report = try readiness(device) }
        catch {
            // Not fatal: the Apple tool that runs next enforces its own prerequisites.
            FileHandle.standardError.write(Data("Unable to determine CoreDevice readiness: \(error). The selected backend will enforce its own prerequisites.\n".utf8))
            return
        }
        try report.requireDeveloperMode(operation: operation)
    }

    func execute(_ args: [String], dryRun: Bool = false, allowInteractive: Bool = false,
                 handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)? = nil) async throws -> CommandOutput {
        do {
            return try await perform(args, dryRun: dryRun, allowInteractive: allowInteractive, handoffConfirmation: handoffConfirmation)
        } catch let failure as CommandFailure where dryRun || Self.isReadOnly(args) {
            // A dry run never contacts a device and an observation sends it
            // nothing, whatever stage failed; the message is unchanged.
            throw failure.noInputSent()
        }
    }

    /// Commands that only read from the device (or touch no device at all).
    /// Their failures cannot have sent input. Any other command is not
    /// assumed read-only.
    static func isReadOnly(_ args: [String]) -> Bool {
        var args = CoreDeviceInput.selectDefaultBackend(args)
        if args.count >= 2, args[0] == "--physical-backend" { args.removeFirst(2) }
        if args.count >= 3, ["physical", "simulator"].contains(args[0]) {
            return (observationOperations + ["media-status"]).contains(args[2])
        }
        return ["ocr", "devices", "doctor", "decode-ax-archive"].contains(args.first ?? "")
    }

    private func perform(_ args: [String], dryRun: Bool, allowInteractive: Bool,
                         handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)?) async throws -> CommandOutput {
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
            guard args.count == 2, !args[1].isEmpty else { throw CommandFailure.usage("Usage: decode-ax-archive <local-plist>") }
            if dryRun { return try json(["backend": "foundation", "operation": "decode-ax-archive", "path": args[1], "execution": "In-process structural inspection; no device query or helper executable."]) }
            return CommandOutput(data: try KeyedArchiveInspector.inspectFile(args[1]))
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
                if AccessibilityWait.operations.contains(native.operation) {
                    return try json(AccessibilityWait(native).plan(identityArguments: identity.arguments))
                }
                if native.operation == DirectPhysicalWake.operation { return try json(DirectPhysicalWake.plan(native)) }
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
                guard (["button", "key"] + DirectPhysicalTouch.operations).contains(native.operation) else {
                    throw CommandFailure.unsupported("Unsupported native physical operation: \(native.operation).")
                }
                return try json(["backend": "coredevice-direct", "identityArguments": identity.arguments,
                    "operation": native.operation, "operands": native.operands,
                    "execution": "In-process Apple CoreDevice/RemoteXPC; fresh display checks for touch; no helper executable."])
            }
            try checkHandoffPause(Array(nativeArguments.dropFirst(2)))
            let identity = try native.identityPlan()
            // Input and AX actions own the device across processes for their
            // duration; tree reads and waits are observations and take no lease.
            // Readiness and identity are checked first, so preparation errors
            // keep their meaning and the lease is keyed by the resolved CoreDevice
            // identifier, whichever alias the caller used. The operation then
            // reuses these details for its own first identity read instead of
            // querying the device a second time.
            var details: Data?
            let lease: DeviceLease?
            do {
                details = try readinessQuery(native.device)
                if Self.nativeObservations.contains(native.operation) {
                    lease = nil
                } else {
                    let resolved = try DirectPhysicalInput.identity(native, query: { _ in details ?? Data() })
                    lease = try leases.acquire(device: resolved.uuid, operation: native.operation)
                }
            } catch let failure as CommandFailure {
                throw failure.noInputSent()
            }
            defer { lease?.release() }
            // Only read-only devicectl queries (details, displays, lock state)
            // run through this closure, so its failures cannot have sent input.
            let query: (DeviceCommand) throws -> Data = { plan in
                do {
                    if plan.executable == identity.executable, plan.arguments == identity.arguments {
                        if let prefetched = details {
                            details = nil
                            return prefetched
                        }
                        return try self.readinessQuery(native.device)
                    }
                    return try self.runner.run(plan.arguments, executable: plan.executable, timeout: 40)
                } catch let failure as CommandFailure {
                    throw failure.noInputSent()
                }
            }
            if native.operation == DirectPhysicalWake.operation {
                return try DirectPhysicalWake.output(DirectPhysicalWake.execute(native, query: query))
            }
            if AccessibilityWait.operations.contains(native.operation) {
                // A wait suspends between polls, so other calls to this
                // service can run then; each poll's requests still block it.
                return try AccessibilityWait.output(await DirectPhysicalAccessibility.executeNativeRSD(native, query: query))
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
        if let simulator = try SimulatorInput.parse(args) {
            if dryRun { return try json(simulator.plan()) }
            return try await executeSimulator(simulator)
        }
        if let handoff = try HandoffCommand.parse(args) {
            if dryRun { return try json(["platform": handoff.platform, "device": handoff.device, "message": handoff.message, "action": "Request human completion; no device action or prompt is executed by this dry run."]) }
            guard pendingHandoffs.insert(handoff.target).inserted else { throw CommandFailure(.handoffPending, "A handoff is already pending for this device.", inputSent: .none) }
            defer { pendingHandoffs.remove(handoff.target) }
            if let handoffConfirmation {
                let status = try await handoffConfirmation(handoff)
                return try handoff.output(status, mechanism: "mcp-form")
            }
            guard allowInteractive else { throw CommandFailure(.hostRequirement, "Handoff requires a terminal or an MCP host with form elicitation.", inputSent: .none) }
            return try handoff.output(TerminalHandoff.confirm(handoff), mechanism: "terminal")
        }
        if !dryRun { try checkHandoffPause(args) }
        if let screen = try ScreenCommand.parse(args) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/screen-\(UUID().uuidString)")
            if dryRun {
                let plan = try screen.capturePlan(image: directory.appendingPathComponent("screen.png"))
                return try json(["executable": plan.executable, "arguments": plan.arguments, "analysisMode": screen.mode.rawValue,
                    "analysis": "Prefer accessibility in auto mode (physical selects the app at primary display centre; simulators the frontmost application); fall back to Vision OCR, then explicitly report image-only if analysis fails."])
            }
            if screen.platform == "physical" { try preflight(screen.device, operation: "capture screen") }
            return CommandOutput(data: try await screen.execute(directory: directory,
                run: { try runner.run($0.arguments, executable: $0.executable) },
                hierarchy: { try await self.execute([screen.platform, screen.device, "tree"]).data }))
        }
        if args.count == 3, args[0] == "physical", args[2] == "readiness" {
            guard !args[1].isEmpty, !args[1].hasPrefix("-") else { throw CommandFailure.usage("Provide a valid device identifier.") }
            if dryRun {
                guard let plan = try DeviceCommand.parse(["physical", args[1], "details"]) else { throw CommandFailure.usage("Invalid device.") }
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
            // Recording sends no input, so none of its failures can have.
            do {
                if recording.physical { try preflight(recording.device, operation: "record screen") }
                // The native stream is owned for the whole capture. This process
                // may still send input meanwhile; another process may not.
                let lease = recording.native
                    ? try leases.acquire(device: CoreDeviceInput.resolve(readinessQuery(recording.device), requested: recording.device), operation: "record")
                    : nil
                defer { lease?.release() }
                return CommandOutput(data: try await recording.execute(directory: directory, runner: runner))
            } catch let failure as CommandFailure {
                throw failure.noInputSent()
            }
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
            if dryRun { return try json(["executable": command.executable, "arguments": command.arguments]) }
            if args[0] == "physical", ["launch", "terminate", "processes", "open-url", "screenshot"].contains(args[2]) {
                try preflight(args[1], operation: args[2])
            }
            let data = try runner.run(command.arguments, executable: command.executable)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            return CommandOutput(data: data)
        }
        guard !dryRun else { throw CommandFailure.usage("--dry-run requires a physical or simulator command.") }
        switch args {
        case let values where values.first == "ocr":
            guard values.count == 2 else { throw CommandFailure.usage("Usage: manzanero ocr <image-path>") }
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
            return try Doctor.run { try runner.run($0) }
        default:
            throw CommandFailure.usage("Unknown command. Run manzanero --help.")
        }
    }

    /// Simulator input and accessibility. The order mirrors the physical path:
    /// handoff pause for mutations, then the device lookup (an unbooted
    /// simulator is refused here), then the lease keyed by the simulator UUID
    /// for anything that can change the simulator, then the operation.
    private func executeSimulator(_ simulator: SimulatorInput) async throws -> CommandOutput {
        try checkHandoffPause(["simulator", simulator.device, simulator.operation])
        let info: SimulatorDeviceInfo
        let lease: DeviceLease?
        do {
            info = try SimulatorDevice.requireBooted(simulator.device, operation: simulator.operation, lookup: self.simulator.lookup)
            lease = simulator.isObservation ? nil : try leases.acquire(device: simulator.device, operation: simulator.operation)
        } catch let failure as CommandFailure {
            throw failure.noInputSent()
        }
        defer { lease?.release() }
        let data = try await DirectSimulatorAccessibility.execute(simulator, info: info, environment: self.simulator)
        return AccessibilityWait.operations.contains(simulator.operation) ? try AccessibilityWait.output(data) : CommandOutput(data: data)
    }

    /// Native AX reads: no device lease, and not paused by a pending handoff.
    static let nativeObservations = ["tree"] + AccessibilityWait.operations

    /// Device operations that only read: not paused by a pending handoff.
    static let observationOperations = ["readiness", "details", "apps", "processes", "screen", "screenshot", "files", "pull", "reports", "report"]
        + nativeObservations

    private func json(_ value: Any) throws -> CommandOutput {
        CommandOutput(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    }

    private func checkHandoffPause(_ args: [String]) throws {
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), pendingHandoffs.contains(where: { $0.platform == args[0] }) else { return }
        guard !Self.observationOperations.contains(args[2]) else { return }
        guard let id = DeviceTarget.identifier(args[1]), args[0] != "physical" || UUID(uuidString: args[1]) == nil else {
            throw CommandFailure.usage("Use an explicit device ID (physical hardware UDID or simulator UUID) while a handoff is pending; aliases cannot be resolved safely for pause coordination.")
        }
        if pendingHandoffs.contains(DeviceTarget(platform: args[0], identifier: id)) {
            throw CommandFailure(.handoffPending, "Automation is paused for this device while human handoff is pending. Wait for the person's response.", inputSent: .none)
        }
    }
}
