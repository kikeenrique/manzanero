import Foundation
import Darwin

/// Uses argument arrays and file-backed output so child processes cannot fill a pipe.
struct ToolRunner: Sendable {
    struct RecordingTiming {
        let seconds: Double
        var startupSeconds: Double = 30
        var finalizationSeconds: Double = 30
    }

    func recordSimulator(_ arguments: [String], timing: RecordingTiming, executable: String = "/usr/bin/xcrun") throws {
        let result = try capture(arguments, executable: executable, recording: timing)
        FileHandle.standardError.write(result.output)
        FileHandle.standardError.write(result.errors)
        guard result.status == 0 else {
            throw CommandFailure(.toolFailed, "Simulator recorder failed (\(result.status)): \(String(decoding: result.errors, as: UTF8.self))", inputSent: .none)
        }
    }
    /// `environment` overlays the inherited environment, for example the
    /// `SIMCTL_CHILD_`/`DEVICECTL_CHILD_` variables Apple's tools pass to an app.
    func run(_ arguments: [String], executable: String = "/usr/bin/xcrun", timeout: Double? = nil, inputData: Data? = nil,
             environment: [String: String] = [:]) throws -> Data {
        let result = try capture(arguments, executable: executable, inputData: inputData, timeout: timeout, environment: environment)
        guard result.status == 0 else {
            let errors = String(decoding: result.errors, as: UTF8.self)
            if let locked = CommandFailure.lockedDevice(errors) { throw locked }
            // The tool ran; whether it changed the device depends on the
            // invocation, which only the caller knows.
            throw CommandFailure(.toolFailed, "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): \(String(decoding: result.errors, as: UTF8.self))", inputSent: .unknown)
        }
        FileHandle.standardError.write(result.errors)
        return result.output
    }

    /// Both Xcode output streams go through xcsift; retain the raw log on failure too.
    /// `timeout` stops the build at its deadline, keeping the log so far;
    /// `progress` is handed the log so far every `progressInterval` seconds.
    func build(_ arguments: [String], log: URL, executable: String = "/usr/bin/xcrun", timeout: Double? = nil,
               progressInterval: Double = 10, progress: ((Data, Double) -> Void)? = nil) throws {
        _ = try run(["xcsift", "--version"], executable: "/usr/bin/env")
        let result: (status: Int32, output: Data, errors: Data)
        do {
            result = try capture(arguments, executable: executable, merged: true, timeout: timeout,
                                 watch: progress.map { report in (progressInterval, { stdout, elapsed in
                                     if let data = try? Data(contentsOf: stdout) { report(data, elapsed) }
                                 }) }, keepOutput: log)
        } catch let failure as CommandFailure where failure.code == .timeout {
            // A build runs on the Mac; the device is untouched until install.
            throw CommandFailure(.timeout, "Xcode build did not finish within \(Int(timeout ?? 0)) s and was stopped; raw build log so far: \(log.path)", inputSent: .none)
        }
        try result.output.write(to: log)
        let formatted = try capture(["xcsift", "-f", "toon"], executable: "/usr/bin/env", input: log)
        FileHandle.standardError.write(formatted.output)
        FileHandle.standardError.write(formatted.errors)
        guard formatted.status == 0 else {
            throw CommandFailure(.toolFailed, "xcsift failed (\(formatted.status)); raw build log: \(log.path)", inputSent: .none)
        }
        guard result.status == 0 else {
            // A build runs on the Mac; the device is untouched until install.
            throw CommandFailure(.toolFailed, "Xcode build failed (\(result.status)); raw build log: \(log.path)", inputSent: .none)
        }
    }

    private func capture(_ arguments: [String], executable: String,
                         merged: Bool = false, input: URL? = nil, inputData: Data? = nil,
                         recording: RecordingTiming? = nil, timeout: Double? = nil,
                         environment: [String: String] = [:],
                         watch: (interval: Double, report: (URL, Double) -> Void)? = nil,
                         keepOutput: URL? = nil) throws -> (status: Int32, output: Data, errors: Data) {
        try DeviceExecutablePolicy.validate(executable, arguments: arguments)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        var inputURL = input
        if let inputData {
            guard input == nil else { throw CommandFailure(.internal, "Process input cannot combine data and a file.", inputSent: .none) }
            let url = directory.appendingPathComponent("stdin")
            guard FileManager.default.createFile(atPath: url.path, contents: inputData, attributes: [.posixPermissions: 0o600]) else {
                throw CommandFailure(.hostRequirement, "Cannot prepare private subprocess stdin.", inputSent: .none)
            }
            inputURL = url
        }
        let inputHandle = try inputURL.map { try FileHandle(forReadingFrom: $0) }
        defer { try? inputHandle?.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, overlay in overlay }
        }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = merged ? output : errors
        try process.run()
        if let recording {
            do {
                try superviseRecording(process, stderr: stderr, timing: recording)
            } catch {
                // Stop only this owned child; allow the encoder to finalize first.
                if process.isRunning { process.interrupt() }
                let deadline = ContinuousClock.now + .seconds(recording.finalizationSeconds)
                while process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw error
            }
        } else if timeout != nil || watch != nil {
            let start = ContinuousClock.now
            let deadline = timeout.map { start + .seconds($0) }
            var nextReport = watch.map { start + .seconds($0.interval) }
            while process.isRunning {
                if Task.isCancelled || deadline.map({ ContinuousClock.now >= $0 }) == true {
                    process.terminate()
                    let grace = ContinuousClock.now + .seconds(1)
                    while process.isRunning, ContinuousClock.now < grace { usleep(10_000) }
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    // What the process wrote so far, for a caller that keeps it.
                    if let keepOutput, let data = try? Data(contentsOf: stdout) { try? data.write(to: keepOutput) }
                    if Task.isCancelled { throw CancellationError() }
                    throw CommandFailure(.timeout, "\(URL(fileURLWithPath: executable).lastPathComponent) timed out; inspect device state before retrying an action.", inputSent: .unknown)
                }
                if let watch, let due = nextReport, ContinuousClock.now >= due {
                    let elapsed = start.duration(to: .now)
                    watch.report(stdout, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    nextReport = due + .seconds(watch.interval)
                }
                usleep(10_000)
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, try Data(contentsOf: stdout), try Data(contentsOf: stderr))
    }

    private func superviseRecording(_ process: Process, stderr: URL, timing: RecordingTiming) throws {
        let input = try FileHandle(forReadingFrom: stderr)
        defer { try? input.close() }
        let marker = Data("Recording started".utf8)
        var pending = Data()
        let startupDeadline = ContinuousClock.now + .seconds(timing.startupSeconds)
        var recordingDeadline: ContinuousClock.Instant?
        while process.isRunning {
            if Task.isCancelled { throw CancellationError() }
            if let recordingDeadline {
                if ContinuousClock.now >= recordingDeadline {
                    process.interrupt()
                    let deadline = ContinuousClock.now + .seconds(timing.finalizationSeconds)
                    while process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
                    guard !process.isRunning else {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                        throw CommandFailure(.timeout, "Simulator recording did not finalize before its deadline.", inputSent: .none)
                    }
                    return
                }
            } else {
                pending.append(try input.readToEnd() ?? Data())
                if pending.range(of: marker) != nil {
                    recordingDeadline = ContinuousClock.now + .seconds(timing.seconds)
                } else {
                    pending = Data(pending.suffix(marker.count - 1))
                    guard ContinuousClock.now < startupDeadline else {
                        throw CommandFailure(.timeout, "Simulator recorder did not report its first frame before the startup deadline.", inputSent: .none)
                    }
                }
            }
            usleep(10_000)
        }
        throw CommandFailure(.toolFailed, "Simulator recorder exited before the requested interval: \((try? String(contentsOf: stderr, encoding: .utf8)) ?? "No diagnostics")", inputSent: .none)
    }
}

