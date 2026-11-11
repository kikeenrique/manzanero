import Foundation

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses argument arrays and file-backed output so child processes cannot fill a pipe.
struct ToolRunner {
    func run(_ arguments: [String]) throws -> Data {
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
            throw CommandFailure(description: "xcrun \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(detail)")
        }
        return try Data(contentsOf: stdout)
    }
}

let help = """
appledevicescmd — Apple device tools for terminals and agents

Usage:
  appledevicescmd devices physical     List CoreDevice devices as JSON
  appledevicescmd devices simulators   List available simulators as JSON
  appledevicescmd doctor               Check Xcode and device-service access
  appledevicescmd ocr <image-path>     Recognize image text and normalized bounds as JSON
  appledevicescmd physical <device> apps
  appledevicescmd physical <device> <launch|uninstall> <bundle-id>
  appledevicescmd physical <device> install <app-path>
  appledevicescmd physical <device> screenshot <output.png>
  appledevicescmd simulator <device> <apps|boot|shutdown>
  appledevicescmd simulator <device> <launch|terminate|uninstall> <bundle-id>
  appledevicescmd simulator <device> install <app-path>
  appledevicescmd simulator <device> open-url <url>
  appledevicescmd simulator <device> screenshot <output.png>
  Prefix a device command with --dry-run to print its invocation without executing.
  appledevicescmd --help
  appledevicescmd --version

HID, accessibility, streaming, and MCP are tracked in docs/ROADMAP.md.
Physical commands return devicectl JSON; simulator commands return simctl output.
Temporary command output is created beneath ./tmp and removed after each command.
"""

do {
    var args = Array(CommandLine.arguments.dropFirst())
    let runner = ToolRunner()
    let dryRun = args.first == "--dry-run"
    if dryRun { args.removeFirst() }
    if let command = try DeviceCommand.parse(args) {
        if dryRun {
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["executable": "/usr/bin/xcrun", "arguments": command.arguments], options: [.prettyPrinted, .sortedKeys]))
            print()
        } else {
            let data = try runner.run(command.arguments)
            if command.jsonOutput { _ = try JSONSerialization.jsonObject(with: data) }
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }
    guard !dryRun else { throw CommandFailure(description: "--dry-run requires a physical or simulator command.") }
    switch args {
    case let values where values.first == "ocr":
        guard values.count == 2 else {
            throw CommandFailure(description: "Usage: appledevicescmd ocr <image-path>")
        }
        let result = try await ScreenText.recognize(path: values[1])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(result))
        print()
    case [], ["--help"], ["-h"]:
        print(help)
    case ["--version"]:
        print("appledevicescmd 0.1.0-dev")
    case ["devices", "physical"]:
        let data = try runner.run(["devicectl", "list", "devices", "--timeout", "15", "--json-output", "-"])
        _ = try JSONSerialization.jsonObject(with: data)
        FileHandle.standardOutput.write(data)
    case ["devices", "simulators"]:
        let data = try runner.run(["simctl", "list", "devices", "available", "--json"])
        _ = try JSONSerialization.jsonObject(with: data)
        FileHandle.standardOutput.write(data)
    case ["doctor"]:
        var checks: [[String: String]] = []
        for (name, command) in [
            ("Xcode", ["xcodebuild", "-version"]),
            ("CoreDevice", ["devicectl", "list", "devices", "--timeout", "5", "--json-output", "-"]),
            ("CoreSimulator", ["simctl", "list", "devices", "available", "--json"])
        ] {
            do {
                _ = try runner.run(command)
                checks.append(["name": name, "status": "available"])
            } catch {
                checks.append(["name": name, "status": "unavailable", "detail": String(describing: error)])
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]))
        print()
        if checks.contains(where: { $0["status"] == "unavailable" }) { exit(1) }
    default:
        throw CommandFailure(description: "Unknown command. Run appledevicescmd --help.")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
