import Foundation
import Darwin

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

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
            throw CommandFailure(description: "Simulator recorder failed (\(result.status)): \(String(decoding: result.errors, as: UTF8.self))")
        }
    }
    func run(_ arguments: [String], executable: String = "/usr/bin/xcrun", timeout: Double? = nil, inputData: Data? = nil) throws -> Data {
        let result = try capture(arguments, executable: executable, inputData: inputData, timeout: timeout)
        guard result.status == 0 else {
            throw CommandFailure(description: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): \(String(decoding: result.errors, as: UTF8.self))")
        }
        FileHandle.standardError.write(result.errors)
        return result.output
    }

    /// Both Xcode output streams go through xcsift; retain the raw log on failure too.
    func build(_ arguments: [String], log: URL, executable: String = "/usr/bin/xcrun") throws {
        _ = try run(["xcsift", "--version"], executable: "/usr/bin/env")
        let result = try capture(arguments, executable: executable, merged: true)
        try result.output.write(to: log)
        let formatted = try capture(["xcsift", "-f", "toon"], executable: "/usr/bin/env", input: log)
        FileHandle.standardError.write(formatted.output)
        FileHandle.standardError.write(formatted.errors)
        guard formatted.status == 0 else {
            throw CommandFailure(description: "xcsift failed (\(formatted.status)); raw build log: \(log.path)")
        }
        guard result.status == 0 else {
            throw CommandFailure(description: "Xcode build failed (\(result.status)); raw build log: \(log.path)")
        }
    }

    private func capture(_ arguments: [String], executable: String,
                         merged: Bool = false, input: URL? = nil, inputData: Data? = nil,
                         recording: RecordingTiming? = nil, timeout: Double? = nil) throws -> (status: Int32, output: Data, errors: Data) {
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
            guard input == nil else { throw CommandFailure(description: "Process input cannot combine data and a file.") }
            let url = directory.appendingPathComponent("stdin")
            guard FileManager.default.createFile(atPath: url.path, contents: inputData, attributes: [.posixPermissions: 0o600]) else {
                throw CommandFailure(description: "Cannot prepare private subprocess stdin.")
            }
            inputURL = url
        }
        let inputHandle = try inputURL.map { try FileHandle(forReadingFrom: $0) }
        defer { try? inputHandle?.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        } else if let timeout {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while process.isRunning {
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    process.terminate()
                    let grace = ContinuousClock.now + .seconds(1)
                    while process.isRunning, ContinuousClock.now < grace { usleep(10_000) }
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    if Task.isCancelled { throw CancellationError() }
                    throw CommandFailure(description: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out; inspect device state before retrying an action.")
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
                        throw CommandFailure(description: "Simulator recording did not finalize before its deadline.")
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
                        throw CommandFailure(description: "Simulator recorder did not report its first frame before the startup deadline.")
                    }
                }
            }
            usleep(10_000)
        }
        throw CommandFailure(description: "Simulator recorder exited before the requested interval: \((try? String(contentsOf: stderr, encoding: .utf8)) ?? "No diagnostics")")
    }
}

