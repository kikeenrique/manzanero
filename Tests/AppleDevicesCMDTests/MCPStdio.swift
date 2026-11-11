import Darwin
import Foundation
import Testing
@testable import AppleDevicesCMD

/// Opt-in because this queries CoreSimulator and captures the selected screen.
struct MCPStdioTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_LIVE"] == "1"), .timeLimit(.minutes(1)))
    func subprocessHandshakeAndSimulatorTools() throws {
        let simulator = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_SIMULATOR"])
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("tmp/mcp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let errorsURL = directory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? errors.close() }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = root.appendingPathComponent(".build/debug/appledevicescmd")
        process.arguments = ["mcp"]
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive() throws -> [String: Any] {
            let deadline = ContinuousClock.now + .seconds(20)
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let message = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return try #require(try JSONSerialization.jsonObject(with: message) as? [String: Any])
                }
                guard ContinuousClock.now < deadline else { throw CommandFailure(description: "MCP response timed out; stderr at \(errorsURL.path)") }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 250)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw CommandFailure(description: "MCP stdout poll failed") }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CommandFailure(description: "MCP closed stdout before responding; stderr at \(errorsURL.path)")
                }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let response = try receive()
            #expect(response["id"] as? Int == id)
            #expect(response["jsonrpc"] as? String == "2.0")
            return response
        }
        let initialized = try request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": ["elicitation": ["form": [:]]], "clientInfo": ["name": "stdio-verification", "version": "1"]])
        let initResult = try #require(initialized["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2025-11-25")
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let listed = try request(2, "tools/list", [:])
        let listResult = try #require(listed["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == MCPTools.definitions.map(\.name))
        let invalid = try request(3, "tools/call", ["name": "tap", "arguments": ["platform": "physical", "device": "fixture", "x": 2, "y": 0]])
        #expect((invalid["result"] as? [String: Any])?["isError"] as? Bool == true)
        let inventory = try request(4, "tools/call", ["name": "list_devices", "arguments": ["platform": "simulator"]])
        let inventoryResult = try #require(inventory["result"] as? [String: Any])
        #expect(inventoryResult["isError"] as? Bool == false)
        let structured = try #require(inventoryResult["structuredContent"] as? [String: Any])
        #expect((structured["result"] as? [String: Any])?["devices"] != nil)
        let tree = try request(5, "tools/call", ["name": "get_ui_tree", "arguments": ["device": simulator]])
        #expect((tree["result"] as? [String: Any])?["isError"] as? Bool == false)
        let screenshot = try request(6, "tools/call", ["name": "screenshot", "arguments": ["platform": "simulator", "device": simulator, "path": directory.appendingPathComponent("screen.png").path]])
        let screenshotResult = try #require(screenshot["result"] as? [String: Any])
        #expect(screenshotResult["isError"] as? Bool == false)
        let content = try #require(screenshotResult["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image" })
        #expect(image["mimeType"] as? String == "image/png")
        let base64 = try #require(image["data"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        #expect(bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let recorded = try request(7, "tools/call", ["name": "record_screen", "arguments": ["platform": "simulator", "device": simulator, "path": directory.appendingPathComponent("screen.mp4").path, "seconds": 1]])
        let recordedResult = try #require(recorded["result"] as? [String: Any])
        #expect(recordedResult["isError"] as? Bool == false)
        let recordStructured = try #require(recordedResult["structuredContent"] as? [String: Any])
        let recording = try #require(recordStructured["result"] as? [String: Any])
        let artifact = try #require(recording["artifact"] as? [String: Any])
        #expect(recording["status"] as? String == "recorded")
        #expect(artifact["frameDecoded"] as? Bool == true)
        #expect((artifact["durationSeconds"] as? Double ?? 0) > 0)
        try send(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "request_handoff", "arguments": ["platform": "simulator", "device": simulator, "message": "Synthetic handoff verification"]]])
        let elicitation = try receive()
        #expect(elicitation["method"] as? String == "elicitation/create")
        let elicitationID = try #require(elicitation["id"])
        let form = try #require(elicitation["params"] as? [String: Any])
        let schema = try #require(form["requestedSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["completed"])
        try send(["jsonrpc": "2.0", "id": elicitationID, "result": ["action": "accept", "content": ["completed": true]]])
        let acknowledged = try receive()
        #expect(acknowledged["id"] as? Int == 8)
        let handoffResult = try #require(acknowledged["result"] as? [String: Any])
        #expect(handoffResult["isError"] as? Bool == false)
        let handoffStructured = try #require(handoffResult["structuredContent"] as? [String: Any])
        #expect((handoffStructured["result"] as? [String: Any])?["humanAcknowledged"] as? Bool == true)
        let inspected = try request(9, "tools/call", ["name": "get_screen", "arguments": ["platform": "simulator", "device": simulator]])
        let inspectResult = try #require(inspected["result"] as? [String: Any])
        #expect(inspectResult["isError"] as? Bool == false)
        let inspectStructured = try #require(inspectResult["structuredContent"] as? [String: Any])
        let screen = try #require(inspectStructured["result"] as? [String: Any])
        #expect(screen["method"] as? String == "accessibility")
        let screenContent = try #require(inspectResult["content"] as? [[String: Any]])
        #expect(screenContent.contains { $0["type"] as? String == "image" })
        // Closing stdin must end the server without a protocol shutdown request.
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
        #expect(process.isRunning == false)
        if !process.isRunning { #expect(process.terminationStatus == 0) }
    }
}
