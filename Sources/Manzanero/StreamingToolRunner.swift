import Foundation
import Subprocess
import Synchronization
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

    /// Which of the child's streams a captured chunk came from.
    enum CaptureStream: Sendable, Equatable { case output, error }

    /// How a finite capture ended. Only `hardDeadline` expiry is an error;
    /// every other ending is returned so the caller can judge the status.
    enum CaptureEnd: Sendable, Equatable {
        /// The child exited (or was signalled) by itself before any soft stop.
        case exited(TerminationStatus)
        /// The soft deadline passed and the stop signal was sent; the child
        /// then ended with this status.
        case softDeadline(TerminationStatus)
        /// The consumer asked to stop (a bound was reached); the child was
        /// torn down (SIGTERM, then SIGKILL after one second).
        case consumerStopped
    }

    private struct ConsumerStop: Error {}

    /// A bounded capture where reaching a limit is a normal ending, not a
    /// failure. Both streams are delivered to `receive` as they arrive;
    /// returning `false` stops the capture and tears the child down.
    /// `softDeadline` (seconds from start) sends `softSignal` once and keeps
    /// reading until the child exits; `hardDeadline` stops and reaps the child
    /// and throws `timeout`. `environment` overlays the inherited environment.
    func capture<C: Clock>(executable: String, arguments: [String], environment: [String: String] = [:],
                           softDeadline: Double? = nil, softSignal: Int32 = SIGINT, hardDeadline: Double,
                           clock: C = ContinuousClock(),
                           receive: @Sendable @escaping (CaptureStream, Data) async throws -> Bool) async throws -> CaptureEnd where C.Duration == Duration {
        try DeviceExecutablePolicy.validate(executable, arguments: arguments)
        guard hardDeadline.isFinite, hardDeadline > 0,
              softDeadline.map({ $0.isFinite && $0 > 0 && $0 < hardDeadline }) ?? true else {
            throw CommandFailure(.internal, "Invalid capture deadlines.", inputSent: .none)
        }
        var overlay: [Environment.Key: String?] = [:]
        for (key, value) in environment {
            guard let key = Environment.Key(rawValue: key) else {
                throw CommandFailure(.internal, "Invalid environment variable name.", inputSent: .none)
            }
            overlay[key] = value
        }
        let processEnvironment: Environment = overlay.isEmpty ? .inherit : .inherit.updating(overlay)
        let start = clock.now
        let hard = start.advanced(by: .seconds(hardDeadline))
        let soft = softDeadline.map { start.advanced(by: .seconds($0)) }
        let softFired = Mutex(false)
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return try await withThrowingTaskGroup(of: CaptureEnd.self) { group in
            group.addTask {
                try await clock.sleep(until: hard, tolerance: nil)
                throw CommandFailure(.timeout, "\(name) did not finish within its \(Int(hardDeadline))-second hard deadline; it was stopped and reaped.", inputSent: .unknown)
            }
            group.addTask {
                var options = PlatformOptions()
                options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(1))]
                do {
                    let result = try await Subprocess.run(
                        .path(FilePath(executable)), arguments: Arguments(arguments), environment: processEnvironment,
                        platformOptions: options, input: .none, output: .sequence, error: .sequence
                    ) { execution in
                        try await withThrowingTaskGroup(of: Bool.self) { readers in
                            readers.addTask {
                                for try await buffer in execution.standardOutput {
                                    try Task.checkCancellation()
                                    guard try await receive(.output, buffer.withUnsafeBytes { Data($0) }) else { throw ConsumerStop() }
                                }
                                return true
                            }
                            readers.addTask {
                                for try await buffer in execution.standardError {
                                    try Task.checkCancellation()
                                    guard try await receive(.error, buffer.withUnsafeBytes { Data($0) }) else { throw ConsumerStop() }
                                }
                                return true
                            }
                            if let soft {
                                readers.addTask {
                                    do { try await clock.sleep(until: soft, tolerance: nil) } catch { return false }
                                    softFired.withLock { $0 = true }
                                    try? execution.send(signal: Signal(rawValue: softSignal))
                                    return false
                                }
                            }
                            var finishedReaders = 0
                            while let isReader = try await readers.next() {
                                if isReader { finishedReaders += 1 }
                                if finishedReaders == 2 { break }
                            }
                            readers.cancelAll()
                        }
                    }
                    return softFired.withLock { $0 } ? .softDeadline(result.terminationStatus) : .exited(result.terminationStatus)
                } catch is ConsumerStop {
                    return .consumerStopped
                }
            }
            defer { group.cancelAll() }
            guard let end = try await group.next() else {
                throw CommandFailure(.internal, "Capture ended without a result.", inputSent: .none)
            }
            return end
        }
    }
}
