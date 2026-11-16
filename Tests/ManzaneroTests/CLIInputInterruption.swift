import Darwin
import Foundation
import Testing
@testable import Manzanero

struct CLIInputInterruptionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_CLI_INTERRUPT_DEVICE"] != nil), .timeLimit(.minutes(1)))
    func physicalHoldExitsAfterSignalWithoutSuccessReceipt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let device = try #require(environment["MANZANERO_CLI_INTERRUPT_DEVICE"])
        let operands = try #require(environment["MANZANERO_CLI_INTERRUPT_HOLD"]).split(separator: ",").map(String.init)
        let signalName = try #require(environment["MANZANERO_CLI_INTERRUPT_SIGNAL"])
        let signal = try #require(["SIGINT": SIGINT, "SIGTERM": SIGTERM][signalName])
        let args = ["long-press", "--device", device, "--"] + operands
        let native = try #require(try physicalInput(args))
        try #require((8...10).contains(try #require(Double(native.operands[2]))))
        _ = try DirectPhysicalInput.identity(native, query: { plan in
            try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
        })
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("tmp/cli-signal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdout = directory.appendingPathComponent("stdout.json"), stderr = directory.appendingPathComponent("stderr.log")
        for path in [stdout, stderr] {
            try #require(FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        }
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/manzanero")
        process.arguments = args
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let started = ContinuousClock.now
        try await Task.sleep(for: .seconds(2))
        try #require(process.isRunning, "CLI exited before the interruption; inspect \(stderr.path)")
        try #require(Darwin.kill(process.processIdentifier, signal) == 0)
        // Preserve the CLI's own cleanup grace even if the early-exit assertion
        // fails; a test observation timeout must not kill cleanup prematurely.
        let deadline = ContinuousClock.now + .seconds(35)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning, "CLI exceeded its cleanup grace; device release remains unknown")
        process.waitUntilExit()
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(8))
        #expect(process.terminationReason == .exit && process.terminationStatus == 128 + signal)
        #expect(try Data(contentsOf: stdout).isEmpty)
        let diagnostic = try String(contentsOf: stderr, encoding: .utf8)
        #expect(diagnostic.contains("Interrupted by \(signalName)") && !diagnostic.contains("forcing exit"))
        try JSONSerialization.data(withJSONObject: ["signal": signalName, "exitCode": process.terminationStatus,
            "elapsed": String(describing: elapsed), "plannedSeconds": operands[2], "deviceSideReleaseVerified": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
    }
}
