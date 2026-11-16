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
    let commandArgs = invocation.arguments
    let dryRun = invocation.dryRun
    let result: CommandOutput
    if CLIInputSignals.applies(to: commandArgs, dryRun: dryRun) {
        result = try await CLIInputSignals.run(context: CLIInputSignals.context(for: commandArgs)) {
            try await CommandService().execute(commandArgs, allowInteractive: true)
        }
    } else {
        result = try await CommandService().execute(commandArgs, dryRun: dryRun, allowInteractive: true)
    }
    if result.data.isEmpty, result.exitCode != 0 { exit(result.exitCode) }
    FileHandle.standardOutput.write(result.data)
    if result.data.last != 10 { print() }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(errorFormat.render(error))
    exit(CommandFailure.exitCode(for: error))
}
