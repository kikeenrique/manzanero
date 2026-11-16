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
    case buildRun(BuildRunCommand)
    case diagnostics(AppDiagnosticsCommand)
    /// A `devicectl` or `simctl` wrapper.
    case tool(DeviceOperation)
    case decodeArchive(path: String)
    case ocr(path: String)
    case devices(simulators: Bool)
    case doctor
    /// The keyboard layouts `type` accepts, read from this Mac.
    case keyboardLayouts
}

/// A wrapped Apple tool invocation and the operation it implements.
struct DeviceOperation: Sendable, Equatable {
    let platform: Target.Platform
    let device: String
    /// The operation's internal name; app-data and report operations keep
    /// `files`, `pull`, `push`, `reports` and `report`.
    let operation: String
    let command: DeviceCommand

    init(_ target: Target, _ operation: String, _ operands: [String] = []) throws {
        platform = target.platform
        device = target.identifier
        self.operation = operation
        command = try DeviceCommand.plan(physical: target.platform == .physical, device: target.identifier, operation: operation, operands: operands)
    }

    /// devicectl operations that first check Developer Mode.
    var needsPreflight: Bool {
        platform == .physical && ["launch", "terminate", "processes", "open-url", "screenshot"].contains(operation)
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
        case .buildRun(let build): (build.physical ? "physical" : "simulator", build.device, "build-run")
        case .diagnostics(let diagnostics): (diagnostics.physical ? "physical" : "simulator", diagnostics.device, diagnostics.operation)
        case .tool(let tool): (tool.platform.rawValue, tool.device, tool.operation)
        case .decodeArchive, .ocr, .devices, .doctor, .keyboardLayouts: nil
        }
    }

    /// Commands that only read from the device (or touch no device at all).
    /// Their failures cannot have sent input. Any other command is not
    /// assumed read-only.
    var isReadOnly: Bool {
        guard let addressed else { return true }
        return (CommandService.observationOperations + ["media-status"]).contains(addressed.operation)
    }

    /// Operations that own a child process or send input run under the CLI's
    /// signal scope (`CLIInputSignals`): SIGINT/SIGTERM cancel them and wait
    /// for cleanup. The value names what is stopped in the diagnostic.
    var signalContext: String? {
        switch self {
        case .diagnostics(.logs), .diagnostics(.console): "app output capture"
        case .simulatorInput: "simulator input"
        case .physicalInput: "physical input"
        default: nil
        }
    }

    /// The accessibility tree of the foreground application, as `screen` reads it.
    static func tree(platform: String, device: String) throws -> Self {
        try input(Target(platform: platform == "simulator" ? .simulator : .physical, identifier: device), "tree")
    }
}
