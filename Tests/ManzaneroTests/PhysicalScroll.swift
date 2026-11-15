import Foundation
import MCP
import Testing
@testable import Manzanero

struct PhysicalScrollTests {
    @Test(arguments: ["scroll-id", "scroll-label"])
    func validatesTargetsAndPreservesLiteralSelectors(operation: String) throws {
        let selector = "--literal $(text); botón"
        func native(_ values: [String]) throws -> CoreDeviceInput? {
            try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(["physical", "fixture", operation] + values))
        }
        #expect(try native([selector])?.operands == [selector])
        #expect(try native(["123", selector])?.operands == ["123", selector])
        for values in [[], ["0", selector], ["2147483648", selector], [""], ["a\0b"], [String(repeating: "é", count: 2049)], ["1", "2", selector]] {
            #expect(throws: CommandFailure.self) { try native(values) }
        }
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["simulator", "11111111-2222-3333-4444-555555555555", operation, selector]) }
    }

    @Test func sharedMCPRouteIsMutatingAndAllowsOptionalPID() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "scroll_to_element" })
        #expect(tool.readOnly == false)
        let args = try tool.command(["device": "fixture", "by": "label", "text": "Exact row"])
        #expect(args == ["physical", "fixture", "scroll-label", "Exact row"])
        let explicit = try tool.command(["device": "fixture", "by": "identifier", "text": "fixture.row", "pid": 123])
        #expect(explicit == ["physical", "fixture", "scroll-id", "123", "fixture.row"])
    }

    @Test func disabledModePreventsScrollAndDryRunQueriesNothing() async throws {
        let data = try DeviceReadinessTests().fixture(mode: "disabled")
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.execute(["physical", "fixture", "scroll-label", "Row"])
            Issue.record("Disabled device reached scroll backend")
        } catch { #expect(String(describing: error).contains("Developer Mode is disabled")) }
        let dry = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return data })
        let output = try await dry.execute(["physical", "fixture", "scroll-id", "fixture.row"], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["backend"] as? String == "coredevice-direct")
        #expect(plan["operation"] as? String == "scroll-to-visible")
        #expect((plan["selector"] as? [String: String]) == ["by": "identifier", "text": "fixture.row"])
    }
}
