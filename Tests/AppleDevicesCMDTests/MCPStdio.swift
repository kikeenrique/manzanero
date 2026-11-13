import Darwin
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import AppleDevicesCMD

/// Opt-in because this queries a selected simulator or physical application.
struct MCPStdioTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_LIVE"] == "1"), .timeLimit(.minutes(1)))
    func subprocessHandshakeAndDeviceTools() async throws {
        let physical = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_PHYSICAL"]
        let simulator = physical == nil ? try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_SIMULATOR"]) : ""
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
            let deadline = ContinuousClock.now + .seconds(physical == nil ? 20 : 50)
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
        func finish() throws {
            try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
            #expect(process.isRunning == false)
            if !process.isRunning { #expect(process.terminationStatus == 0) }
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
        if let physical {
            let cancelFile = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_CANCEL_GESTURE_FILE"]
            let cancelHold = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_CANCEL_LONG_PRESS"]
            let shutdownMode = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_SHUTDOWN"]
            if let shutdownMode { try #require(["EOF", "SIGINT", "SIGTERM"].contains(shutdownMode)) }
            if cancelFile != nil || cancelHold != nil {
                let name: String, arguments: [String: Any], milliseconds: Int
                if let file = cancelFile {
                    let json = try String(contentsOfFile: file, encoding: .utf8)
                    let sequence = try NativeGestureSequence(json: json)
                    milliseconds = sequence.times.last ?? 0
                    name = "perform_gesture"; arguments = ["device": physical, "sequence": json]
                } else {
                    let operands = try #require(cancelHold).split(separator: ",").map(String.init)
                    _ = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", physical, "long-press"] + operands))
                    let numbers = try operands.map { try #require(Double($0)) }
                    milliseconds = Int((numbers[2] * 1000).rounded())
                    name = "long_press"; arguments = ["device": physical, "x": numbers[0], "y": numbers[1], "seconds": numbers[2]]
                }
                try #require((8000...10000).contains(milliseconds))
                let before = try request(4, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical,
                    "path": directory.appendingPathComponent("cancel-before.png").path]])
                try #require((before["result"] as? [String: Any])?["isError"] as? Bool == false)
                let baselineStart = ContinuousClock.now
                let baseline = try request(40, "tools/call", ["name": "device_readiness", "arguments": ["device": physical]])
                try #require((baseline["result"] as? [String: Any])?["isError"] as? Bool == false)
                let baselineDuration = baselineStart.duration(to: .now)
                let start = ContinuousClock.now
                try send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
                try await Task.sleep(for: .seconds(2))
                if let shutdownMode {
                    let exitCode: Int32
                    switch shutdownMode {
                    case "EOF": try input.fileHandleForWriting.close(); exitCode = 0
                    case "SIGINT": try #require(Darwin.kill(process.processIdentifier, SIGINT) == 0); exitCode = 130
                    default: try #require(Darwin.kill(process.processIdentifier, SIGTERM) == 0); exitCode = 143
                    }
                    // Allow the runtime's own 30-second grace before the test
                    // cleanup may kill this owned child on a genuine stall.
                    let deadline = ContinuousClock.now + .seconds(35)
                    while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    try #require(!process.isRunning, "MCP process did not finish its shutdown grace")
                    process.waitUntilExit()
                    let elapsed = start.duration(to: .now)
                    #expect(elapsed < .seconds(8))
                    #expect(process.terminationReason == .exit && process.terminationStatus == exitCode)
                    // All previous responses were consumed. Shutdown must not
                    // publish a normal success receipt for the interrupted call.
                    while true {
                        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&descriptor, 1, 0)
                        if ready < 0, errno == EINTR { continue }
                        try #require(ready >= 0)
                        if ready == 0 { break }
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                        if count < 0, errno == EINTR { continue }
                        try #require(count >= 0)
                        if count == 0 { break }
                        buffer.append(contentsOf: bytes.prefix(count))
                        try #require(buffer.count <= 65536)
                    }
                    #expect(buffer.isEmpty)
                    let diagnostic = try String(contentsOf: errorsURL, encoding: .utf8)
                    #expect(!diagnostic.contains("forcing exit"))
                    if shutdownMode != "EOF" { #expect(diagnostic.contains("Interrupted by \(shutdownMode)")) }
                    try JSONSerialization.data(withJSONObject: ["shutdown": shutdownMode, "exitCode": process.terminationStatus,
                        "elapsed": String(describing: elapsed), "plannedMilliseconds": milliseconds,
                        "pendingOutputBytes": buffer.count, "forcedExitDiagnostic": diagnostic.contains("forcing exit"),
                        "deviceSideReleaseVerified": false], options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("shutdown-result.json"))
                    let screenshot = try await CommandService().execute(["physical", physical, "screenshot",
                        directory.appendingPathComponent("shutdown-after.png").path])
                    #expect(screenshot.exitCode == 0)
                    return
                }
                try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 5, "reason": "Explicit live cancellation verification"]])
                // This call must enter the same command actor after input's
                // cleanup; screenshot latency is measured separately below.
                let ready = try request(6, "tools/call", ["name": "device_readiness", "arguments": ["device": physical]])
                try #require((ready["result"] as? [String: Any])?["isError"] as? Bool == false)
                let actorAvailable = start.duration(to: .now)
                #expect(actorAvailable < .seconds(8))
                let captureStart = ContinuousClock.now
                let after = try request(7, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical,
                    "path": directory.appendingPathComponent("cancel-after.png").path]])
                try #require((after["result"] as? [String: Any])?["isError"] as? Bool == false)
                let elapsed = start.duration(to: .now)
                try JSONSerialization.data(withJSONObject: ["cancelledRequest": 5, "followupRequest": 6, "screenshotRequest": 7,
                    "operation": name, "elapsed": String(describing: elapsed), "plannedMilliseconds": milliseconds,
                    "baselineReadiness": String(describing: baselineDuration), "actorAvailableElapsed": String(describing: actorAvailable),
                    "captureElapsed": String(describing: captureStart.duration(to: .now)),
                    "deviceSideReleaseVerified": false], options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("cancel-result.json"))
                try finish()
                return
            }
            if let text = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_PASTE"] ?? ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_TYPE"] {
                let paste = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_PASTE"] != nil
                let operation = paste ? "paste" : "type"
                _ = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", physical, operation, text]))
                let before = try request(4, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-\(operation)-before.png").path]])
                try #require((before["result"] as? [String: Any])?["isError"] as? Bool == false)
                let response = try request(5, "tools/call", ["name": paste ? "paste_text" : "type_text", "arguments": ["platform": "physical", "device": physical, "text": text].filter { paste ? $0.key != "platform" : true }])
                let result = try #require(response["result"] as? [String: Any])
                try #require(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let receipt = try #require(structured["result"] as? [String: Any])
                #expect(receipt["backend"] as? String == "coredevice-direct" && receipt["operation"] as? String == operation)
                if paste { #expect(receipt["clipboard"] as? String == "replaced") }
                else {
                    #expect(receipt["layout"] as? String == "US" && receipt["characterCount"] as? Int == text.utf8.count)
                    #expect(receipt["clipboard"] == nil)
                }
                #expect(receipt["insertionVerified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("direct-\(operation).json"))
                let after = try request(6, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-\(operation)-after.png").path]])
                try #require((after["result"] as? [String: Any])?["isError"] as? Bool == false)
                try finish()
                return
            }
            if let key = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_KEY"] {
                _ = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", physical, "key", key]))
                let before = try request(4, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-key-before.png").path]])
                #expect((before["result"] as? [String: Any])?["isError"] as? Bool == false)
                let response = try request(5, "tools/call", ["name": "press_key", "arguments": ["device": physical, "key": key]])
                let result = try #require(response["result"] as? [String: Any])
                try #require(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let receipt = try #require(structured["result"] as? [String: Any])
                #expect(receipt["backend"] as? String == "coredevice-direct")
                #expect(receipt["operation"] as? String == "key")
                #expect(receipt["key"] as? String == key)
                #expect(receipt["usage"] as? UInt64 == DirectPhysicalKeyboard.usages[key])
                #expect(receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("direct-key.json"))
                let after = try request(6, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-key-after.png").path]])
                #expect((after["result"] as? [String: Any])?["isError"] as? Bool == false)
                try finish()
                return
            }
            if ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_BUTTON"] == "1" {
                let before = try request(4, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-button-before.png").path]])
                #expect((before["result"] as? [String: Any])?["isError"] as? Bool == false)
                let response = try request(5, "tools/call", ["name": "press_button", "arguments": ["platform": "physical", "device": physical, "button": "home"]])
                let result = try #require(response["result"] as? [String: Any])
                try #require(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let receipt = try #require(structured["result"] as? [String: Any])
                #expect(receipt["backend"] as? String == "coredevice-direct")
                #expect(receipt["verified"] as? Bool == false)
                let screenshot = try request(6, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("direct-button-after.png").path]])
                #expect((screenshot["result"] as? [String: Any])?["isError"] as? Bool == false)
                try finish()
                return
            }
            if ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_RECORDING"] == "1" {
                let path = directory.appendingPathComponent("physical-hevc.mp4")
                let response = try request(4, "tools/call", ["name": "record_screen", "arguments": ["platform": "physical", "device": physical, "path": path.path, "seconds": 2, "codec": "hevc", "recording_backend": "coredevice"]])
                let result = try #require(response["result"] as? [String: Any])
                try #require(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let receipt = try #require(structured["result"] as? [String: Any])
                #expect(receipt["backend"] as? String == "coredevice-avconference")
                #expect((receipt["sourceFrames"] as? Int ?? 0) > 0)
                let video = try await VideoArtifact.inspect(path)
                #expect(abs(video.duration - 2) < 0.02)
                #expect(video.codec == "hvc1")
                #expect((receipt["cleanup"] as? [String: Any])?["deviceStopConfirmed"] as? Bool == false)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: path))
                let frame = try await generator.image(at: .zero)
                let imageURL = directory.appendingPathComponent("recording-first-frame.png")
                let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, frame.image, nil)
                #expect(CGImageDestinationFinalize(destination))
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent("recording.json"))
                let screenshot = try request(5, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("after-recording.png").path]])
                #expect((screenshot["result"] as? [String: Any])?["isError"] as? Bool == false)
                try finish()
                return
            }
            let hold = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_LONG_PRESS"]
            let pinch = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_PINCH"]
            let sequenceFile = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_GESTURE_FILE"]
            let multitouch = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_MULTITOUCH"]
            if hold != nil || sequenceFile != nil || pinch != nil || multitouch != nil {
                let operation: String
                let name: String
                let arguments: [String: Any]
                if let multitouch {
                    let operands = multitouch.split(separator: ",").map(String.init)
                    operation = try #require(operands.first)
                    try #require(["multi-tap", "multi-drag"].contains(operation))
                    let input = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", physical] + operands))
                    _ = try DirectPhysicalGesture.sequence(for: input)
                    let values = try input.operands.map { try #require(Double($0)) }
                    name = operation == "multi-tap" ? "multi_tap" : "multi_drag"
                    arguments = operation == "multi-tap" ? ["device": physical, "coordinates": values] :
                        ["device": physical, "seconds": values[0], "paths": Array(values.dropFirst())]
                } else if let sequenceFile {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: sequenceFile), options: .mappedIfSafe)
                    let json = try #require(String(data: bytes, encoding: .utf8))
                    _ = try NativeGestureSequence(json: json)
                    operation = "gesture"; name = "perform_gesture"
                    arguments = ["device": physical, "sequence": json]
                } else if let pinch {
                    let operands = pinch.split(separator: ",").map(String.init)
                    _ = try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", physical, "pinch"] + operands))
                    let values = try operands.map { try #require(Double($0)) }
                    operation = "pinch"; name = "pinch"
                    arguments = ["device": physical, "center_x": values[0], "center_y": values[1], "start_span": values[2], "end_span": values[3], "seconds": values[4]]
                } else {
                    let operands = try #require(hold).split(separator: ",").map(String.init)
                    let command = ["--physical-backend", "coredevice", "physical", physical, "long-press"] + operands
                    _ = try #require(try CoreDeviceInput.parse(command))
                    operation = "long-press"; name = "long_press"
                    arguments = ["device": physical, "x": try #require(Double(operands[0])), "y": try #require(Double(operands[1])), "seconds": try #require(Double(operands[2]))]
                }
                let response = try request(4, "tools/call", ["name": name, "arguments": arguments])
                let result = try #require(response["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let receipt = try #require(structured["result"] as? [String: Any])
                #expect(receipt["operation"] as? String == operation)
                if operation == "long-press" {
                    #expect(receipt["backend"] as? String == "coredevice-direct")
                    #expect((receipt["sampleCount"] as? Int ?? 0) > 2)
                }
                if operation == "pinch" {
                    #expect(receipt["backend"] as? String == "coredevice-direct")
                    #expect(receipt["contactCount"] as? Int == 2)
                    #expect(receipt["sampleCount"] as? Int == 32)
                }
                if ["gesture", "multi-tap", "multi-drag"].contains(operation) {
                    #expect(receipt["backend"] as? String == "coredevice-direct")
                    #expect((receipt["frameCount"] as? Int ?? 0) >= 2)
                    #expect((receipt["contactSlots"] as? Int ?? 0) >= 1)
                    #expect(receipt["releaseVerified"] as? Bool == false)
                }
                #expect(receipt["verified"] as? Bool == false)
                let artifact = directory.appendingPathComponent("physical-\(operation).json")
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                #expect(FileManager.default.createFile(atPath: artifact.path, contents: data, attributes: [.posixPermissions: 0o600]))
                let screenshot = try request(5, "tools/call", ["name": "screenshot", "arguments": ["platform": "physical", "device": physical, "path": directory.appendingPathComponent("\(operation).png").path]])
                #expect((screenshot["result"] as? [String: Any])?["isError"] as? Bool == false)
                try finish()
                return
            }
            let rawPID = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_PID"] ?? ""
            let pid = Int(rawPID)
            guard rawPID.isEmpty || pid.map({ $0 > 0 }) == true else {
                throw CommandFailure(description: "Physical MCP test PID must be positive or omitted for foreground selection.")
            }
            var arguments: [String: Any] = ["device":physical,"platform":"physical"]
            if let pid { arguments["pid"] = pid }
            let response = try request(4, "tools/call", ["name": "get_ui_tree", "arguments": arguments])
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == false)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            let tree = try #require(structured["result"] as? [String: Any])
            #expect(tree["parsedHierarchy"] as? Bool == true)
            #expect(tree["atomic"] as? Bool == false)
            let application = try #require(tree["application"] as? [String: Any])
            if let pid { #expect(application["pid"] as? Int == pid) }
            else {
                #expect((application["pid"] as? Int ?? 0) > 0)
                #expect(application["selection"] as? String == "centre-hit-test")
            }
            let cleanup = try #require(tree["cleanup"] as? [String: Any])
            let stop = try #require(cleanup["subscriptionStop"] as? String)
            #expect(["confirmed", "connection-closed-before-ack"].contains(stop))
            if stop == "connection-closed-before-ack" {
                #expect(cleanup["confirmed"] as? Bool == false)
                #expect(!(cleanup["warning"] as? String ?? "").isEmpty)
            }
            let nodes = try #require(tree["nodes"] as? [[String: Any]])
            #expect(!nodes.isEmpty)
            #expect(tree["nodeCount"] as? Int == nodes.count)
            let ids = Set(nodes.compactMap { $0["id"] as? String })
            #expect(ids.count == nodes.count)
            for node in nodes {
                let children = try #require(node["children"] as? [String])
                #expect(children.allSatisfy(ids.contains))
            }
            let artifact = directory.appendingPathComponent("physical-tree.json")
            let data = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
            #expect(FileManager.default.createFile(atPath: artifact.path, contents: data, attributes: [.posixPermissions: 0o600]))
            if pid == nil {
                let response = try request(5,"tools/call",["name":"get_screen","arguments":["device":physical,"platform":"physical"]])
                let result = try #require(response["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let screen = try #require(structured["result"] as? [String: Any])
                #expect(screen["method"] as? String == "accessibility")
                #expect(screen["coordinateSpace"] as? String == "device-logical-points")
                #expect((screen["hierarchy"] as? [String: Any])?["parsedHierarchy"] as? Bool == true)
                let content = try #require(result["content"] as? [[String: Any]])
                #expect(content.contains { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" })
                let artifact = directory.appendingPathComponent("physical-screen.json")
                let data = try JSONSerialization.data(withJSONObject:screen,options:[.prettyPrinted,.sortedKeys])
                #expect(FileManager.default.createFile(atPath:artifact.path,contents:data,attributes:[.posixPermissions:0o600]))
            }
            if let identifier = ProcessInfo.processInfo.environment["APPLEDEVICES_MCP_TEST_SCROLL_IDENTIFIER"], !identifier.isEmpty {
                let response = try request(6, "tools/call", ["name": "scroll_to_element", "arguments": ["device": physical, "by": "identifier", "text": identifier]])
                let result = try #require(response["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == false)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let scroll = try #require(structured["result"] as? [String: Any])
                #expect(scroll["operation"] as? String == "scroll-to-visible")
                #expect(scroll["nativeResult"] as? Bool != nil)
                #expect(scroll["postconditionVerified"] as? Bool == true)
                #expect((scroll["after"] as? [String: Any])?["identifier"] as? String == identifier)
                #expect((scroll["after"] as? [String: Any])?["visible"] as? Bool == true)
                let artifact = directory.appendingPathComponent("physical-scroll.json")
                let data = try JSONSerialization.data(withJSONObject: scroll, options: [.prettyPrinted, .sortedKeys])
                #expect(FileManager.default.createFile(atPath: artifact.path, contents: data, attributes: [.posixPermissions: 0o600]))
            }
            try finish()
            return
        }
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
        try finish()
    }
}
