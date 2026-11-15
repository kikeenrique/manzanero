import Foundation
import MCP
import Testing
@testable import Manzanero

struct MCPToolsTests {
    @Test func cancellationPropagatesToSDKInsteadOfToolErrorResponse() async throws {
        do {
            _ = try await MCPTools.call(name: "press_button", arguments: ["device": "fixture", "platform": "physical", "button": "home"]) { _ in
                throw CancellationError()
            }
            Issue.record("Cancellation became an ordinary MCP response")
        } catch is CancellationError {
            // The SDK owns suppression of the cancelled request's response.
        }
    }
    @Test func multitouchToolsUseTheSharedPhysicalPlanner() throws {
        let pinch = try #require(MCPTools.definitions.first { $0.name == "pinch" })
        let args = try pinch.command(["device": "fixture", "center_x": 0.5, "center_y": 0.5, "start_span": 1, "end_span": 0.5, "seconds": 1])
        let planned = try #require(try DeviceCommand.parse(args))
        #expect(planned.arguments[2] == "multi-drag")
        #expect(planned.arguments[3] == "1000")
        let multi = try #require(MCPTools.definitions.first { $0.name == "multi_drag" })
        let multiArgs = try multi.command(["device": "fixture", "paths": [0, 0, 1, 1, 1, 1, 0, 0], "seconds": 1])
        let multiPlan = try #require(try DeviceCommand.parse(multiArgs))
        #expect(multiPlan.arguments == ["manzanero-idevice", "fixture", "multi-drag", "1000", "0", "0", "65535", "65535", "65535", "65535", "0", "0"])
    }
    @Test func catalogHasUniqueNamesAndClosedObjectSchemas() throws {
        let definitions = MCPTools.definitions
        #expect(definitions.count == 30)
        #expect(Set(definitions.map(\.name)).count == definitions.count)
        for definition in definitions {
            let schema = try #require(definition.tool.inputSchema.objectValue)
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
            #expect(definition.tool.annotations.readOnlyHint != nil)
        }
    }

    @Test func routingPreservesLiteralText() throws {
        let typing = try #require(MCPTools.definitions.first { $0.name == "type_text" })
        let text = "$(touch sentinel); 'hello'\nworld"
        let args = try typing.command(["device": "11111111-2222-3333-4444-555555555555", "text": .string(text)])
        let plan = try #require(try DeviceCommand.parse(args))
        #expect(plan.arguments.last == text)
        let tap = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let tapped = try tap.command(["platform": "physical", "device": "phone", "x": 0.5, "y": 1])
        #expect(tapped == ["physical", "phone", "tap", "0.5", "1"])
    }

    @Test func helperOnlyToolsAndFieldsAreNotAdvertised() throws {
        let names = Set(MCPTools.definitions.map(\.name))
        for removed in ["tap_element", "capture_logs", "get_accessibility_archive"] { #expect(!names.contains(removed)) }
        for definition in MCPTools.definitions {
            let properties = try #require(definition.tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["pairing_file"] == nil)
            #expect(properties["backend"] == nil)
        }
        let tap = try #require(MCPTools.definitions.first { $0.name == "tap" })
        for field in ["pairing_file", "backend"] {
            #expect(throws: MCPError.self) {
                try tap.command(["platform": "physical", "device": "phone", "x": 0.5, "y": 0.5, field: "fixture"])
            }
        }
    }

    @Test(arguments: [("type_text", ["device": Value.string("fixture"), "text": "a"], ["physical", "fixture", "type", "a"]),
                      ("get_ui_tree", ["device": Value.string("fixture")], ["physical", "fixture", "tree"])])
    func optionalPlatformDefaultsToPhysical(_ name: String, _ arguments: [String: Value], _ expected: [String]) throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        #expect(try definition.command(arguments) == expected)
    }

    @Test(arguments: [
        ["platform": Value.string("simulator")],
        ["platform": Value.string("wrong"), "device": "x", "x": 1, "y": 1],
        ["platform": Value.string("physical"), "device": "x", "x": "0.5", "y": 1],
        ["platform": Value.string("physical"), "device": "x", "x": true, "y": 1],
        ["platform": Value.string("physical"), "device": "x", "x": 0.5, "y": 1, "executable": "/bin/sh"]
    ]) func schemaFailuresDoNotInvokeExecutor(_ args: [String: Value]) async {
        do {
            _ = try await MCPTools.call(name: "tap", arguments: args) { _ in
                Issue.record("Invalid parameters reached executor")
                return CommandOutput(data: Data())
            }
            Issue.record("Expected invalid parameters")
        } catch {
            #expect(error is MCPError)
        }
    }

    @Test func backendFailureReturnsToolError() async throws {
        let result = try await MCPTools.call(name: "list_devices", arguments: ["platform": "simulator"]) { _ in
            throw CommandFailure(description: "fixture unavailable")
        }
        #expect(result.isError == true)
        guard case .text(let message, _, _) = result.content.first else { Issue.record("Missing tool error content"); return }
        #expect(message.contains("fixture unavailable"))
    }

    @Test func physicalTypingRoutesThroughTheSharedPlanner() throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "type_text" })
        let args = try definition.command(["platform": "physical", "device": "fixture", "text": "Hello!"])
        #expect(args == ["physical", "fixture", "type", "Hello!"])
        #expect(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args))?.operands == ["Hello!"])
    }

    @Test func unknownToolsCannotInvokeExecutor() async {
        await #expect(throws: MCPError.self) {
            try await MCPTools.call(name: "execute_shell", arguments: [:]) { _ in
                Issue.record("Unknown tool reached executor")
                return CommandOutput(data: Data())
            }
        }
    }

    @Test func commandExitFailureAndStructuredOutputArePreserved() async throws {
        let result = try await MCPTools.call(name: "doctor", arguments: [:]) { _ in
            CommandOutput(data: Data("[{\"status\":\"unavailable\"}]".utf8), exitCode: 1)
        }
        #expect(result.isError == true)
        #expect(result.structuredContent?.objectValue?["result"]?.arrayValue?.count == 1)
    }

    @Test func serviceReusesDryRunAndRejectsInteractivePairing() async throws {
        let service = CommandService()
        let result = try await service.execute(["physical", "phone", "tap", "0.5", "0.5"], dryRun: true)
        let plan = try #require(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct")
        #expect(plan["operands"] as? [String] == ["0.5", "0.5"])
        await #expect(throws: CommandFailure.self) {
            try await service.execute(["pair", "wifi", "example.local", "1234", "tmp/fixture.pairing.plist"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func sdkHandshakeDiscoveryAndToolError() async throws {
        let service = CommandService()
        let server = await AppleMCPServer.make(service: service)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "manzanero-test", version: "1")
        try await server.start(transport: serverTransport)
        do {
            let initialized = try await client.connect(transport: clientTransport)
            #expect(initialized.protocolVersion == "2025-11-25")
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "build_run" })
            #expect(tools.contains { $0.name == "get_ui_tree" })
            #expect(tools.contains { $0.name == "multi_drag" })
            #expect(tools.contains { $0.name == "pinch" })
            #expect(tools.contains { $0.name == "decode_accessibility_archive" })
            #expect(tools.contains { $0.name == "paste_text" })
            let (_, failed) = try await client.callTool(name: "tap", arguments: ["platform": "physical", "device": "fixture", "x": 2, "y": 0])
            #expect(failed == true)
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }
}
