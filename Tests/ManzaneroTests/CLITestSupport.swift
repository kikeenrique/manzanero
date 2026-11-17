import Foundation
@testable import Manzanero

/// The request the CLI's parser builds for a command line in its grammar,
/// such as `["tap", "--device", udid, "0.5", "0.5"]`. MCP command lines parse
/// the same way; the environment never supplies the target here.
func request(_ arguments: [String]) throws -> CommandRequest { try CLI.invocation(arguments).request }

/// The validated native physical input for a command line, or nil when the
/// command is not physical input, such as `["long-press", "--device", udid, "--", "0.5", "0.5", "8"]`.
func physicalInput(_ arguments: [String]) throws -> CoreDeviceInput? {
    if case .physicalInput(let input) = try request(arguments) { return input }
    return nil
}

/// The validated simulator input for a command line, or nil when the command
/// is not simulator input or accessibility.
func simulatorInput(_ arguments: [String]) throws -> SimulatorInput? {
    if case .simulatorInput(let input) = try request(arguments) { return input }
    return nil
}

/// A request rendered as platform, device, internal operation and operands,
/// such as `["physical", udid, "press-label", "7", "General"]`. Options are
/// rendered as `--name value` only when they differ from their defaults. A
/// wrapped `devicectl`/`simctl` tool keeps its operands only inside its planned
/// invocation, so it renders platform, device and operation only; compare
/// `DeviceOperation` values for its operands.
func summary(_ request: CommandRequest) -> [String] {
    func option(_ name: String, _ value: String?) -> [String] { value.map { [name, $0] } ?? [] }
    func flag(_ name: String, _ on: Bool) -> [String] { on ? [name] : [] }
    func platform(_ physical: Bool) -> String { physical ? "physical" : "simulator" }
    switch request {
    case .physicalInput(let input):
        return ["physical", input.device, input.operation] + input.operands
    case .simulatorInput(let input):
        return ["simulator", input.device, input.operation] + input.operands
    case .mediaStatus(let device):
        return ["physical", device, "media-status"]
    case .readiness(let device):
        return ["physical", device, "readiness"]
    case .handoff(let handoff):
        return [handoff.platform, handoff.device, "handoff", handoff.message]
            + (handoff.timeoutSeconds == 300 ? [] : [String(handoff.timeoutSeconds)])
    case .screen(let screen):
        return [screen.platform, screen.device, "screen"] + (screen.mode == .automatic ? [] : [screen.mode.rawValue])
    case .record(let recording):
        return [platform(recording.physical), recording.device, "record", recording.destination.relativePath,
                String(format: "%g", recording.seconds)]
            + (recording.codec == "h264" ? [] : [recording.codec]) + (recording.native ? ["--backend", "coredevice"] : [])
    case .frames(let frames):
        return ["physical", frames.device, "frames", frames.directory.relativePath]
            + option("--count", frames.count == (frames.seconds == nil ? FramesCommand.defaultCount : FramesCommand.maximumCount) ? nil : String(frames.count))
            + option("--seconds", frames.seconds.map { String(format: "%g", $0) })
            + option("--interval", frames.intervalMilliseconds == 0 ? nil : String(frames.intervalMilliseconds))
            + flag("--overwrite", frames.overwrite)
    case .detectLayout(let detection):
        return [detection.platform.rawValue, detection.device, "detect-layout", detection.by == "identifier" ? "--id" : "--label", detection.text]
            + option("--pid", detection.pid.map { String($0) })
    case .clearQuarantine(let target):
        return [target.platform.rawValue, target.identifier, DeviceQuarantine.operation]
    case .buildRun(let build):
        return [platform(build.physical), build.device, "build-run", build.project, build.scheme]
            + option("--configuration", build.configuration == "Debug" ? nil : build.configuration)
            + option("--app-target", build.appTarget)
            + flag(BuildRunCommand.provisioningUpdatesFlag, build.allowProvisioningUpdates)
            + flag(BuildRunCommand.deviceRegistrationFlag, build.allowDeviceRegistration)
    case .diagnostics(.logs(let logs)):
        let mode: [String] = switch logs.mode {
        case .stream(let seconds): ["--seconds", String(seconds)]
        case .last(let seconds): ["--last", String(seconds)]
        case .range(let start, let end): ["--start", DiagnosticTime.iso8601(start)] + option("--end", end.map { DiagnosticTime.iso8601($0) })
        }
        let target: [String] = switch logs.target {
        case .pid(let pid): ["--pid", String(pid)]
        case .bundle(let bundle): ["--bundle", bundle]
        case .process(let process): ["--process", process]
        }
        return ["simulator", logs.device, "logs"] + mode + target
            + option("--subsystem", logs.subsystem) + option("--category", logs.category)
            + option("--level", logs.level == .default ? nil : logs.level.rawValue)
            + option("--max-entries", logs.maxEntries == LogCapture.defaultMaxEntries ? nil : String(logs.maxEntries))
            + option("--max-bytes", logs.maxBytes == LogCapture.defaultMaxBytes ? nil : String(logs.maxBytes))
            + option("--output", logs.output)
    case .diagnostics(.console(let console)):
        return [platform(console.physical), console.device, "console", console.bundle, "--seconds", String(console.seconds)]
            + option("--max-bytes", console.maxBytes == ConsoleCapture.defaultMaxBytes ? nil : String(console.maxBytes))
            + flag("--os-log", console.osLog) + flag("--terminate", console.terminate)
            + (console.appArguments.isEmpty ? [] : ["--"] + console.appArguments)
    case .diagnostics(.lastCrash(let query)):
        return [platform(query.physical), query.device, "last-crash"]
            + option("--bundle", query.bundle) + option("--process", query.process)
            + option("--since", query.since.map { DiagnosticTime.iso8601($0) }) + option("--download", query.download)
    case .tool(let tool):
        return [tool.platform.rawValue, tool.device, tool.operation]
    case .simulatorDisplay(let display):
        return ["simulator", display.device, display.operation]
    case .decodeArchive(let path):
        return ["decode-ax-archive", path]
    case .ocr(let path):
        return ["ocr", path]
    case .devices(let simulators):
        return ["devices", simulators ? "simulators" : "physical"]
    case .doctor:
        return ["doctor"]
    case .keyboardLayouts:
        return ["keyboard-layouts"]
    }
}

/// The wrapped tool request an expected summary names, planned again from its
/// operands: `["physical", udid, "launch", "com.example.app"]`.
func toolRequest(_ expected: [String]) throws -> CommandRequest {
    let target = Target(platform: expected[0] == "physical" ? .physical : .simulator, identifier: expected[1])
    return .tool(try DeviceOperation(target, expected[2], Array(expected.dropFirst(3))))
}
