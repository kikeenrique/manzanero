import Foundation
import MCP
import Testing
@testable import Manzanero

struct PhysicalPressTests {
    @Test func validatesPIDAndPreservesLiteralSelectorBeforeBackendExecution() throws {
        let selector = "--literal $(text); botón"
        func native(_ operation: String, _ operands: [String]) throws -> CoreDeviceInput {
            try CoreDeviceInput.validated(device: "fixture", operation: operation, operands: operands)
        }
        #expect(try native("press-label", ["123", selector]).operands == ["123", selector])
        #expect(try physicalInput(["press", "--label", selector, "--pid", "123", "--device", "fixture"])?.operands == ["123", selector])
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_element" })
        let args = try tool.command(["device": "fixture", "pid": 123, "by": "identifier", "text": "fixture.button"])
        #expect(args == ["press", "--device=fixture", "--id=fixture.button", "--pid=123"])
        #expect(summary(try request(args)) == ["physical", "fixture", "press-id", "123", "fixture.button"])
        let foreground = try tool.command(["device": "fixture", "by": "label", "text": "Back"])
        #expect(summary(try request(foreground)) == ["physical", "fixture", "press-label", "Back"])
        #expect(try physicalInput(foreground)?.operation == "press-label")
        #expect(!tool.readOnly)
        for values in [["0","button"], ["-1","button"], ["2147483648","button"], ["123",""], ["123", "a\0b"], ["123",String(repeating:"é",count:2049)]] {
            #expect(throws: CommandFailure.self) { try native("press-id", values) }
        }
    }

    @Test func disabledModeBlocksAXPressAndDryRunDoesNotDispatch() async throws {
        let data = try DeviceReadinessTests().fixture(mode: "disabled")
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.run(["press", "--label", "Button", "--pid", "123", "--device", "fixture"])
            Issue.record("Disabled device reached AX press")
        } catch { #expect(String(describing:error).contains("Developer Mode is disabled")) }
        let output = try await service.run(["press", "--label", "Button", "--pid", "123", "--device", "fixture"], dryRun:true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct")
        #expect(plan["operation"] as? String == "press")
        #expect((plan["selector"] as? [String: String]) == ["by": "label", "text": "Button"])
    }
}
