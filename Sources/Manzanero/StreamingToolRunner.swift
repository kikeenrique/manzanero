import Foundation
import Subprocess
import System

/// Scoped asynchronous output consumption. Subprocess owns pipe IO, process
/// termination, and reaping; no stream or execution handle escapes its closure.
struct StreamingToolRunner: Sendable {
    /// `clock` measures `timeout`; tests inject a manual clock so the deadline
    /// does not depend on how quickly a loaded machine schedules the child.
    func run<C: Clock>(executable: String, arguments: [String], timeout: Double, clock: C = ContinuousClock(),
                       maximumOutputBytes: Int = 1024 * 1024 * 1024,
                       receive: @Sendable @escaping (Data) async throws -> Void) async throws where C.Duration == Duration {
        try DeviceExecutablePolicy.validate(executable, arguments: arguments)
        guard timeout.isFinite, timeout > 0, maximumOutputBytes > 0 else {
            throw CommandFailure(.internal, "Invalid streaming process deadline or output limit.", inputSent: .none)
        }
        let deadline = clock.now.advanced(by: .seconds(timeout))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await clock.sleep(until: deadline, tolerance: nil)
                throw CommandFailure(.timeout, "Streaming process timed out; capture cleanup may be incomplete.", inputSent: .unknown)
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
                            throw CommandFailure(.toolFailed, "Streaming process exceeded the output byte limit.", inputSent: .unknown)
                        }
                        count += data.count
                        try await receive(data)
                    }
                }
                let diagnostics = result.standardError
                guard result.terminationStatus.isSuccess else {
                    throw CommandFailure(.toolFailed, "Streaming process failed (\(result.terminationStatus)): \(diagnostics)", inputSent: .unknown)
                }
                FileHandle.standardError.write(Data(diagnostics.utf8))
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
