import Foundation

/// Result of one Manzanero invocation.
public struct InvocationResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// The runner interrupted the command after its deadline.
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs an executable with an argument array (never through a shell). Injected so
/// tests can answer with canned `tree` output, receipts and pulled logs.
public protocol ManzaneroInvoking: AnyObject {
    func invoke(executable: String, arguments: [String], timeout: Double) throws -> InvocationResult
}

/// The few file operations the runner needs, injected so tests stay in memory.
public protocol RunnerFileSystem: AnyObject {
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func createDirectory(_ path: String) throws
    func write(_ data: Data, to path: String) throws
    func read(_ path: String) throws -> Data
}

/// Waiting and host time. Host time only names the run directory and records
/// elapsed seconds; it is never compared with device timestamps.
public protocol RunnerClock: AnyObject {
    func sleep(seconds: Double)
    func now() -> Date
    /// Monotonic seconds for elapsed-time records.
    func uptime() -> Double
}

public struct RunnerError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Renders an argument array for display, single-quoting anything a shell would interpret.
public func shellQuoted(_ arguments: [String]) -> String {
    arguments.map { argument in
        let safe = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_./=:,+@%".unicodeScalars.contains($0)
        }
        return safe ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
