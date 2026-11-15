import Foundation
import ProbeAnalysis
import ProbeTouchRunner

// Front end for the touch measurement runner. See docs/probe-touch-runner.md.
// stdout: the dry-run plan or the run summary; stderr: progress and errors.

func writeError(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

do {
    switch try RunnerArguments.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(RunnerArguments.usage)
    case .printPlan:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(TouchPlan.builtIn))
        print()
    case .compare(let directory):
        let outcome = TouchRunner.compare(directory: directory, fileSystem: LocalFileSystem())
        FileHandle.standardOutput.write(Data(outcome.output.utf8))
        exit(outcome.exitCode)
    case .run(let options):
        let runner = TouchRunner(options: options, invoker: ProcessInvoker(), fileSystem: LocalFileSystem(),
                                 clock: SystemClock(), progress: { writeError($0 + "\n") })
        let outcome = runner.execute()
        FileHandle.standardOutput.write(Data(outcome.output.utf8))
        exit(outcome.exitCode)
    }
} catch {
    writeError("probe-touch: \(error)\n\(RunnerArguments.usage)\n")
    exit(TouchRunner.exitUsage)
}
