import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct PhysicalPressTests {
    @Test func validatesPIDAndPreservesLiteralSelectorBeforeBackendExecution() throws {
        let selector = "--literal $(text); botón"
        let plan = try #require(try DeviceCommand.parse(["physical", "fixture", "press-label", "123", selector]))
        #expect(plan.arguments == ["appledevices-idevice", "fixture", "press-label", "123", selector])
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_element" })
        let args = try tool.command(["device": "fixture", "pid": 123, "by": "identifier", "text": "fixture.button"])
        #expect(args == ["physical", "fixture", "press-id", "123", "fixture.button"])
        let foreground = try tool.command(["device": "fixture", "by": "label", "text": "Back"])
        #expect(foreground == ["physical", "fixture", "press-label", "Back"])
        #expect(try DeviceCommand.parse(foreground)?.arguments.suffix(2) == ["press-label", "Back"])
        #expect(!tool.readOnly)
        for values in [["0","button"], ["-1","button"], ["2147483648","button"], ["123",""], ["123", "a\0b"], ["123",String(repeating:"é",count:2049)]] {
            #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "fixture", "press-id"] + values) }
        }
    }

    @Test func disabledModeBlocksAXPressAndDryRunDoesNotDispatch() async throws {
        let data = try DeviceReadinessTests().fixture(mode: "disabled")
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.execute(["physical", "fixture", "press-label", "123", "Button"])
            Issue.record("Disabled device reached AX press")
        } catch { #expect(String(describing:error).contains("Developer Mode is disabled")) }
        let output = try await service.execute(["physical", "fixture", "press-label", "123", "Button"], dryRun:true)
        #expect(String(decoding:output.data,as:UTF8.self).contains("press-label"))
    }
}
