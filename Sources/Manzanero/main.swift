import Foundation

// Help comes from the command definitions in CLI.swift and CLICommands.swift.
let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
var errorFormat = ErrorFormat.text
do {
    errorFormat = try ErrorFormat.scan(arguments, environment: environment)
    let invocation: CLIInvocation
    switch try CLI.parse(arguments, environment: environment) {
    case .output(let text):
        print(text)
        exit(0)
    case .serve:
        let result = try await CLIInputSignals.run(context: "MCP server") {
            try await AppleMCPServer.run()
            return CommandOutput(data: Data())
        }
        exit(result.exitCode)
    case .run(let parsed):
        invocation = parsed
    }
    errorFormat = try ErrorFormat.select(invocation.errorFormat, environment: environment)
    let request = invocation.request
    let result: CommandOutput
    if !invocation.dryRun, let context = request.signalContext {
        result = try await CLIInputSignals.run(context: context) {
            try await CommandService().execute(request, allowInteractive: true)
        }
    } else {
        result = try await CommandService().execute(request, dryRun: invocation.dryRun, allowInteractive: true)
    }
    if result.data.isEmpty, result.exitCode != 0 { exit(result.exitCode) }
    FileHandle.standardOutput.write(result.data)
    if result.data.last != 10 { print() }
    // Lines for a person, after the machine-readable output so that they
    // are the last thing a terminal shows.
    if let note = result.note { FileHandle.standardError.write(Data((note + "\n").utf8)) }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(errorFormat.render(error))
    exit(CommandFailure.exitCode(for: error))
}
