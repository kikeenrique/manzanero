import Foundation

#if os(macOS)
/// Runs Manzanero with Foundation's `Process`: an executable URL and an argument array,
/// no shell. On timeout it sends SIGINT, which Manzanero turns into cancellation with an
/// attempted release, then SIGTERM if the process is still running 35 seconds later
/// (Manzanero's own cleanup deadline is 30 seconds).
public final class ProcessInvoker: ManzaneroInvoking {
    public init() {}

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        var value: Data { lock.withLock { data } }
    }

    public func invoke(executable: String, arguments: [String], timeout: Double) throws -> InvocationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let stdoutHandle = stdoutPipe.fileHandleForReading, stderrHandle = stderrPipe.fileHandleForReading
        let stdout = Capture(), stderr = Capture()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { stdout.set(stdoutHandle.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: readers) { stderr.set(stderrHandle.readDataToEndOfFile()) }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.interrupt()
            if exited.wait(timeout: .now() + 35) == .timedOut {
                process.terminate()
                exited.wait()
            }
        }
        readers.wait()
        return InvocationResult(exitCode: process.terminationStatus, stdout: stdout.value, stderr: stderr.value,
                                timedOut: timedOut)
    }
}
#endif

/// Paths relative to the current directory, as the mise task runs from the repository root.
public final class LocalFileSystem: RunnerFileSystem {
    public init() {}

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
}

public final class SystemClock: RunnerClock {
    public init() {}
    public func sleep(seconds: Double) { if seconds > 0 { Thread.sleep(forTimeInterval: seconds) } }
    public func now() -> Date { Date() }
    public func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
}
