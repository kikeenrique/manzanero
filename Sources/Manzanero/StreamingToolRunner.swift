import Foundation
import Subprocess
import System

/// Scoped asynchronous output consumption. Subprocess owns pipe IO, process
/// termination, and reaping; no stream or execution handle escapes its closure.
struct StreamingToolRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: Double,
             maximumOutputBytes: Int = 1024 * 1024 * 1024,
             receive: @Sendable @escaping (Data) async throws -> Void) async throws {
        try DeviceExecutablePolicy.validate(executable, arguments: arguments)
        guard timeout.isFinite, timeout > 0, maximumOutputBytes > 0 else {
            throw CommandFailure(description: "Invalid streaming process deadline or output limit.")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CommandFailure(description: "Streaming process timed out; capture cleanup may be incomplete.")
            }
            group.addTask {
                var options = PlatformOptions()
                options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(1))]
                let result = try await Subprocess.run(
                    .path(FilePath(executable)), arguments: Arguments(arguments), platformOptions: options,
                    input: .none, output: .sequence, error: .string(limit: 65536)
                ) { execution in
                    var count = 0
                    for try await buffer in execution.standardOutput {
                        try Task.checkCancellation()
                        let data = buffer.withUnsafeBytes { Data($0) }
                        guard data.count <= maximumOutputBytes - count else {
                            throw CommandFailure(description: "Streaming process exceeded the output byte limit.")
                        }
                        count += data.count
                        try await receive(data)
                    }
                }
                let diagnostics = result.standardError
                guard result.terminationStatus.isSuccess else {
                    throw CommandFailure(description: "Streaming process failed (\(result.terminationStatus)): \(diagnostics)")
                }
                FileHandle.standardError.write(Data(diagnostics.utf8))
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
