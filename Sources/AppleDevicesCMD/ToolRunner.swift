import Foundation

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses argument arrays and file-backed output so child processes cannot fill a pipe.
struct ToolRunner {
    func run(_ arguments: [String], executable: String = "/usr/bin/xcrun", interactive: Bool = false) throws -> Data {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = interactive ? FileHandle.standardInput : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = interactive ? FileHandle.standardError : errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
            throw CommandFailure(description: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)): \(detail)")
        }
        FileHandle.standardError.write(try Data(contentsOf: stderr))
        return try Data(contentsOf: stdout)
    }
}

