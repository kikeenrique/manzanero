import Foundation

struct CommandOutput: Sendable {
    let data: Data
    var exitCode: Int32 = 0
    /// Lines for a person, which the CLI prints on stderr after the output;
    /// the same facts are in `data`.
    var note: String?
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
    }, handoffWatchPause: Duration = .seconds(2), connectionState: @escaping @Sendable () throws -> Data = StaleDeviceConnection.liveDump,
       tunnelLinks: @escaping @Sendable () -> [String: String] = DeviceTunnelLinks.live,
       inspector: @escaping InspectorRoute.Open = InspectorRoute.live, holdTransport: HoldTransport = .live) {
        self.inspector = inspector
        self.holdTransport = holdTransport
        self.connectionState = connectionState
        self.tunnelLinks = tunnelLinks
        self.leases = leases
        self.simulator = simulator
        self.readinessQuery = readinessQuery
        self.uiReadinessQuery = uiReadinessQuery
        self.handoffWatchPause = handoffWatchPause
    }

    /// The pause between two looks at the device while a handoff watches it.
    private let handoffWatchPause: Duration
    /// remoted's state dump, read only after a query has timed out.
    private let connectionState: @Sendable () throws -> Data
    /// Opens the audit server behind the accessibility shim, for a press
    /// on an Apple TV.
    private let inspector: InspectorRoute.Open
    /// The devices usbmuxd lists, for `devices`.
    private let tunnelLinks: @Sendable () -> [String: String]
    /// Runs a `hold` step's live digitizer stream.
    private let holdTransport: HoldTransport

    private nonisolated func staleConnection(_ failure: CommandFailure) -> CommandFailure {
        StaleDeviceConnection.annotate(failure, dump: connectionState)
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
        } catch let failure as CommandFailure where dryRun {
            // A dry run never contacts a device, whatever stage failed; the
            // message is unchanged.
            throw failure.noInputSent()
        } catch let failure as CommandFailure {
            // A query that timed out may mean the stale connection, which a
            // retry prolongs; the failure then says so.
            let named = staleConnection(failure)
            // An observation sends the device nothing, whatever stage failed.
            throw request.isReadOnly ? named.noInputSent() : named
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
        case .reportingFocus(let press, let tree):
            let pressed = try await perform(press, dryRun: dryRun, allowInteractive: allowInteractive, handoffConfirmation: handoffConfirmation)
            if dryRun {
                var plan = (try? JSONSerialization.jsonObject(with: pressed.data)) as? [String: Any] ?? [:]
                plan["reportFocus"] = RemoteFocusReport.plan
                return try json(plan)
            }
            return await RemoteFocusReport.annotate(pressed) {
                try await Task.sleep(for: RemoteFocusReport.settle)
                return try await self.perform(tree, dryRun: false, allowInteractive: allowInteractive, handoffConfirmation: handoffConfirmation)
            }
        case .simulatorInput(let simulator):
            if dryRun { return try json(simulator.plan()) }
            return try await executeSimulator(simulator)
        case .handoff(let handoff):
            if dryRun {
                var plan: [String: Any] = ["platform": handoff.platform, "device": handoff.device, "message": handoff.message, "action": "Request human completion; no device action or prompt is executed by this dry run."]
                if let condition = handoff.condition {
                    plan["until"] = condition.json
                    plan["timeoutSeconds"] = handoff.timeoutSeconds
                    plan["action"] = "Read the device for the condition, then ask a person and keep reading (read-only, about every 2 s) until it is seen or the timeout passes. Nobody has to answer; at a terminal done, decline and cancel are also taken. Nothing is queried by this dry run."
                }
                return try json(plan)
            }
            guard pendingHandoffs.insert(handoff.target).inserted else { throw CommandFailure(.handoffPending, "A handoff is already pending for this device.", inputSent: .none) }
            defer { pendingHandoffs.remove(handoff.target) }
            if let condition = handoff.condition {
                return try await watchHandoff(handoff, until: condition, terminal: allowInteractive)
            }
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
            guard !simulators else { return CommandOutput(data: data) }
            // Which of them a tunnel of the tool's own can be opened to.
            let annotated = try DeviceTunnelLinks.annotate(data, links: tunnelLinks())
            return CommandOutput(data: annotated.data, note: annotated.summary.joined(separator: "\n"))
        case .createSimulator(let name, let type, let runtime):
            let arguments = ["simctl", "create", name, type] + (runtime.map { [$0] } ?? [])
            if dryRun { return try json(["executable": "/usr/bin/xcrun", "arguments": arguments]) }
            let uuid = String(decoding: try runner.run(arguments, timeout: 120), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: uuid) != nil else {
                throw CommandFailure(.toolFailed, "simctl create did not print a simulator UUID: \(uuid.prefix(200))", inputSent: .none)
            }
            return try json(["status": "created", "udid": uuid, "name": name, "deviceType": type, "runtime": runtime.map { $0 as Any } ?? NSNull(), "state": "Shutdown"] as [String: Any])
        case .doctor:
            guard !dryRun else { throw CommandFailure.usage(CLI.noPlanMessage) }
            return try Doctor.run { try runner.run($0) }
        case .batch(let batch):
            let active = ActiveHold()
            return try await withTaskCancellationHandler {
                try await runBatch(batch, dryRun: dryRun, active: active)
            } onCancel: {
                active.stop()
            }
        case .hold, .release:
            throw CommandFailure.usage(HoldStep.batchOnly)
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
        case .pair(let pair):
            if dryRun { return try json(pair.plan()) }
            try checkHandoffPause(request)
            return CommandOutput(data: try pair.execute(details: readinessQuery(pair.device)))
        case .clearQuarantine(let target):
            if dryRun { return try json(DeviceQuarantine.plan(target)) }
            // The mark is keyed like the lease: by the resolved CoreDevice
            // identifier (a read-only query) or the simulator UUID.
            let key = target.platform == .physical
                ? try CoreDeviceInput.resolve(readinessQuery(target.identifier), requested: target.identifier) : target.identifier
            return try json(DeviceQuarantine.clear(target, key: key, leases: leases))
        case .buildRun(let command):
            if !dryRun { try checkHandoffPause(request) }
            return try executeBuildRun(command, dryRun: dryRun)
        case .diagnostics(let diagnostics):
            if !dryRun { try checkHandoffPause(request) }
            return try await executeDiagnostics(diagnostics, dryRun: dryRun)
        case .tool(let tool):
            if !dryRun { try checkHandoffPause(request) }
            let command = tool.command
            if dryRun {
                var plan: [String: Any] = ["executable": command.executable, "arguments": command.arguments]
                if !command.environment.isEmpty { plan["environment"] = command.environment }
                if let bundle = tool.bundleToResolve {
                    plan["resolve"] = ["bundleId": bundle, "from": ["devicectl device info apps", "devicectl device info processes"],
                                       "rule": "Exactly one running process whose executable is in the app's folder; none or several refuse with nothing terminated."]
                }
                return try json(plan)
            }
            if tool.needsPreflight { try preflight(tool.device, operation: tool.operation) }
            var arguments = command.arguments
            if let bundle = tool.bundleToResolve {
                func query(_ operation: String) throws -> Data {
                    let plan = try DeviceCommand.plan(physical: true, device: tool.device, operation: operation)
                    return try runner.run(plan.arguments, executable: plan.executable)
                }
                let pid = try RunningApp.pid(of: bundle, apps: query("apps"), processes: query("processes"))
                arguments = arguments.map { $0 == DeviceCommand.resolvedPIDPlaceholder ? String(pid) : $0 }
            }
            if tool.operation == "clipboard" {
                // The text is devicectl's stdout; its JSON result goes to a file of this run.
                let directory = URL(fileURLWithPath: "tmp", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("clipboard-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                let text = try runner.run(arguments.map { $0 == DeviceSettings.resultPlaceholder ? file.path : $0 }, executable: command.executable)
                return try json(DeviceSettings.clipboardResult(stdout: text, resultFile: Data(contentsOf: file)))
            }
            let data = try runner.run(arguments, executable: command.executable, environment: command.environment)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            if tool.platform == .physical, tool.operation == "screenshot" {
                let annotated = DeviceUIReadiness.annotateScreenshot(data, device: tool.device, query: uiReadinessQuery)
                let blank = ScreenshotBlank.annotate(annotated, image: ScreenshotBlank.destination(arguments))
                // A black Apple TV picture: one tree says whether Apple's
                // player is in front (on the tool's own tunnel only, as
                // every Apple TV accessibility command).
                return CommandOutput(data: await ScreenshotBlank.annotatePlayer(blank) {
                    try await self.perform(.tree(platform: "physical", device: tool.device), dryRun: false,
                                           allowInteractive: false, handoffConfirmation: nil).data
                })
            }
            return CommandOutput(data: data)
        case .simulatorDisplay(let display):
            if dryRun { return try json(display.plan()) }
            try checkHandoffPause(request)
            return CommandOutput(data: try display.execute(environment: simulator, run: { try runner.run($0.arguments, executable: $0.executable) }))
        }
    }

    /// `batch`: each step runs as it would alone (its own lease, pause check
    /// and quarantine), except inside a hold, where touch steps join the held
    /// contact's stream. The batch stops at the first failure or non-zero exit
    /// code and repeats nothing. A hold still down when the batch ends, fails
    /// or is cancelled is released then.
    private func runBatch(_ batch: BatchCommand, dryRun: Bool, active: ActiveHold) async throws -> CommandOutput {
        var results: [[String: Any]] = []
        var failedStep: Int?
        var holdSummaries: [[String: Any]] = dryRun ? batch.holds.map(\.plan) : []
        var holdFailed = false
        var session: HoldSession?
        // Ends the hold, quarantines the device when the end is unknown, and
        // keeps its summary for the receipt.
        func endHold(by reason: String, releaseStep: Int?, stop: Bool = false) -> (HoldSession, HoldStream.Outcome)? {
            guard let current = session else { return nil }
            session = nil
            active.set(nil)
            let outcome = current.finish(stop: stop)
            if let failure = outcome.failure {
                DeviceQuarantine.note(failure, device: current.uuid, operation: HoldStep.operation, leases: leases)
            }
            holdSummaries.append(current.summary(releasedBy: reason, releaseStep: releaseStep, outcome: outcome))
            return (current, outcome)
        }
        do {
            for (index, step) in batch.requests.enumerated() {
                try Task.checkCancellation()
                let number = index + 1
                var result: [String: Any] = ["step": number, "command": batch.steps[index]]
                if let session, !batch.holds.contains(where: { $0.releaseStep == number }) { session.stepsWhileHeld.append(number) }
                do {
                    let output: CommandOutput
                    switch step {
                    case .hold(let hold):
                        guard let span = batch.holds.first(where: { $0.step == number }) else {
                            throw CommandFailure(.internal, "The batch lost its hold plan; nothing was sent.", inputSent: .none)
                        }
                        if dryRun {
                            output = try json(holdPlan(hold, span: span))
                        } else {
                            let started = try startHold(hold, span: span, active: active)
                            session = started
                            output = try json(started.holdReceipt())
                        }
                    case .release:
                        if dryRun {
                            output = try json(["backend": "coredevice-direct", "operation": HoldStep.releaseOperation,
                                "holdStep": batch.holds.first { $0.releaseStep == number }?.step ?? NSNull(),
                                "execution": "End the hold's live stream: every active contact released in one report, then the service barrier and the drain, as for other touch input. Nothing is queried by this dry run."])
                        } else {
                            guard let (ended, outcome) = endHold(by: "release-step", releaseStep: number) else {
                                throw CommandFailure(.internal, "release found no hold; nothing was sent.", inputSent: .none)
                            }
                            if let failure = outcome.failure { throw failure }
                            var receipt = ended.summary(releasedBy: "release-step", releaseStep: number, outcome: outcome)
                            receipt.merge(["backend": "coredevice-direct", "operation": HoldStep.releaseOperation, "status": "released",
                                           "releaseVerified": false, "device": batch.target.identifier, "holdStep": ended.span.step]) { _, new in new }
                            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                            output = CommandOutput(data: DeviceUIReadiness.annotateInput(data, uuid: ended.uuid, query: uiReadinessQuery))
                        }
                    case .physicalInput(let input) where HoldSegment.handles(input) && batch.hold(containing: number) != nil:
                        if dryRun {
                            output = try json(mergedPlan(input, span: batch.hold(containing: number)!))
                        } else {
                            guard let session else {
                                throw CommandFailure(.internal, "The hold of this step is not down; nothing was sent.", inputSent: .none)
                            }
                            output = try mergeIntoHold(input, session: session, step: number)
                        }
                    default:
                        output = try await execute(step, dryRun: dryRun)
                    }
                    result["exitCode"] = Int(output.exitCode)
                    result["output"] = BatchCommand.output(output.data)
                    if output.exitCode != 0 { failedStep = number }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    let failure = CommandFailure.classify(error)
                    result["exitCode"] = Int(CommandFailure.exitCode(for: error))
                    result["error"] = failure.fields.compactMapValues { $0 }
                    failedStep = number
                }
                results.append(result)
                if failedStep != nil { break }
            }
        } catch {
            // Cancelled: the handler has already stopped the stream; wait
            // for its release before the cancellation goes on.
            _ = endHold(by: "cancelled", releaseStep: nil, stop: true)
            throw error
        }
        if session != nil {
            let reason = failedStep.map { "failed-step \($0)" } ?? "end-of-batch"
            if let (_, outcome) = endHold(by: reason, releaseStep: nil), outcome.failure != nil, failedStep == nil {
                holdFailed = true
            }
        }
        let receipt = BatchCommand.receipt(batch, results: results, failedStep: failedStep, dryRun: dryRun,
                                           holds: holdSummaries, holdFailed: holdFailed)
        return CommandOutput(data: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
                             exitCode: failedStep == nil && !holdFailed ? 0 : 1)
    }

    private func holdPlan(_ hold: HoldStep, span: HoldSpan) throws -> [String: Any] {
        let identity = try CoreDeviceInput(device: hold.device, operation: HoldStep.operation, operands: []).identityPlan()
        var plan = span.plan
        plan.merge(["backend": "coredevice-direct", "operation": HoldStep.operation, "identityArguments": identity.arguments,
                    "displayArguments": Self.displayPlan("<resolved CoreDevice UUID>").arguments, "liveVerified": false,
                    "execution": "Handoff pause, readiness and identity, the device lease for the whole hold, two display reads that must agree, then ADCPerformLiveDigitizerReports on a thread of its own; the step returns once contact 0's first report was sent. Nothing is queried by this dry run."]) { _, new in new }
        return plan
    }

    private func mergedPlan(_ input: CoreDeviceInput, span: HoldSpan) throws -> [String: Any] {
        let segment = try HoldSegment(input)
        return ["backend": "coredevice-direct", "operation": input.operation, "operands": input.operands, "mergedIntoHold": true,
                "holdStep": span.step, "contactIDs": Array(1...segment.contactCount), "contactSlots": span.contactSlots,
                "frameCount": segment.frames.count, "durationMilliseconds": Int(segment.durationNanoseconds / 1_000_000),
                "execution": "A fresh display read that must match the hold's, then the step's frames sent in the hold's live stream beside contact 0, as contact ids \(Array(1...segment.contactCount).map(String.init).joined(separator: ", ")); no connection of its own. Nothing is queried by this dry run."]
    }

    private static func displayPlan(_ uuid: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", uuid,
            "--timeout", "15", "--json-output", "-", "--quiet"], jsonOutput: true)
    }

    /// One read-only display query; its failures sent nothing.
    private func holdDisplay(_ uuid: String) throws -> DirectTouchDisplay {
        do { return try DirectTouchDisplay(uiReadinessQuery(Self.displayPlan(uuid))) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
    }

    /// `hold`: the pause check, identity, the lease (kept until the hold
    /// ends), fresh display checks, then the stream on its own thread. Returns
    /// once contact 0's first report was sent.
    private func startHold(_ hold: HoldStep, span: HoldSpan, active: ActiveHold) throws -> HoldSession {
        try checkHandoffPause(.hold(hold))
        let input = CoreDeviceInput(device: hold.device, operation: HoldStep.operation, operands: [])
        let identity: (uuid: String, version: String)
        let lease: DeviceLease
        let display: DirectTouchDisplay
        do {
            let details = try readinessQuery(hold.device)
            identity = try DirectPhysicalInput.identity(input, query: { _ in details })
            lease = try leases.acquire(device: identity.uuid, operation: HoldStep.operation)
        } catch let failure as CommandFailure {
            throw failure.noInputSent()
        }
        do {
            display = try holdDisplay(identity.uuid)
            guard try holdDisplay(identity.uuid) == display else {
                throw CommandFailure(.preconditionChanged, "Display changed before the hold; no input sent.", inputSent: .none)
            }
            try Task.checkCancellation()
        } catch {
            lease.release()
            throw error
        }
        let point = display.portrait(hold.x, hold.y)
        let stream = HoldStream(slots: span.contactSlots, held: [point.0, point.1].map { Int((min(max($0, 0), 1) * 65535).rounded()) })
        let session = HoldSession(span: span, stream: stream, device: hold.device, uuid: identity.uuid, display: display, lease: lease)
        active.set(session)
        holdTransport.start(stream, uuid: identity.uuid, version: identity.version)
        guard let early = stream.waitUntilHolding() else { return session }
        // The stream ended before the contact was down: nothing is held.
        active.set(nil)
        let outcome = session.finish()
        let failure = early.failure ?? outcome.failure
            ?? CommandFailure(.internal, "The hold's stream ended before its first report; nothing is held.", inputSent: .none)
        DeviceQuarantine.note(failure, device: identity.uuid, operation: HoldStep.operation, leases: leases)
        throw failure
    }

    /// A touch step inside a hold: its frames go into the hold's stream as
    /// contacts after the held one; it opens no connection of its own.
    private func mergeIntoHold(_ input: CoreDeviceInput, session: HoldSession, step: Int) throws -> CommandOutput {
        try checkHandoffPause(.physicalInput(input))
        guard try holdDisplay(session.uuid) == session.display else {
            throw CommandFailure(.preconditionChanged, "Display changed during the hold; this step sent nothing, and the hold is released when the batch stops.", inputSent: .none)
        }
        let segment = try HoldSegment(input, display: session.display)
        try Task.checkCancellation()
        session.mergedSteps.append(step)
        if let ended = session.stream.perform(segment) {
            throw ended.failure ?? CommandFailure(.inputOutcomeUnknown, "The hold's stream ended while this step was sent; its effect is unknown.", inputSent: .possible)
        }
        return try json(["backend": "coredevice-direct", "operation": input.operation, "status": "dispatched", "verified": false,
            "releaseVerified": false, "device": input.device, "resolvedCoreDeviceUUID": session.uuid, "mergedIntoHold": true,
            "holdStep": session.span.step, "contactIDs": Array(1...segment.contactCount), "frameCount": segment.frames.count,
            "durationMilliseconds": Int(segment.durationNanoseconds / 1_000_000),
            "coordinateSpace": "normalized-current-interface", "displayRotationDegrees": session.display.rotation])
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
                if DirectAccessibilityAction.operations.contains(native.operation) {
                    let press = try DirectAccessibilityAction(native)
                    return try json(["backend": "coredevice-direct", "operation": press.operation, "selector": press.selector.json,
                        "identityArguments": identity.arguments, "liveVerified": false,
                        "execution": "Native AX: primary portrait display selection, two unique snapshots and live state/frame guards before one action. Press checks exact hit; scroll follows with fresh visibility/frame/hit and selection checks. No fallback or replay."])
                }
                if DirectAccessibilitySetValue.operations.contains(native.operation) {
                    let action = try DirectAccessibilitySetValue(native)
                    return try json(["backend": "coredevice-direct", "operation": action.operation,
                        "selector": action.guards.selector.json, "pid": action.guards.pid.map { $0 as Any } ?? NSNull(),
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
                if native.operation == "remote" { return try json(AppleTVRemote.plan(native)) }
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
            var leased: String?
            do {
                details = try readinessQuery(native.device)
                if Self.nativeObservations.contains(native.operation) {
                    lease = nil
                } else {
                    let resolved = try DirectPhysicalInput.identity(native, query: { _ in details ?? Data() })
                    lease = try leases.acquire(device: resolved.uuid, operation: native.operation)
                    leased = resolved.uuid
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
            // An input's receipt says whether the device was locked afterwards
            // (one read-only query; observations hold no lease and get none).
            let inputDevice = leased
            let lockQuery = uiReadinessQuery
            func sent(_ data: Data) -> CommandOutput {
                CommandOutput(data: inputDevice.map { DeviceUIReadiness.annotateInput(data, uuid: $0, query: lockQuery) } ?? data)
            }
            func appleTVPower(_ name: String, operation: String, details: Data) async throws -> CommandOutput {
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/power-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let power = CoreDeviceInput(device: native.device, operation: "remote", operands: [name])
                return try DirectPhysicalWake.output(await AppleTVPower.execute(power, details: details,
                    environment: AppleTVPower.live(power, details: details, directory: directory, query: query), operation: operation))
            }
            do {
            if native.operation == DirectPhysicalWake.operation {
                // An Apple TV has no side button: its wake is remote wake's.
                let details = try query(identity)
                if AppleTVRemote.deviceType(details) == "appleTV" {
                    return try await appleTVPower("wake", operation: DirectPhysicalWake.operation, details: details)
                }
                return try DirectPhysicalWake.output(DirectPhysicalWake.execute(native, query: { plan in
                    plan.executable == identity.executable && plan.arguments == identity.arguments ? details : try query(plan)
                }))
            }
            if AccessibilityWait.operations.contains(native.operation) {
                // A wait suspends between polls, so other calls to this
                // service can run then; each poll's requests still block it.
                return try AccessibilityWait.output(await DirectPhysicalAccessibility.executeNativeRSD(native, query: query))
            }
            if (["tree"] + DirectAccessibilityAction.operations + DirectAccessibilitySetValue.operations).contains(native.operation) {
                // A press on an Apple TV goes by the tool's own tunnel, then
                // by the Inspector's cursor, and is refused when neither can
                // take it: Apple's tunnel is not used for an Apple TV. Each
                // route passes to the next only what it has not pressed.
                if let details = try InspectorRoute.appleTVPress(native, query: query) {
                    let open = inspector
                    let data = try await InspectorRoute.pressInOrder(
                        ownTunnel: { try await DirectPhysicalAccessibility.executeNativeRSD(native, ownTunnelOnly: true, query: query) },
                        inspector: InspectorRoute.enabled ? { try InspectorRoute.press(native, details: details, open: open) } : nil)
                    return sent(data)
                }
                return sent(try await DirectPhysicalAccessibility.executeNativeRSD(native, query: query))
            }
            if native.operation == "key" {
                return sent(try DirectPhysicalKeyboard.execute(native, query: query))
            }
            if native.operation == "remote", AppleTVPower.handles(native.operands) {
                try AppleTVPower.validate(native.operands)
                return try await appleTVPower(native.operands[0], operation: "remote", details: try query(identity))
            }
            if native.operation == "remote" {
                return sent(try AppleTVRemote.execute(native, query: query))
            }
            if DirectPhysicalGesture.handles(native) {
                return sent(try DirectPhysicalGesture.execute(native, query: query))
            }
            if native.operation == "type" {
                return sent(try DirectPhysicalTyping.execute(native, query: query))
            }
            if native.operation == "paste" {
                return sent(try DirectPhysicalPaste.execute(native, query: query, copy: { plan, data in
                    try self.runner.run(plan.arguments, executable: plan.executable, timeout: 40, inputData: data)
                }))
            }
            if native.operation != "button" {
                return sent(try DirectPhysicalTouch.execute(native, query: query))
            }
            return sent(try DirectPhysicalInput.execute(native, query: query))
            } catch {
                // An input whose end is unknown quarantines the device.
                DeviceQuarantine.note(error, device: leased, operation: native.operation, leases: leases)
                throw error
            }
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
                    "additionalReadOnlyQueries": ["displays", "lockState", "screenshot (an external display only: an Apple TV refuses it while asleep)"],
                    "targetResolution": "Additional UI observations use the UUID resolved from fresh details; no queries are performed in dry run."] as [String: Any])
            }
            let details = try readinessQuery(device)
            var report = try DeviceReadiness.decode(details, device: device)
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/readiness-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let query = uiReadinessQuery
            report.ui = try DeviceUIReadiness.observe(details: details, device: device, query: query).observingSleep {
                try AppleTVPower.screenshot(device: device, to: directory.appendingPathComponent("sleep.png"), query: query)
            }
            return try report.output()
    }

    private func executeRecording(_ recording: RecordingCommand, dryRun: Bool) async throws -> CommandOutput {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/recording-\(UUID().uuidString)")
            if dryRun {
                if recording.native {
                    return try json(["execution": "in-process", "backend": "coredevice-videotoolbox",
                        "frameworks": ["AVConference", "VideoToolbox", "AVFoundation"], "destination": recording.destination.path,
                        "durationSeconds": recording.seconds, "codec": recording.codec, "audio": recording.audio,
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
                let data = try await recording.execute(directory: directory, runner: runner)
                // A partial recording is published, and still not a success.
                let partial = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String == "partial"
                return CommandOutput(data: data, exitCode: partial ? 1 : 0)
            } catch let failure as CommandFailure {
                throw failure.noInputSent()
            }
    }

    /// `frames`: the directory is checked before the device is contacted; the
    /// lease is held for the whole stream, as for a native recording.
    private func executeFrames(_ frames: FramesCommand) async throws -> CommandOutput {
        do {
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
        let leased: String
        let keyboard: LayoutDetection.Keyboard
        var setting: @Sendable () -> [String: Any]? = { nil }
        do {
            switch command.platform {
            case .physical:
                let details = try readinessQuery(command.device)
                let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: command.device, operation: "type", operands: []),
                                                                query: { _ in details })
                lease = try leases.acquire(device: identity.uuid, operation: "detect-layout")
                leased = identity.uuid
                keyboard = .physical(uuid: identity.uuid, version: identity.version)
            case .simulator:
                let booted = try SimulatorDevice.requireBooted(command.device, operation: "detect-layout", lookup: simulator.lookup)
                // Its probe is typed, and keyboard events do not reach watchOS:
                // on a watch simulator it changed the field and detected nothing.
                if booted.isAppleWatch { throw CommandFailure.unsupported(DigitalCrown.keyboardRefusal) }
                lease = try leases.acquire(device: command.device, operation: "detect-layout")
                leased = command.device
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
        detectionRoute = nil
        do {
            var result = try await LayoutDetection.run(command, probe: probe, operations: operations)
            // The route of the last accessibility request it made.
            if let detectionRoute { result["route"] = detectionRoute }
            return try json(result)
        } catch {
            // The probe is typed with real key events.
            DeviceQuarantine.note(error, device: leased, operation: "detect-layout", leases: leases)
            throw error
        }
    }

    private func detectionRead(_ command: LayoutDetectionCommand) async throws -> String {
        let tree = try await execute(.input(command.target, "tree", command.pid.map { [String($0)] } ?? []))
        if let route = DirectPhysicalAccessibility.route(of: tree.data) { detectionRoute = route }
        return try LayoutDetection.fieldValue(fromTree: tree.data, by: command.by, text: command.text, index: command.index)
    }

    private func detectionSet(_ command: LayoutDetectionCommand, _ value: String) async throws -> Bool {
        let receipt = try await execute(.input(command.target, command.setValueOperation, command.selectorOperands + [value] + command.indexOperands))
        if let route = DirectPhysicalAccessibility.route(of: receipt.data) { detectionRoute = route }
        let fields = try JSONSerialization.jsonObject(with: receipt.data) as? [String: Any]
        return fields?["valueMatches"] as? Bool == true
    }

    /// The route of the last accessibility request a layout detection made.
    private var detectionRoute: [String: Any]?

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
            }, build: { arguments, log in
                try runner.build(arguments, log: log, timeout: command.buildTimeoutSeconds.map(Double.init),
                                 progressInterval: BuildRunCommand.progressSeconds) { data, elapsed in
                    FileHandle.standardError.write(Data((BuildRunCommand.progressLine(log: data, elapsed: elapsed) + "\n").utf8))
                }
            }))
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
            do {
                return CommandOutput(data: try DirectSimulatorInput.execute(simulator, info: info, environment: self.simulator))
            } catch {
                DeviceQuarantine.note(error, device: simulator.device, operation: simulator.operation, leases: leases)
                throw error
            }
        }
        let data = try await DirectSimulatorAccessibility.execute(simulator, info: info, environment: self.simulator)
        return AccessibilityWait.operations.contains(simulator.operation) ? try AccessibilityWait.output(data) : CommandOutput(data: data)
    }

    /// Native AX reads: no device lease, and not paused by a pending handoff.
    static let nativeObservations = ["tree"] + AccessibilityWait.operations

    /// Device operations that only read: not paused by a pending handoff.
    static let observationOperations = ["readiness", "details", "apps", "processes", "screen", "screenshot", "files", "pull", "reports", "report", "clipboard", DeviceSettings.readOperation]
        + nativeObservations + AppDiagnosticsCommand.observations + ["displays", SimulatorHinge.angleOperation]

    /// `logs`, `console` and `last-crash` (docs/app-logs.md). The handoff
    /// pause has already applied to `console`; none of them takes a lease.
    private func executeDiagnostics(_ command: AppDiagnosticsCommand, dryRun: Bool) async throws -> CommandOutput {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        switch command {
        case .logs(let capture):
            if dryRun { return try json(capture.plan()) }
            if capture.physical {
                try preflight(capture.device, operation: "logs")
                let readinessQuery = self.readinessQuery
                return CommandOutput(data: try await PhysicalLogCapture.execute(capture,
                    environment: PhysicalLogCapture.live(device: capture.device, details: { try readinessQuery(capture.device) })))
            }
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

    /// A handoff that watches the device for its condition and ends when it
    /// is seen, at its deadline, or (at a terminal) when the person types an
    /// answer. Nobody has to answer. The condition is read first, so a step
    /// that is already done is not asked for. Reads only; the pause on the
    /// device's mutations holds for the whole watch.
    private func watchHandoff(_ handoff: HandoffCommand, until condition: HandoffCondition, terminal: Bool) async throws -> CommandOutput {
        let clock = ContinuousClock(), start = clock.now
        let deadline = start + .seconds(handoff.timeoutSeconds)
        let keyboard = terminal && isatty(STDIN_FILENO) != 0
        var polls = 0, asked = false
        var observation: [String: Any] = [:]
        func extra() -> [String: Any] {
            let elapsed = clock.now - start
            return ["until": condition.json, "observation": observation, "polls": polls, "alreadyMet": !asked,
                    "elapsedSeconds": (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18).rounded(),
                    "timeoutSeconds": handoff.timeoutSeconds]
        }
        while true {
            try Task.checkCancellation()
            polls += 1
            let (met, seen) = try await observeHandoff(condition, handoff)
            observation = seen
            if met { return try handoff.output(.observed, mechanism: "device-observation", extra: extra()) }
            if !asked {
                asked = true
                if terminal {
                    FileHandle.standardError.write(Data(("\u{7}Human action needed on \(handoff.platform) \(handoff.device):\n\(handoff.message)\n"
                        + "Watching the device for: \(condition.sentence). This ends by itself when that is seen, or after \(handoff.timeoutSeconds) s."
                        + (keyboard ? " You can also type 'done', 'decline' or 'cancel'." : "") + "\n").utf8))
                }
            }
            guard clock.now < deadline else { return try handoff.output(.timedOut, mechanism: "device-observation", extra: extra()) }
            if keyboard {
                // Listening for a typed answer between looks at the device.
                let answer = try TerminalHandoff.confirm(handoff, timeout: handoffWatchPause, prompt: { _ in })
                if answer != .timedOut { return try handoff.output(answer, mechanism: "terminal", extra: extra()) }
            } else {
                try await Task.sleep(for: handoffWatchPause)
            }
        }
    }

    /// One look at the device. A look that fails (asleep, unreachable, not
    /// portrait) is "not seen yet" with the reason, never an error: the
    /// person may be in the middle of the step.
    private func observeHandoff(_ condition: HandoffCondition, _ handoff: HandoffCommand) async throws -> (met: Bool, observation: [String: Any]) {
        do {
            switch condition {
            case .unlocked:
                let details = try readinessQuery(handoff.device)
                let ui = try DeviceUIReadiness.observe(details: details, device: handoff.device, query: uiReadinessQuery)
                return (ui.displayPower == "on" && ui.passcodeRequired == false,
                        ["displayPower": ui.displayPower, "passcodeRequired": ui.passcodeRequired.map { $0 as Any } ?? NSNull()])
            case .paired:
                let report = try readiness(handoff.device)
                return (report.connection == "connected" && report.pairing == "paired", ["connection": report.connection, "pairing": report.pairing])
            case .element(let operation, let operands, _, _, _, _):
                let target = Target(platform: handoff.platform == "physical" ? .physical : .simulator, identifier: handoff.device)
                let output = try await perform(.input(target, operation, operands), dryRun: false, allowInteractive: false, handoffConfirmation: nil)
                let result = try JSONSerialization.jsonObject(with: output.data) as? [String: Any] ?? [:]
                var observation = result["observation"] as? [String: Any] ?? [:]
                // The route of this look, on a physical device.
                if let route = DirectPhysicalAccessibility.route(of: output.data) { observation["route"] = route }
                return (result["conditionMet"] as? Bool == true, observation)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return (false, ["notObserved": String(String(describing: error).prefix(400))])
        }
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
