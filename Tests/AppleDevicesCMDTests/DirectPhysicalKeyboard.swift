import AppleDeviceBridge
import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalKeyboardTests {
    @Test(arguments: [("return", UInt64(40)), ("escape", 41), ("backspace", 42), ("tab", 43), ("space", 44),
                      ("right", 79), ("left", 80), ("down", 81), ("up", 82)])
    func mapsNamedKeysToOneValidatedDownUpDispatch(_ name: String, _ usage: UInt64) throws {
        let command = try CoreDeviceInputTests().input(["key", name])
        var queries = 0, sends = 0
        let output = try DirectPhysicalKeyboard.execute(command, query: { plan in
            queries += 1
            #expect(plan.executable == "/usr/bin/xcrun" && plan.arguments.contains("details"))
            return try DirectPhysicalInputTests().details()
        }, send: { key in
            sends += 1
            #expect(queries == 1)
            #expect(key == .init(uuid: CoreDeviceInputTests().uuid, version: "651.32", name: name, usage: usage))
        })
        #expect(sends == 1)
        let result = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-direct")
        #expect(result["usage"] as? UInt64 == usage)
        #expect(result["key"] as? String == name)
        #expect(result["verified"] as? Bool == false && result["releaseVerified"] as? Bool == false)
    }

    @Test func readinessIdentityAndInvalidKeyStopBeforeDispatch() throws {
        let command = try CoreDeviceInputTests().input(["key", "backspace"])
        for metadata in [try DirectPhysicalInputTests().details(mode: "disabled"), try DirectPhysicalInputTests().details(hardware: "other"), try DirectPhysicalInputTests().details(version: "bad")] {
            #expect(throws: CommandFailure.self) {
                try DirectPhysicalKeyboard.execute(command, query: { _ in metadata }, send: { _ in Issue.record("Invalid identity/readiness sent a key") })
            }
        }
        let invalid = CoreDeviceInput(device: "fixture", operation: "key", operands: ["unknown"])
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalKeyboard.execute(invalid, query: { _ in Issue.record("Invalid key queried device"); return Data() }, send: { _ in Issue.record("Invalid key sent input") })
        }
        var sends = 0
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalKeyboard.execute(command, query: { _ in try DirectPhysicalInputTests().details() }, send: { _ in sends += 1; throw CommandFailure(description: "fixture failure") })
        }
        #expect(sends == 1)
    }

    @Test func mcpDefaultKeyDryRunUsesDirectBackendWithoutDeviceQuery() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_key" })
        let args = try tool.command(["device": .string(CoreDeviceInputTests().udid), "key": "backspace"])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let output = try await service.execute(args, dryRun: true)
        let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct")
        #expect(plan["operation"] as? String == "key")
        #expect(plan["executable"] == nil)
    }

    @Test func cBoundaryRejectsUnsupportedKeyUsagesBeforeFrameworkAccess() {
        for usage: UInt64 in [0, 4, 39, 45, 78, 83, 255, .max] {
            var error = [CChar](repeating: 0, count: 1024)
            #expect(ADCPressKeyboardKey("invalid", "invalid", usage, nil, &error, error.count) != 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("Unsupported direct keyboard usage"))
        }
    }
}
