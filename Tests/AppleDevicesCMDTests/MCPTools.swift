import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct MCPToolsTests {
    @Test func catalogHasUniqueNamesAndClosedObjectSchemas() throws {
        let definitions = MCPTools.definitions
        #expect(Set(definitions.map(\.name)).count == definitions.count)
        for definition in definitions {
            let schema = try #require(definition.tool.inputSchema.objectValue)
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
            #expect(definition.tool.annotations.readOnlyHint != nil)
        }
    }

    @Test func routingPreservesLiteralTextAndPairing() throws {
        let typing = try #require(MCPTools.definitions.first { $0.name == "type_text" })
        let text = "$(touch sentinel); 'hello'\nworld"
        let args = try typing.command(["device": "11111111-2222-3333-4444-555555555555", "text": .string(text)])
        let plan = try #require(try DeviceCommand.parse(args))
        #expect(plan.arguments.last == text)
        let tap = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let tapped = try tap.command(["platform": "physical", "device": "phone", "x": 0.5, "y": 1, "pairing_file": "tmp/My Phone.pairing.plist"])
        let physical = try #require(try DeviceCommand.parse(tapped))
        #expect(physical.arguments == ["appledevices-idevice", "--pairing-file", "tmp/My Phone.pairing.plist", "phone", "tap", "32768", "65535"])
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
        let args = try definition.command(["platform": "physical", "device": "fixture", "text": "Hello!", "pairing_file": "tmp/fixture.pairing.plist"])
        let command = try #require(try DeviceCommand.parse(args))
        #expect(command.arguments == ["appledevices-idevice", "--pairing-file", "tmp/fixture.pairing.plist", "fixture", "type", "Hello!"])
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
        #expect(plan["arguments"] as? [String] == ["appledevices-idevice", "phone", "tap", "32768", "32768"])
        await #expect(throws: CommandFailure.self) {
            try await service.execute(["pair", "wifi", "example.local", "1234", "tmp/fixture.pairing.plist"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func sdkHandshakeDiscoveryAndToolError() async throws {
        let service = CommandService()
        let server = await AppleMCPServer.make(service: service)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "appledevicescmd-test", version: "1")
        try await server.start(transport: serverTransport)
        do {
            let initialized = try await client.connect(transport: clientTransport)
            #expect(initialized.protocolVersion == "2025-11-25")
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "build_run" })
            #expect(tools.contains { $0.name == "get_ui_tree" })
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
