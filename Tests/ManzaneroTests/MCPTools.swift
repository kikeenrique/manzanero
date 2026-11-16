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
    @Test func multitouchToolsUseTheSharedNativeValidation() throws {
        let pinch = try #require(MCPTools.definitions.first { $0.name == "pinch" })
        let args = try pinch.command(["device": "fixture", "center_x": 0.5, "center_y": 0.5, "start_span": 1, "end_span": 0.5, "seconds": 1])
        let planned = try #require(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args)))
        #expect(planned.operation == "pinch" && planned.operands == ["0.5", "0.5", "1", "0.5", "1"])
        let multi = try #require(MCPTools.definitions.first { $0.name == "multi_drag" })
        let multiArgs = try multi.command(["device": "fixture", "paths": [0, 0, 1, 1, 1, 1, 0, 0], "seconds": 1])
        let multiPlan = try #require(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(multiArgs)))
        #expect(multiPlan.operation == "multi-drag" && multiPlan.operands == ["1", "0", "0", "1", "1", "1", "1", "0", "0"])
    }
    @Test func catalogHasUniqueNamesAndClosedObjectSchemas() throws {
        let definitions = MCPTools.definitions
        #expect(definitions.count == 36)
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
        let plan = try #require(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args)))
        #expect(plan.operands == [text])
        let tap = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let tapped = try tap.command(["platform": "physical", "device": "phone", "x": 0.5, "y": 1])
        #expect(tapped == ["physical", "phone", "tap", "0.5", "1"])
    }

    @Test func buildRunProvisioningFlagsAreOptionalBooleans() throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "build_run" })
        let schema = try #require(definition.tool.inputSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        for name in ["allow_provisioning_updates", "allow_device_registration"] {
            #expect(properties[name]?.objectValue?["type"] == "boolean")
            #expect(!required.contains(name))
        }
        let base: [String: Value] = ["platform": "physical", "device": "00000000-0000000000000000", "project": "A.xcodeproj", "scheme": "A"]
        let plain = ["physical", "00000000-0000000000000000", "build-run", "A.xcodeproj", "A"]
        #expect(try definition.command(base) == plain)
        #expect(try definition.command(base.merging(["allow_provisioning_updates": false]) { $1 }) == plain)
        let flagged = try definition.command(base.merging(["allow_provisioning_updates": true, "allow_device_registration": true]) { $1 })
        #expect(flagged == plain + ["--allow-provisioning-updates", "--allow-device-registration"])
        let parsed = try #require(try BuildRunCommand.parse(flagged))
        #expect(parsed.allowProvisioningUpdates && parsed.allowDeviceRegistration)
        #expect(throws: MCPError.self) { try definition.command(base.merging(["allow_provisioning_updates": "yes"]) { $1 }) }
        let simulator = try definition.command(base.merging(["platform": "simulator", "device": "11111111-2222-3333-4444-555555555555",
                                                             "allow_provisioning_updates": true]) { $1 })
        #expect(throws: CommandFailure.self) { try BuildRunCommand.parse(simulator) }
    }

    @Test func helperOnlyToolsAndFieldsAreNotAdvertised() throws {
        let names = Set(MCPTools.definitions.map(\.name))
        // capture_logs was the retired idevice helper's tool; the name now
        // belongs to the simctl-based capture, which has no helper fields.
        for removed in ["tap_element", "get_accessibility_archive"] { #expect(!names.contains(removed)) }
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

    static let physicalDefaults: [(String, [String: Value], [String])] = [
        ("press_element", ["device": Value.string("fixture"), "by": "identifier", "text": "x"], ["physical", "fixture", "press-id", "x"]),
        ("scroll_to_element", ["device": Value.string("fixture"), "by": "label", "text": "x"], ["physical", "fixture", "scroll-label", "x"]),
        ("wait_for_element", ["device": Value.string("fixture"), "by": "identifier", "text": "x"], ["physical", "fixture", "wait-id", "x"]),
        ("press_key", ["device": Value.string("fixture"), "key": "return"], ["physical", "fixture", "key", "return"]),
        ("long_press", ["device": Value.string("fixture"), "x": 0.5, "y": 0.5, "seconds": 1],
         ["--physical-backend", "coredevice", "physical", "fixture", "long-press", "0.5", "0.5", "1"]),
        ("pinch", ["device": Value.string("fixture"), "center_x": 0.5, "center_y": 0.5, "start_span": 0.2, "end_span": 0.5, "seconds": 0.6],
         ["physical", "fixture", "pinch", "0.5", "0.5", "0.2", "0.5", "0.6"]),
        ("multi_drag", ["device": Value.string("fixture"), "seconds": 0.5, "paths": [0.5, 0.25, 0.5, 0.1, 0.5, 0.75, 0.5, 0.9]],
         ["physical", "fixture", "multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"])
    ]

    @Test(arguments: physicalDefaults)
    func newOptionalPlatformsKeepThePhysicalRoute(_ name: String, _ arguments: [String: Value], _ expected: [String]) throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        #expect(try definition.command(arguments) == expected)
        #expect(try definition.command(arguments.merging(["platform": "physical"]) { $1 }) == expected)
        let required = Set((definition.tool.inputSchema.objectValue?["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(!required.contains("platform"))
    }

    /// Every simulator operation an agent can reach over MCP routes to the
    /// simulator command that SimulatorInput accepts.
    static let simulatorRoutes: [(String, [String: Value], [String])] = [
        ("get_ui_tree", ["platform": Value.string("simulator")], ["tree"]),
        ("get_ui_tree", ["platform": Value.string("simulator"), "pid": 42], ["tree", "42"]),
        ("press_element", ["platform": Value.string("simulator"), "by": "identifier", "text": "probe.touch.reset"], ["press-id", "probe.touch.reset"]),
        ("scroll_to_element", ["platform": Value.string("simulator"), "by": "label", "text": "General"], ["scroll-label", "General"]),
        ("wait_for_element", ["platform": Value.string("simulator"), "by": "label", "text": "General", "timeout_seconds": 2], ["wait-label", "General", "--timeout", "2"]),
        ("tap", ["platform": Value.string("simulator"), "x": 0.5, "y": 0.25], ["tap", "0.5", "0.25"]),
        ("drag", ["platform": Value.string("simulator"), "x1": 0.3, "y1": 0.5, "x2": 0.7, "y2": 0.5, "seconds": 0.5], ["drag", "0.3", "0.5", "0.7", "0.5", "0.5"]),
        ("long_press", ["platform": Value.string("simulator"), "x": 0.5, "y": 0.5, "seconds": 0.8], ["long-press", "0.5", "0.5", "0.8"]),
        ("press_button", ["platform": Value.string("simulator"), "button": "home"], ["button", "home"]),
        ("press_key", ["platform": Value.string("simulator"), "key": "backspace"], ["key", "backspace"]),
        ("type_text", ["platform": Value.string("simulator"), "text": "Wi-Fi"], ["type", "Wi-Fi"]),
        ("pinch", ["platform": Value.string("simulator"), "center_x": 0.5, "center_y": 0.5, "start_span": 0.2, "end_span": 0.5, "seconds": 0.6],
         ["pinch", "0.5", "0.5", "0.2", "0.5", "0.6"]),
        ("multi_drag", ["platform": Value.string("simulator"), "seconds": 0.5, "paths": [0.5, 0.25, 0.5, 0.1, 0.5, 0.75, 0.5, 0.9]],
         ["multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]),
        ("set_element_value", ["platform": Value.string("simulator"), "by": "identifier", "text": "probe.text.field", "value": "mañana 🚀 中"],
         ["set-value-id", "probe.text.field", "mañana 🚀 中"]),
        ("set_element_value", ["platform": Value.string("simulator"), "by": "label", "text": "Field", "pid": 42, "value": "x"],
         ["set-value-label", "42", "Field", "x"])
    ]

    @Test func setElementValueOnAPhysicalDeviceIsRefusedPlainly() async throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "set_element_value" })
        let args = try definition.command(["platform": "physical", "device": "fixture", "by": "identifier", "text": "f", "value": "v"])
        #expect(args == ["physical", "fixture", "set-value-id", "f", "v"])
        for dryRun in [false, true] {
            let failure = try #require(await #expect(throws: CommandFailure.self) {
                _ = try await CommandService(readinessQuery: { _ in Issue.record("queried a device"); return Data() }).execute(args, dryRun: dryRun)
            })
            #expect(failure.code == .unsupportedOperation && failure.inputSent == .none && failure.retry == .no)
            #expect(failure.description == "Physical set-value-id is not enabled: the accessibility set-value request has been verified only on simulators. For Unicode text on a physical device use paste. No input sent.")
        }
    }

    @Test(arguments: simulatorRoutes)
    func simulatorPlatformRoutesToTheSimulatorCommand(_ name: String, _ arguments: [String: Value], _ operands: [String]) throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        let args = try definition.command(arguments.merging(["device": .string(uuid)]) { $1 })
        #expect(args == ["simulator", uuid] + operands)
        let parsed = try #require(try SimulatorInput.parse(args))
        #expect(parsed.operation == operands[0])
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

    @Test func serviceReusesDryRun() async throws {
        let service = CommandService()
        let result = try await service.execute(["physical", "phone", "tap", "0.5", "0.5"], dryRun: true)
        let plan = try #require(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct")
        #expect(plan["operands"] as? [String] == ["0.5", "0.5"])
    }

    @Test func inspectDeviceOffersOnlyWorkingQueries() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "inspect_device" })
        let query = try #require(tool.tool.inputSchema.objectValue?["properties"]?.objectValue?["query"]?.objectValue)
        #expect(query["enum"] == .array(["apps", "details", "processes", "media-status"]))
        #expect(throws: MCPError.self) { try tool.command(["platform": "physical", "device": "phone", "query": "hid-info"]) }
        for definition in MCPTools.definitions {
            #expect(!definition.description.contains("AXe"))
            #expect(!definition.description.lowercased().contains("legacy"))
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
