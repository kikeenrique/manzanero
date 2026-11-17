import ArgumentParser
import Foundation

/// The command line: `manzanero <operation> [operands] [--device <UDID> | --simulator <UUID>]`.
///
/// Swift Argument Parser parses the arguments into one `CLICommand`; the
/// library's `main()` is never called, so the exit path, the JSON error format
/// and signal handling stay in `main.swift`. MCP tools build the same argument
/// arrays and parse them here too, so the two front ends cannot drift.
enum CLI {
    /// What a parsed command line asks for.
    enum Parsed {
        /// Help, version or a completion script: print it on stdout and exit 0.
        case output(String)
        /// `manzanero mcp`.
        case serve
        /// An operation for the command service.
        case run(CLIInvocation)
    }

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Parsed {
        var command: any ParsableCommand
        do {
            command = try ManzaneroCLI.parseAsRoot(arguments)
        } catch {
            return try outcome(of: error)
        }
        if let serve = command as? ManzaneroCLI.MCPServe {
            guard !serve.common.dryRun else { throw CommandFailure.usage(noPlanMessage) }
            return .serve
        }
        guard let operation = command as? any CLICommand else {
            // The root or a group without a subcommand, or the help command:
            // each one's run() throws the help request.
            do { try command.run() } catch { return try outcome(of: error) }
            return .output("")
        }
        return .run(CLIInvocation(request: try operation.request(environment: environment),
                                  dryRun: operation.common.dryRun, errorFormat: operation.common.errorFormat))
    }

    /// An MCP tool's argument array, parsed exactly as the CLI parses it.
    /// The environment does not supply a target: tools always name one.
    static func invocation(_ arguments: [String]) throws -> CLIInvocation {
        guard case .run(let invocation) = try parse(arguments, environment: [:]) else {
            throw CommandFailure(.internal, "The tool's arguments did not name an operation.", inputSent: .none)
        }
        return invocation
    }

    /// The library's clean exits (help, version, completion scripts) and its
    /// parse and validation errors, which become `usage` failures.
    private static func outcome(of error: any Error) throws -> Parsed {
        let full = String(ManzaneroCLI.fullMessage(for: error).trimmingSuffix(while: \.isNewline))
        if ManzaneroCLI.exitCode(for: error) == .success { return .output(full) }
        throw CommandFailure.usage(ManzaneroCLI.message(for: error), text: full)
    }

    static let noPlanMessage = "--dry-run requires a physical or simulator command."
}

private extension String {
    func trimmingSuffix(while predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return self[..<end]
    }
}

/// One parsed operation and the options that shape how it runs.
struct CLIInvocation: Sendable, Equatable {
    let request: CommandRequest
    let dryRun: Bool
    let errorFormat: ErrorFormat?
}

/// `--dry-run` and `--error-format`, accepted by every command in any position.
struct CommonOptions: ParsableArguments {
    @Flag(help: "Print the planned invocation as JSON without contacting a device.")
    var dryRun = false

    @Option(help: ArgumentHelp("How a failure is printed on stderr (default: $\(ErrorFormat.environmentVariable), else text).",
                               valueName: "text|json"))
    var errorFormat: ErrorFormat?
}

extension ErrorFormat: ExpressibleByArgument {}

/// Where a command runs: exactly one physical device or simulator.
struct Target: Sendable, Equatable {
    enum Platform: String, Sendable { case physical, simulator }
    let platform: Platform
    let identifier: String

    static let deviceVariable = "MANZANERO_DEVICE"
    static let simulatorVariable = "MANZANERO_SIMULATOR"
}

struct TargetOptions: ParsableArguments {
    @Option(help: ArgumentHelp("A physical device: CoreDevice UUID, hardware UDID or name (default: $\(Target.deviceVariable)).",
                               valueName: "UDID"))
    var device: String?

    @Option(help: ArgumentHelp("A simulator, by UUID (default: $\(Target.simulatorVariable)).", valueName: "UUID"))
    var simulator: String?

    /// An explicit option wins; otherwise exactly one environment variable.
    func resolve(_ environment: [String: String]) throws -> Target {
        switch (device, simulator) {
        case (let device?, nil): return Target(platform: .physical, identifier: device)
        case (nil, let simulator?): return Target(platform: .simulator, identifier: simulator)
        case (.some, .some): throw CommandFailure.usage("Give exactly one of --device or --simulator.")
        case (nil, nil): break
        }
        let device = environment[Target.deviceVariable].flatMap { $0.isEmpty ? nil : $0 }
        let simulator = environment[Target.simulatorVariable].flatMap { $0.isEmpty ? nil : $0 }
        switch (device, simulator) {
        case (let device?, nil): return Target(platform: .physical, identifier: device)
        case (nil, let simulator?): return Target(platform: .simulator, identifier: simulator)
        case (.some, .some):
            throw CommandFailure.usage("Both \(Target.deviceVariable) and \(Target.simulatorVariable) are set; pass --device or --simulator to choose one.")
        case (nil, nil):
            throw CommandFailure.usage("Name a target: --device <UDID> or --simulator <UUID> (or set \(Target.deviceVariable) or \(Target.simulatorVariable)).")
        }
    }
}

/// An exact accessibility selector: `--id` or `--label`, and an optional PID.
struct SelectorOptions: ParsableArguments {
    @Option(parsing: .unconditional, help: ArgumentHelp("Exact, case-sensitive accessibility identifier.", valueName: "identifier"))
    var id: String?

    @Option(parsing: .unconditional, help: ArgumentHelp("Exact, case-sensitive accessibility label.", valueName: "label"))
    var label: String?

    @Option(help: ArgumentHelp("Positive PID of the application to inspect (default: the foreground application).", valueName: "pid"))
    var pid: String?

    @Option(help: ArgumentHelp("Choose among several matching elements by position, counted from 1 in the tree's node order (the order an ambiguous-selector failure lists them). Positional: check the tree first.", valueName: "position"))
    var index: String?

    func validate() throws {
        guard (id == nil) != (label == nil) else { throw ValidationError("Give exactly one of --id or --label.") }
    }
}

/// A parsed operation.
protocol CLICommand: ParsableCommand {
    var common: CommonOptions { get }
    /// The validated request `CommandService.execute` runs.
    func request(environment: [String: String]) throws -> CommandRequest
}

/// An operation on one device or simulator.
protocol TargetedCommand: CLICommand {
    var target: TargetOptions { get }
    func request(_ target: Target) throws -> CommandRequest
}

extension TargetedCommand {
    func request(environment: [String: String]) throws -> CommandRequest {
        try request(target.resolve(environment))
    }
}

extension SelectorOptions {
    /// The internal name of a selector operation: `press-id`, `wait-label`, …
    func operation(_ base: String) -> String { "\(base)-\(id != nil ? "id" : "label")" }

    /// `[pid] <text>`, the operands the selector operations validate.
    var operands: [String] { (pid.map { [$0] } ?? []) + [id ?? label ?? ""] }

    /// `--index <n>` when given; it follows every positional operand.
    var indexOperands: [String] { index.map { [AccessibilitySelector.indexOption, $0] } ?? [] }
}

struct ManzaneroCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manzanero",
        abstract: "Apple device tools for terminals and agents.",
        discussion: """
        Every device command takes exactly one target, --device <UDID> for a physical device or \
        --simulator <UUID> for a booted simulator; MANZANERO_DEVICE or MANZANERO_SIMULATOR supplies \
        it when neither option is given. Coordinates are normalized 0...1 from the top left of the \
        current interface. A receipt reports what was sent, not what the app did: inspect afterward.

        Exit status: 0 success, 1 failure, 64 usage error, 124 wait timeout, 130/143 interrupted. \
        --error-format json (or MANZANERO_ERROR_FORMAT=json) prints a failure as one JSON object on \
        stderr. See docs/errors.md.
        """,
        version: "manzanero \(manzaneroVersion)",
        groupedSubcommands: [
            CommandGroup(name: "Touch and keys", subcommands: [
                Tap.self, LongPress.self, Swipe.self, Drag.self, Pinch.self, MultiTap.self, MultiDrag.self,
                Gesture.self, Button.self, Key.self, TypeText.self, DetectLayout.self, Paste.self, Wake.self, Remote.self, Crown.self,
                Fold.self, Unfold.self, Hinge.self]),
            CommandGroup(name: "Accessibility", subcommands: [Tree.self, Press.self, Scroll.self, Wait.self, SetValue.self]),
            CommandGroup(name: "Screen", subcommands: [Screenshot.self, Screen.self, Record.self, Frames.self, Displays.self]),
            CommandGroup(name: "Apps and files", subcommands: [
                Apps.self, Launch.self, Terminate.self, Install.self, Uninstall.self, OpenURL.self,
                Files.self, Reports.self, BuildRun.self]),
            CommandGroup(name: "Diagnostics", subcommands: [Logs.self, Console.self, LastCrash.self]),
            CommandGroup(name: "Device state", subcommands: [
                Devices.self, Details.self, Processes.self, Readiness.self, MediaStatus.self, Boot.self, Shutdown.self, Handoff.self, ClearQuarantine.self]),
            CommandGroup(name: "Host", subcommands: [Doctor.self, KeyboardLayouts.self, OCR.self, DecodeAXArchive.self, MCPServe.self]),
        ])

    @OptionGroup var common: CommonOptions
}
