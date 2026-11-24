import Foundation

/// One operation, typed: what a parsed command line asks the command service
/// to run. Each case wraps the operation's own validated type, so building a
/// request is where operands are checked, before any device is contacted.
enum CommandRequest: Sendable, Equatable {
    /// Physical input and accessibility in process (`DirectPhysical*`).
    case physicalInput(CoreDeviceInput)
    /// Simulator input and accessibility in process (`DirectSimulator*`).
    case simulatorInput(SimulatorInput)
    case mediaStatus(device: String)
    case readiness(device: String)
    case handoff(HandoffCommand)
    case screen(ScreenCommand)
    case record(RecordingCommand)
    /// `frames`: native video frames saved as JPEG files (physical).
    case frames(FramesCommand)
    /// `detect-layout`: a probe typed into a named field and read back.
    case detectLayout(LayoutDetectionCommand)
    /// `clear-quarantine`: remove this Mac's mark that an earlier input may
    /// have left something held on the device. Sends the device nothing.
    case clearQuarantine(Target)
    /// `pair`: a pairing of the tool's own with a physical device.
    case pair(PairCommand)
    case buildRun(BuildRunCommand)
    case diagnostics(AppDiagnosticsCommand)
    /// A `devicectl` or `simctl` wrapper.
    case tool(DeviceOperation)
    /// Simulator `displays` and `screenshot` with a display choice.
    case simulatorDisplay(SimulatorDisplayRequest)
    case decodeArchive(path: String)
    case ocr(path: String)
    case devices(simulators: Bool)
    /// `create-simulator`: `simctl create`, addressing no device yet.
    case createSimulator(name: String, type: String, runtime: String?)
    case doctor
    /// The keyboard layouts `type` accepts, read from this Mac.
    case keyboardLayouts
    /// `batch`: several commands for one device, in order.
    case batch(BatchCommand)
    /// `hold <x> <y>`: a batch step that keeps one contact down (`HoldStep`).
    case hold(HoldStep)
    /// `release`: the batch step that lifts the hold before it.
    case release(Target)
    /// `remote <button> --report-focus`: the press, then a fresh tree whose
    /// focused node goes into the press's receipt (`RemoteFocusReport`).
    indirect case reportingFocus(press: CommandRequest, tree: CommandRequest)
    /// `scrub --to <time>`: Apple's player moved to a time (`PlayerScrub`).
    case scrub(ScrubCommand)
}

/// A wrapped Apple tool invocation and the operation it implements.
struct DeviceOperation: Sendable, Equatable {
    let platform: Target.Platform
    let device: String
    /// The operation's internal name; app-data and report operations keep
    /// `files`, `pull`, `push`, `reports` and `report`.
    let operation: String
    let command: DeviceCommand
    /// Physical `terminate <bundle>`: the bundle whose one running process
    /// is resolved just before the terminate runs.
    private(set) var bundleToResolve: String?

    init(_ target: Target, _ operation: String, _ operands: [String] = []) throws {
        platform = target.platform
        device = target.identifier
        self.operation = operation
        command = try DeviceCommand.plan(physical: target.platform == .physical, device: target.identifier, operation: operation, operands: operands)
        if command.arguments.contains(DeviceCommand.resolvedPIDPlaceholder) { bundleToResolve = operands.first }
    }

    /// `launch` with arguments, environment, language, locale or a relaunch.
    init(_ target: Target, launch bundle: String, options: LaunchOptions) throws {
        platform = target.platform
        device = target.identifier
        operation = "launch"
        command = try DeviceCommand.launch(physical: target.platform == .physical, device: target.identifier, bundle: bundle, options: options)
    }


    /// devicectl operations that first check Developer Mode.
    var needsPreflight: Bool {
        platform == .physical && (["launch", "terminate", "processes", "open-url", "screenshot"] + DeviceSettings.operations).contains(operation)
    }
}

extension CommandRequest {
    /// Input or accessibility on either platform; `operation` is the internal
    /// name (`press-id`, `wait-label`, `set-value-id` and so on).
    static func input(_ target: Target, _ operation: String, _ operands: [String] = []) throws -> Self {
        switch target.platform {
        case .physical: .physicalInput(try CoreDeviceInput.validated(device: target.identifier, operation: operation, operands: operands))
        case .simulator: .simulatorInput(try SimulatorInput(device: target.identifier, operation: operation, operands: operands))
        }
    }

    /// The device a request addresses: platform, identifier and operation, as
    /// the handoff pause and the read-only rule see it.
    var addressed: (platform: String, device: String, operation: String)? {
        switch self {
        case .physicalInput(let input): ("physical", input.device, input.operation)
        case .simulatorInput(let input): ("simulator", input.device, input.operation)
        case .mediaStatus(let device): ("physical", device, "media-status")
        case .readiness(let device): ("physical", device, "readiness")
        case .handoff(let handoff): (handoff.platform, handoff.device, "handoff")
        case .screen(let screen): (screen.platform, screen.device, "screen")
        case .record(let recording): (recording.physical ? "physical" : "simulator", recording.device, "record")
        case .frames(let frames): ("physical", frames.device, "frames")
        case .detectLayout(let detection): (detection.platform.rawValue, detection.device, "detect-layout")
        case .clearQuarantine(let target): (target.platform.rawValue, target.identifier, DeviceQuarantine.operation)
        case .pair(let pair): ("physical", pair.device, PairCommand.operation)
        case .buildRun(let build): (build.physical ? "physical" : "simulator", build.device, "build-run")
        case .diagnostics(let diagnostics): (diagnostics.physical ? "physical" : "simulator", diagnostics.device, diagnostics.operation)
        case .tool(let tool): (tool.platform.rawValue, tool.device, tool.operation)
        case .simulatorDisplay(let display): ("simulator", display.device, display.operation)
        case .batch(let batch): (batch.target.platform.rawValue, batch.target.identifier, "batch")
        case .hold(let hold): (hold.simulator ? "simulator" : "physical", hold.device, HoldStep.operation)
        case .release(let target): (target.platform.rawValue, target.identifier, HoldStep.releaseOperation)
        case .reportingFocus(let press, _): press.addressed
        case .scrub(let scrub): (scrub.target.platform.rawValue, scrub.target.identifier, ScrubCommand.operation)
        case .decodeArchive, .ocr, .devices, .createSimulator, .doctor, .keyboardLayouts: nil
        }
    }

    /// Commands that only read from the device (or touch no device at all).
    /// Their failures cannot have sent input. Any other command is not
    /// assumed read-only.
    var isReadOnly: Bool {
        // A batch is read-only only when every step is.
        if case .batch(let batch) = self { return batch.requests.allSatisfy(\.isReadOnly) }
        guard let addressed else { return true }
        return (CommandService.observationOperations + ["media-status", DeviceQuarantine.operation]).contains(addressed.operation)
    }

    /// Operations that own a child process, send input or (`frames`) save
    /// work as they go run under the CLI's signal scope (`CLIInputSignals`):
    /// SIGINT/SIGTERM cancel them and wait for cleanup. The value names what
    /// is stopped in the diagnostic.
    var signalContext: String? {
        switch self {
        case .diagnostics(.logs), .diagnostics(.console): "app output capture"
        case .simulatorInput: "simulator input"
        case .hold(let hold) where hold.simulator: "simulator input"
        case .physicalInput, .hold, .release: "physical input"
        case .frames: "frame capture"
        // The in-process recording owns a stream on the device. Outside the
        // scope an interrupt ended the process at once and left the stream
        // running (the Apple TV 4K, 2026-11-21); inside it the loop stops
        // its own stream and releases the tunnel, as `frames` does.
        case .record(let recording) where recording.physical && recording.native: "native recording"
        case .detectLayout: "layout detection"
        case .batch(let batch): batch.requests.contains { $0.signalContext != nil } ? "batch" : nil
        case .reportingFocus(let press, _): press.signalContext
        case .scrub(let scrub): scrub.target.platform == .simulator ? "simulator input" : "physical input"
        default: nil
        }
    }

    /// A touch step's input, on either platform, which a hold takes into its
    /// stream (`HoldSegment.handles`); nil for any other step.
    var holdTouch: CoreDeviceInput? {
        switch self {
        case .physicalInput(let input) where HoldSegment.handles(input): input
        case .simulatorInput(let input) where HoldSegment.handles(input.coreDeviceInput): input.coreDeviceInput
        default: nil
        }
    }

    /// The accessibility tree of the foreground application, as `screen` reads it.
    static func tree(platform: String, device: String) throws -> Self {
        try input(Target(platform: platform == "simulator" ? .simulator : .physical, identifier: device), "tree")
    }
}
