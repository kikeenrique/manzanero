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
        #expect(args == ["pinch", "--device=fixture", "--", "0.5", "0.5", "1", "0.5", "1"])
        let planned = try #require(try physicalInput(args))
        #expect(planned.operation == "pinch" && planned.operands == ["0.5", "0.5", "1", "0.5", "1"])
        let multi = try #require(MCPTools.definitions.first { $0.name == "multi_drag" })
        let multiArgs = try multi.command(["device": "fixture", "paths": [0, 0, 1, 1, 1, 1, 0, 0], "seconds": 1])
        let multiPlan = try #require(try physicalInput(multiArgs))
        #expect(multiPlan.operation == "multi-drag" && multiPlan.operands == ["1", "0", "0", "1", "1", "1", "1", "0", "0"])
    }
    @Test func catalogHasUniqueNamesAndClosedObjectSchemas() throws {
        let definitions = MCPTools.definitions
        #expect(definitions.count == 45 + MCPTools.otherFamilies.count)
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
        let plan = try #require(try physicalInput(args))
        #expect(plan.operands == [text, "us"])
        let tap = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let tapped = try tap.command(["platform": "physical", "device": "phone", "x": 0.5, "y": 1])
        #expect(tapped == ["tap", "--device=phone", "--", "0.5", "1"])
        // Values that begin with '-' stay values and operands, so the
        // operation's own validation sees them unchanged.
        let negative = try tap.command(["platform": "simulator", "device": "11111111-2222-3333-4444-555555555555", "x": -0.5, "y": 0.5])
        let outside = try #require(throws: CommandFailure.self) { try request(negative) }
        #expect(outside.description == "Simulator input coordinates must be normalized numbers from 0 to 1.")
        let selector = try #require(MCPTools.definitions.first { $0.name == "press_element" })
        let dashed = try selector.command(["device": "phone", "by": "label", "text": "--dry-run", "pid": -3])
        #expect(dashed == ["press", "--device=phone", "--label=--dry-run", "--pid=-3"])
        let negativePID = try #require(throws: CommandFailure.self) { try CLI.invocation(dashed) }
        #expect(negativePID.description == "Native AX selector PID must be positive.")
        // index reaches the same parser as --index; the layout probe has no such field.
        for name in ["press_element", "scroll_to_element", "wait_for_element", "set_element_value"] {
            let tool = try #require(MCPTools.definitions.first { $0.name == name })
            #expect(tool.fields.contains { $0.name == "index" && !$0.required })
        }
        let detect = try #require(MCPTools.definitions.first { $0.name == "detect_keyboard_layout" })
        #expect(detect.fields.contains { $0.name == "index" && !$0.required })
        // detect-layout changes the field's value, so it cannot select by it.
        #expect(detect.fields.first { $0.name == "by" }?.choices == ["identifier", "label"])
        #expect(try selector.command(["device": "phone", "by": "value", "text": "Buscar"]) == ["press", "--device=phone", "--with-value=Buscar"])
        let indexed = try selector.command(["device": "phone", "by": "label", "text": "Username", "index": 2])
        #expect(indexed == ["press", "--device=phone", "--label=Username", "--index=2"])
        #expect(try CLI.invocation(indexed).request == .physicalInput(CoreDeviceInput(device: "phone", operation: "press-label", operands: ["Username", "--index", "2"])))
        let labelled = try selector.command(["device": "phone", "by": "label", "text": "--dry-run", "pid": 3])
        #expect(try CLI.invocation(labelled) == CLIInvocation(
            request: .physicalInput(CoreDeviceInput(device: "phone", operation: "press-label", operands: ["3", "--dry-run"])), dryRun: false, errorFormat: nil))
    }

    @Test func selectorToolsCarryTheMatchMode() throws {
        for name in ["press_element", "scroll_to_element", "wait_for_element", "set_element_value"] {
            let tool = try #require(MCPTools.definitions.first { $0.name == name })
            #expect(tool.fields.contains { $0.name == "match" && !$0.required && $0.choices == ["exact", "contains", "regex"] })
        }
        let detect = try #require(MCPTools.definitions.first { $0.name == "detect_keyboard_layout" })
        #expect(!detect.fields.contains { $0.name == "match" })
        let press = try #require(MCPTools.definitions.first { $0.name == "press_element" })
        let routed = try press.command(["device": "phone", "by": "label", "text": "row", "match": "contains", "index": 2])
        #expect(routed == ["press", "--device=phone", "--label=row", "--match=contains", "--index=2"])
        #expect(try CLI.invocation(routed).request == .physicalInput(CoreDeviceInput(device: "phone", operation: "press-label", operands: ["row", "--match", "contains", "--index", "2"])))
        #expect(throws: MCPError.self) { try press.command(["device": "phone", "by": "label", "text": "row", "match": "fuzzy"]) }
    }

    @Test func appActionLaunchCarriesItsOptions() throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "app_action" })
        let base: [String: Value] = ["platform": "physical", "device": "fixture-phone", "operation": "launch", "value": "com.example.app"]
        #expect(try definition.command(base) == ["launch", "--device=fixture-phone", "com.example.app"])
        let full = try definition.command(base.merging(["app_arguments": .array(["-ProbeList", "YES"]), "environment": .array(["A=1"]),
                                                        "language": "es", "locale": "es_ES", "relaunch": true]) { $1 })
        #expect(full == ["launch", "--device=fixture-phone", "--env=A=1", "--language=es", "--locale=es_ES", "--relaunch", "com.example.app", "--", "-ProbeList", "YES"])
        guard case .tool(let tool) = try request(full) else { Issue.record("app_action launch is not a tool request"); return }
        #expect(tool.command.arguments.suffix(7) == ["com.example.app", "-AppleLanguages", "(es)", "-AppleLocale", "es_ES", "-ProbeList", "YES"])
        let terminate = try definition.command(["platform": "physical", "device": "fixture-phone", "operation": "terminate", "value": "com.example.app"])
        guard case .tool(let ended) = try request(terminate) else { Issue.record("app_action terminate is not a tool request"); return }
        #expect(ended.bundleToResolve == "com.example.app")
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
        let plain = ["build-run", "--device=00000000-0000000000000000", "--", "A.xcodeproj", "A"]
        #expect(try definition.command(base) == plain)
        #expect(try definition.command(base.merging(["allow_provisioning_updates": false]) { $1 }) == plain)
        let flagged = try definition.command(base.merging(["allow_provisioning_updates": true, "allow_device_registration": true]) { $1 })
        #expect(flagged == ["build-run", "--device=00000000-0000000000000000", "--allow-provisioning-updates", "--allow-device-registration", "--", "A.xcodeproj", "A"])
        guard case .buildRun(let parsed) = try request(flagged) else { Issue.record("build_run is not a build-run request"); return }
        #expect(parsed.allowProvisioningUpdates && parsed.allowDeviceRegistration)
        #expect(throws: MCPError.self) { try definition.command(base.merging(["allow_provisioning_updates": "yes"]) { $1 }) }
        let simulator = try definition.command(base.merging(["platform": "simulator", "device": "11111111-2222-3333-4444-555555555555",
                                                             "allow_provisioning_updates": true]) { $1 })
        #expect(throws: CommandFailure.self) { try request(simulator) }
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
         ["physical", "fixture", "long-press", "0.5", "0.5", "1.0"]),
        ("pinch", ["device": Value.string("fixture"), "center_x": 0.5, "center_y": 0.5, "start_span": 0.2, "end_span": 0.5, "seconds": 0.6],
         ["physical", "fixture", "pinch", "0.5", "0.5", "0.2", "0.5", "0.6"]),
        ("multi_drag", ["device": Value.string("fixture"), "seconds": 0.5, "paths": [0.5, 0.25, 0.5, 0.1, 0.5, 0.75, 0.5, 0.9]],
         ["physical", "fixture", "multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]),
        ("multi_tap", ["device": Value.string("fixture"), "coordinates": [0.25, 0.5, 0.75, 0.5]],
         ["physical", "fixture", "multi-tap", "0.25", "0.5", "0.75", "0.5"]),
        ("perform_gesture", ["device": Value.string("fixture"), "sequence": .string(CLIParserTests.gesture)],
         ["physical", "fixture", "gesture", CLIParserTests.gesture])
    ]

    /// `expected` is what the CLI's parser hands the command service.
    @Test(arguments: physicalDefaults)
    func newOptionalPlatformsKeepThePhysicalRoute(_ name: String, _ arguments: [String: Value], _ expected: [String]) throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        let command = try definition.command(arguments)
        #expect(command.contains("--device=fixture"))
        #expect(summary(try request(command)) == expected)
        #expect(try definition.command(arguments.merging(["platform": "physical"]) { $1 }) == command)
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
        ("type_text", ["platform": Value.string("simulator"), "text": "Wi-Fi"], ["type", "Wi-Fi", "us"]),
        ("type_text", ["platform": Value.string("simulator"), "text": "Grüße", "layout": "german"], ["type", "Grüße", "german"]),
        ("pinch", ["platform": Value.string("simulator"), "center_x": 0.5, "center_y": 0.5, "start_span": 0.2, "end_span": 0.5, "seconds": 0.6],
         ["pinch", "0.5", "0.5", "0.2", "0.5", "0.6"]),
        ("multi_drag", ["platform": Value.string("simulator"), "seconds": 0.5, "paths": [0.5, 0.25, 0.5, 0.1, 0.5, 0.75, 0.5, 0.9]],
         ["multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]),
        ("multi_tap", ["platform": Value.string("simulator"), "coordinates": [0.3, 0.45, 0.5, 0.45, 0.7, 0.45]],
         ["multi-tap", "0.3", "0.45", "0.5", "0.45", "0.7", "0.45"]),
        ("multi_drag", ["platform": Value.string("simulator"), "seconds": 0.6, "paths": [0.3, 0.6, 0.3, 0.4, 0.5, 0.6, 0.5, 0.4, 0.7, 0.6, 0.7, 0.4]],
         ["multi-drag", "0.6", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4", "0.7", "0.6", "0.7", "0.4"]),
        ("perform_gesture", ["platform": Value.string("simulator"), "sequence": #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]}]}"#],
         ["gesture", #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]}]}"#]),
        ("set_element_value", ["platform": Value.string("simulator"), "by": "identifier", "text": "probe.text.field", "value": "mañana 🚀 中"],
         ["set-value-id", "probe.text.field", "mañana 🚀 中"]),
        ("set_element_value", ["platform": Value.string("simulator"), "by": "label", "text": "Field", "pid": 42, "value": "x"],
         ["set-value-label", "42", "Field", "x"])
    ]

    @Test func setElementValueDefaultsToThePhysicalRouteAndPlansWithoutADevice() async throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "set_element_value" })
        let args = try definition.command(["device": "fixture", "by": "label", "text": "Field", "pid": 42, "value": "mañana 🚀"])
        #expect(args == ["set-value", "--device=fixture", "--label=Field", "--pid=42", "--", "mañana 🚀"])
        #expect(summary(try request(args)) == ["physical", "fixture", "set-value-label", "42", "Field", "mañana 🚀"])
        #expect(!definition.readOnly && !CommandService.nativeObservations.contains("set-value-label"))
        let output = try await CommandService(readinessQuery: { _ in Issue.record("queried a device"); return Data() }).run(args, dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct" && plan["operation"] as? String == "set-value")
        #expect(plan["selector"] as? [String: String] == ["by": "label", "text": "Field"])
        #expect(plan["pid"] as? Int == 42 && plan["requestedUTF8Bytes"] as? Int == 12)
        // Operands are checked before any device contact.
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await CommandService(readinessQuery: { _ in Issue.record("queried a device"); return Data() })
                .run(["set-value", "--device=fixture", "--id=f", "--", "a\0b"])
        })
        #expect(failure.code == .usage && failure.description == "Native AX set-value text must be 1...65536 UTF-8 bytes without NUL.")
    }

    @Test(arguments: simulatorRoutes)
    func simulatorPlatformRoutesToTheSimulatorCommand(_ name: String, _ arguments: [String: Value], _ operands: [String]) throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        let args = try definition.command(arguments.merging(["device": .string(uuid)]) { $1 })
        #expect(args.contains("--simulator=\(uuid)"))
        let parsed = try #require(try simulatorInput(args))
        #expect(summary(.simulatorInput(parsed)) == ["simulator", uuid] + operands)
        #expect(parsed.operation == operands[0])
    }

    @Test(arguments: [("type_text", ["device": Value.string("fixture"), "text": "a"], ["physical", "fixture", "type", "a", "us"]),
                      ("get_ui_tree", ["device": Value.string("fixture")], ["physical", "fixture", "tree"])])
    func optionalPlatformDefaultsToPhysical(_ name: String, _ arguments: [String: Value], _ expected: [String]) throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == name })
        #expect(summary(try request(definition.command(arguments))) == expected)
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
        #expect(args == ["type", "--device=fixture", "--", "Hello!"])
        #expect(try physicalInput(args)?.operands == ["Hello!", "us"])
        let german = try definition.command(["device": "fixture", "text": "Grüße", "layout": "german"])
        #expect(german == ["type", "--device=fixture", "--layout=german", "--", "Grüße"])
        #expect(try physicalInput(german)?.operands == ["Grüße", "german"])
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
        let result = try await service.run(["tap", "0.5", "0.5", "--device", "phone"], dryRun: true)
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
