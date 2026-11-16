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
        let plan = try DeviceCommand.plan(physical: true, device: device, operation: "details")
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

    /// A command line in the CLI's grammar, parsed by the CLI's parser: how MCP
    /// tools run. `dryRun` adds to a parsed `--dry-run`. The environment never
    /// supplies the target.
    func run(_ arguments: [String], dryRun: Bool = false, allowInteractive: Bool = false,
             handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)? = nil) async throws -> CommandOutput {
        let invocation = try CLI.invocation(arguments)
        return try await execute(invocation.request, dryRun: dryRun || invocation.dryRun, allowInteractive: allowInteractive,
                                 handoffConfirmation: handoffConfirmation)
    }

    func execute(_ request: CommandRequest, dryRun: Bool = false, allowInteractive: Bool = false,
                 handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)? = nil) async throws -> CommandOutput {
        do {
            return try await perform(request, dryRun: dryRun, allowInteractive: allowInteractive, handoffConfirmation: handoffConfirmation)
        } catch let failure as CommandFailure where dryRun || request.isReadOnly {
            // A dry run never contacts a device and an observation sends it
            // nothing, whatever stage failed; the message is unchanged.
            throw failure.noInputSent()
        }
    }

    private func perform(_ request: CommandRequest, dryRun: Bool, allowInteractive: Bool,
                         handoffConfirmation: (@Sendable (HandoffCommand) async throws -> HandoffStatus)?) async throws -> CommandOutput {
        try Task.checkCancellation()
        switch request {
        case .mediaStatus(let device):
            if dryRun {
                return try json(["backend": "coredevice-direct", "operation": "media-status", "readOnly": true,
                    "execution": "Read native Apple media support/status only; no stream start/stop, negotiation or decoding."])
            }
            return CommandOutput(data: try NativeMediaInspection.execute(device: device, query: { plan in
                try self.runner.run(plan.arguments, executable: plan.executable, timeout: 20)
            }))
        case .decodeArchive(let path):
            if dryRun { return try json(["backend": "foundation", "operation": "decode-ax-archive", "path": path, "execution": "In-process structural inspection; no device query or helper executable."]) }
            return CommandOutput(data: try KeyedArchiveInspector.inspectFile(path))
        case .physicalInput(let native):
            return try await executePhysical(native, dryRun: dryRun)
        case .simulatorInput(let simulator):
            if dryRun { return try json(simulator.plan()) }
            return try await executeSimulator(simulator)
        case .handoff(let handoff):
            if dryRun { return try json(["platform": handoff.platform, "device": handoff.device, "message": handoff.message, "action": "Request human completion; no device action or prompt is executed by this dry run."]) }
            guard pendingHandoffs.insert(handoff.target).inserted else { throw CommandFailure(.handoffPending, "A handoff is already pending for this device.", inputSent: .none) }
            defer { pendingHandoffs.remove(handoff.target) }
            if let handoffConfirmation {
                let status = try await handoffConfirmation(handoff)
                return try handoff.output(status, mechanism: "mcp-form")
            }
            guard allowInteractive else { throw CommandFailure(.hostRequirement, "Handoff requires a terminal or an MCP host with form elicitation.", inputSent: .none) }
            return try handoff.output(TerminalHandoff.confirm(handoff), mechanism: "terminal")
        case .ocr(let path):
            guard !dryRun else { throw CommandFailure.usage(CLI.noPlanMessage) }
            let result = try await ScreenText.recognize(path: path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return CommandOutput(data: try encoder.encode(result))
        case .devices(let simulators):
            guard !dryRun else { throw CommandFailure.usage(CLI.noPlanMessage) }
            let data = try runner.run(simulators ? ["simctl", "list", "devices", "available", "--json"]
                                                 : ["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-"])
            _ = try JSONSerialization.jsonObject(with: data)
            return CommandOutput(data: data)
        case .doctor:
            guard !dryRun else { throw CommandFailure.usage(CLI.noPlanMessage) }
            return try Doctor.run { try runner.run($0) }
        case .keyboardLayouts:
            guard !dryRun else { throw CommandFailure.usage(CLI.noPlanMessage) }
            return try json(KeyboardLayout.available().map {
                ["name": $0.name, "identifier": $0.identifier, "localizedName": $0.localizedName]
            })
        case .screen(let screen):
            if !dryRun { try checkHandoffPause(request) }
            return try await executeScreen(screen, dryRun: dryRun)
        case .readiness(let device):
            if !dryRun { try checkHandoffPause(request) }
            return try executeReadiness(device, dryRun: dryRun)
        case .record(let recording):
            if !dryRun { try checkHandoffPause(request) }
            return try await executeRecording(recording, dryRun: dryRun)
        case .frames(let frames):
            if dryRun { return try json(frames.plan()) }
            try checkHandoffPause(request)
            return try await executeFrames(frames)
        case .detectLayout(let detection):
            return try await executeLayoutDetection(detection, dryRun: dryRun)
        case .buildRun(let command):
            if !dryRun { try checkHandoffPause(request) }
            return try executeBuildRun(command, dryRun: dryRun)
        case .diagnostics(let diagnostics):
            if !dryRun { try checkHandoffPause(request) }
            return try await executeDiagnostics(diagnostics, dryRun: dryRun)
        case .tool(let tool):
            if !dryRun { try checkHandoffPause(request) }
            let command = tool.command
            if dryRun { return try json(["executable": command.executable, "arguments": command.arguments]) }
            if tool.needsPreflight { try preflight(tool.device, operation: tool.operation) }
            let data = try runner.run(command.arguments, executable: command.executable)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            return CommandOutput(data: data)
        case .simulatorDisplay(let display):
            if dryRun { return try json(display.plan()) }
            try checkHandoffPause(request)
            return CommandOutput(data: try display.execute(environment: simulator, run: { try runner.run($0.arguments, executable: $0.executable) }))
        }
    }

    /// The simulator display a capture uses (`SimulatorDisplays.select`); nil
    /// for a physical device. Reading it sends no input.
    private func captureDisplay(physical: Bool, device: String, requested: String?) throws -> SimulatorDisplaySelection? {
        guard !physical else { return nil }
        do { return try SimulatorDisplays.select(requested, in: SimulatorDisplays.read(device, environment: simulator)) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
    }

    /// Native physical input and accessibility: dry-run plans, the handoff
    /// pause, readiness and identity, the lease for anything but an
    /// observation, then the operation.
    private func executePhysical(_ native: CoreDeviceInput, dryRun: Bool) async throws -> CommandOutput {
            if dryRun {
                let identity = try native.identityPlan()
                if ["press-id", "press-label", "scroll-id", "scroll-label"].contains(native.operation) {
                    let press = try DirectAccessibilityAction(native)
                    return try json(["backend": "coredevice-direct", "operation": press.operation, "selector": ["by": press.by, "text": press.text],
                        "identityArguments": identity.arguments, "liveVerified": false,
                        "execution": "Native AX: primary portrait display selection, two unique snapshots and live state/frame guards before one action. Press checks exact hit; scroll follows with fresh visibility/frame/hit and selection checks. No fallback or replay."])
                }
                if DirectAccessibilitySetValue.operations.contains(native.operation) {
                    let action = try DirectAccessibilitySetValue(native)
                    return try json(["backend": "coredevice-direct", "operation": action.operation,
                        "selector": ["by": action.guards.by, "text": action.guards.text], "pid": action.guards.pid.map { $0 as Any } ?? NSNull(),
                        "requestedUTF8Bytes": action.value.utf8.count, "identityArguments": identity.arguments, "liveVerified": false,
                        "execution": "Native AX: primary display-centre selection, two unique snapshots, live state/frame guards and an exact centre hit as for press; then a settable query (request type 3, attribute 53) that must answer true, one set-value request (type 8, attribute 53) replacing the element's whole value, and one read-back of the value. No keyboard, clipboard, fallback or replay."])
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
                    let (text, layout) = try DirectPhysicalTyping.request(native.operands, subject: "Physical")
                    var plan = DirectPhysicalTyping.fields(text, layout: layout, samples: try layout.samples(text))
                    plan.merge(["backend": "coredevice-direct", "operation": "type", "identityArguments": identity.arguments,
                                "deviceLayoutCheck": DeviceKeyboardLayout.physical(layout),
                                "execution": "In-process Apple Indigo keyboard at current focus; no clipboard operation or helper executable."]) { _, new in new }
                    return try json(plan)
                }
                guard (["button", "key"] + DirectPhysicalTouch.operations).contains(native.operation) else {
                    throw CommandFailure.unsupported("Unsupported native physical operation: \(native.operation).")
                }
                return try json(["backend": "coredevice-direct", "identityArguments": identity.arguments,
                    "operation": native.operation, "operands": native.operands,
                    "execution": "In-process Apple CoreDevice/RemoteXPC; fresh display checks for touch; no helper executable."])
            }
            try checkHandoffPause(.physicalInput(native))
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
            if (["tree", "press-id", "press-label", "scroll-id", "scroll-label"] + DirectAccessibilitySetValue.operations).contains(native.operation) {
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

    private func executeScreen(_ screen: ScreenCommand, dryRun: Bool) async throws -> CommandOutput {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/screen-\(UUID().uuidString)")
            if dryRun {
                let plan = try screen.capturePlan(image: directory.appendingPathComponent("screen.png"))
                var output: [String: Any] = ["executable": plan.executable, "arguments": plan.arguments, "analysisMode": screen.mode.rawValue,
                    "analysis": "Prefer accessibility in auto mode (physical selects the app at primary display centre; simulators the frontmost application, else the one at screen centre); fall back to Vision OCR, then explicitly report image-only if analysis fails."]
                if screen.platform == "simulator" {
                    output["display"] = ["requested": screen.display.map { $0 as Any } ?? NSNull(),
                                         "resolution": SimulatorDisplays.resolution + " A display the interface is not on is described by OCR only."]
                }
                return try json(output)
            }
            if screen.platform == "physical" { try preflight(screen.device, operation: "capture screen") }
            var screen = screen
            screen.selection = try captureDisplay(physical: screen.platform == "physical", device: screen.device, requested: screen.display)
            return CommandOutput(data: try await screen.execute(directory: directory,
                run: { try runner.run($0.arguments, executable: $0.executable) },
                hierarchy: { try await self.execute(.tree(platform: screen.platform, device: screen.device)).data }))
    }

    private func executeReadiness(_ device: String, dryRun: Bool) throws -> CommandOutput {
            if dryRun {
                let plan = try DeviceCommand.plan(physical: true, device: device, operation: "details")
                return try json(["executable": plan.executable, "arguments": plan.arguments + ["--quiet"],
                    "additionalReadOnlyQueries": ["displays", "lockState"],
                    "targetResolution": "Additional UI observations use the UUID resolved from fresh details; no queries are performed in dry run."] as [String: Any])
            }
            let details = try readinessQuery(device)
            var report = try DeviceReadiness.decode(details, device: device)
            report.ui = try DeviceUIReadiness.observe(details: details, device: device, query: uiReadinessQuery)
            return try report.output()
    }

    private func executeRecording(_ recording: RecordingCommand, dryRun: Bool) async throws -> CommandOutput {
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
                var output: [String: Any] = ["executable": plan.executable, "arguments": plan.arguments,
                    "destination": recording.destination.path, "durationSeconds": recording.seconds,
                    "stopPolicy": recording.native ? "Timestamped live frames; AVFoundation MP4 encoding; no automatic backend fallback." : (recording.physical ? "devicectl --duration" : "Wait for first frame, then SIGINT after duration; wait for finalization.")]
                if !recording.physical {
                    output["display"] = ["requested": recording.display.map { $0 as Any } ?? NSNull(), "resolution": SimulatorDisplays.resolution]
                }
                return try json(output)
            }
            var recording = recording
            // Recording sends no input, so none of its failures can have.
            do {
                if recording.physical { try preflight(recording.device, operation: "record screen") }
                recording.selection = try captureDisplay(physical: recording.physical, device: recording.device, requested: recording.display)
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

    /// `frames`: the directory is checked before the device is contacted; the
    /// lease is held for the whole stream, as for a native recording.
    private func executeFrames(_ frames: FramesCommand) async throws -> CommandOutput {
        do {
            guard #available(macOS 26.0, *) else {
                throw CommandFailure(.hostRequirement, "frames requires macOS 26 or later.", inputSent: .none)
            }
            try frames.prepareDirectory()
            try preflight(frames.device, operation: "capture frames")
            let lease = try leases.acquire(device: CoreDeviceInput.resolve(readinessQuery(frames.device), requested: frames.device), operation: "frames")
            defer { lease.release() }
            return CommandOutput(data: try await NativeFrameCapture.execute(frames, runner: runner))
        } catch let failure as CommandFailure {
            // Frame capture sends no input, so none of its failures can have.
            throw failure.noInputSent()
        }
    }

    /// `detect-layout`: the lease is held for the whole detection; each step
    /// is an existing operation (tree read, guarded set-value, keyboard
    /// schedule), run on this service's queue (docs/physical-typing.md).
    private func executeLayoutDetection(_ command: LayoutDetectionCommand, dryRun: Bool) async throws -> CommandOutput {
        let probe = try LayoutProbe.installed()
        if dryRun { return try json(command.plan(probe)) }
        try checkHandoffPause(.detectLayout(command))
        let lease: DeviceLease
        let keyboard: LayoutDetection.Keyboard
        var setting: @Sendable () -> [String: Any]? = { nil }
        do {
            switch command.platform {
            case .physical:
                let details = try readinessQuery(command.device)
                let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: command.device, operation: "type", operands: []),
                                                                query: { _ in details })
                lease = try leases.acquire(device: identity.uuid, operation: "detect-layout")
                keyboard = .physical(uuid: identity.uuid, version: identity.version)
            case .simulator:
                _ = try SimulatorDevice.requireBooted(command.device, operation: "detect-layout", lookup: simulator.lookup)
                lease = try leases.acquire(device: command.device, operation: "detect-layout")
                keyboard = .simulator(command.device)
                let environment = simulator, device = command.device
                setting = { DeviceKeyboardLayout.simulatorSetting(Result { try environment.keyboardPreferences(device) }, sources: KeyboardLayout.available()) }
            }
        } catch let failure as CommandFailure {
            throw failure.noInputSent()
        }
        defer { lease.release() }
        let operations = LayoutDetection.Operations(
            read: { try await self.detectionRead(command) },
            set: { try await self.detectionSet(command, $0) },
            keys: { try await self.detectionKeys($0, keyboard) },
            deviceSetting: setting)
        return try json(await LayoutDetection.run(command, probe: probe, operations: operations))
    }

    private func detectionRead(_ command: LayoutDetectionCommand) async throws -> String {
        let tree = try await execute(.input(command.target, "tree", command.pid.map { [String($0)] } ?? []))
        return try LayoutDetection.fieldValue(fromTree: tree.data, by: command.by, text: command.text)
    }

    private func detectionSet(_ command: LayoutDetectionCommand, _ value: String) async throws -> Bool {
        let receipt = try await execute(.input(command.target, command.setValueOperation, command.selectorOperands + [value]))
        let fields = try JSONSerialization.jsonObject(with: receipt.data) as? [String: Any]
        return fields?["valueMatches"] as? Bool == true
    }

    /// On this service's queue, as every blocking device call is.
    private func detectionKeys(_ schedule: LayoutDetection.KeySchedule, _ keyboard: LayoutDetection.Keyboard) throws {
        try LayoutDetection.send(schedule, to: keyboard, simulator: simulator)
    }

    private func executeBuildRun(_ command: BuildRunCommand, dryRun: Bool) throws -> CommandOutput {
            var command = command
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

    /// Simulator input and accessibility. The order mirrors the physical path:
    /// handoff pause for mutations, then the device lookup (an unbooted
    /// simulator is refused here), then the lease keyed by the simulator UUID
    /// for anything that can change the simulator, then the operation.
    private func executeSimulator(_ simulator: SimulatorInput) async throws -> CommandOutput {
        try checkHandoffPause(.simulatorInput(simulator))
        let info: SimulatorDeviceInfo
        let lease: DeviceLease?
        do {
            info = try SimulatorDevice.requireBooted(simulator.device, operation: simulator.operation, lookup: self.simulator.lookup)
            lease = simulator.isObservation ? nil : try leases.acquire(device: simulator.device, operation: simulator.operation)
        } catch let failure as CommandFailure {
            throw failure.noInputSent()
        }
        defer { lease?.release() }
        if SimulatorHinge.operations.contains(simulator.operation) {
            return CommandOutput(data: try SimulatorHinge.execute(simulator, info: info, environment: self.simulator))
        }
        if SimulatorInput.inputOperations.contains(simulator.operation) {
            return CommandOutput(data: try DirectSimulatorInput.execute(simulator, info: info, environment: self.simulator))
        }
        let data = try await DirectSimulatorAccessibility.execute(simulator, info: info, environment: self.simulator)
        return AccessibilityWait.operations.contains(simulator.operation) ? try AccessibilityWait.output(data) : CommandOutput(data: data)
    }

    /// Native AX reads: no device lease, and not paused by a pending handoff.
    static let nativeObservations = ["tree"] + AccessibilityWait.operations

    /// Device operations that only read: not paused by a pending handoff.
    static let observationOperations = ["readiness", "details", "apps", "processes", "screen", "screenshot", "files", "pull", "reports", "report"]
        + nativeObservations + AppDiagnosticsCommand.observations + ["displays", SimulatorHinge.angleOperation]

    /// `logs`, `console` and `last-crash` (docs/app-logs.md). The handoff
    /// pause has already applied to `console`; none of them takes a lease.
    private func executeDiagnostics(_ command: AppDiagnosticsCommand, dryRun: Bool) async throws -> CommandOutput {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        switch command {
        case .logs(let capture):
            if dryRun { return try json(capture.plan()) }
            let runner = self.runner
            return CommandOutput(data: try await UnifiedLogExecution.execute(capture, environment: simulator,
                run: { try runner.run($0, timeout: 15) }))
        case .console(let capture):
            let target = directory.appendingPathComponent("tmp/console-\(UUID().uuidString)")
            if dryRun { return try json(capture.plan(directory: target)) }
            if capture.physical {
                try preflight(capture.device, operation: "console")
                return CommandOutput(data: try await AppConsole.executePhysical(capture, directory: target))
            }
            let runner = self.runner
            let environment = ConsoleEnvironment(lookup: simulator.lookup, run: { try runner.run($0, timeout: 30, environment: $1) })
            return CommandOutput(data: try await AppConsole.executeSimulator(capture, directory: target, environment: environment))
        case .lastCrash(let query):
            if dryRun { return try json(query.plan()) }
            if query.physical {
                try preflight(query.device, operation: "last-crash")
                return CommandOutput(data: try CrashReportSelection.executePhysical(query,
                    directory: directory.appendingPathComponent("tmp/crash-\(UUID().uuidString)"),
                    run: { try self.runner.run($0.arguments, executable: $0.executable, timeout: 90) }))
            }
            return CommandOutput(data: try CrashReportSelection.executeSimulator(query, environment: simulator))
        }
    }

    private func json(_ value: Any) throws -> CommandOutput {
        CommandOutput(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
    }

    private func checkHandoffPause(_ request: CommandRequest) throws {
        guard let (platform, device, operation) = request.addressed,
              pendingHandoffs.contains(where: { $0.platform == platform }) else { return }
        guard !Self.observationOperations.contains(operation) else { return }
        guard let id = DeviceTarget.identifier(device), platform != "physical" || UUID(uuidString: device) == nil else {
            throw CommandFailure.usage("Use an explicit device ID (physical hardware UDID or simulator UUID) while a handoff is pending; aliases cannot be resolved safely for pause coordination.")
        }
        if pendingHandoffs.contains(DeviceTarget(platform: platform, identifier: id)) {
            throw CommandFailure(.handoffPending, "Automation is paused for this device while human handoff is pending. Wait for the person's response.", inputSent: .none)
        }
    }
}
