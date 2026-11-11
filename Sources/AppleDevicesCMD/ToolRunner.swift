import Foundation

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses argument arrays and file-backed output so child processes cannot fill a pipe.
struct ToolRunner {
    func run(_ arguments: [String], executable: String = "/usr/bin/xcrun", interactive: Bool = false) throws -> Data {
        let result = try capture(arguments, executable: executable, interactive: interactive)
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

    private func capture(_ arguments: [String], executable: String, interactive: Bool = false,
                         merged: Bool = false, input: URL? = nil) throws -> (status: Int32, output: Data, errors: Data) {
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
        let inputHandle = try input.map { try FileHandle(forReadingFrom: $0) }
        defer { try? output.close(); try? errors.close() }
        defer { try? inputHandle?.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputHandle ?? (interactive ? FileHandle.standardInput : FileHandle.nullDevice)
        process.standardOutput = output
        process.standardError = merged ? output : (interactive ? FileHandle.standardError : errors)
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try Data(contentsOf: stdout), try Data(contentsOf: stderr))
    }
}

