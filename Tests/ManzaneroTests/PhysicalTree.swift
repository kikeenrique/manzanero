import Foundation
import MCP
import Testing
@testable import Manzanero

struct PhysicalTreeTests {
    func native(_ operands: [String]) throws -> CoreDeviceInput {
        try CoreDeviceInput.validated(device: "fixture", operation: "tree", operands: operands)
    }

    @Test func physicalPIDIsValidatedBeforeNativeExecution() throws {
        #expect(try native(["123"]).operands == ["123"])
        #expect(try native([]).operands == [])
        for operands in [["0"], ["-1"], ["2147483648"], ["nan"], ["1", "2"]] {
            #expect(throws: CommandFailure.self) { try native(operands) }
        }
    }

    @Test func mcpTreeDefaultsToPhysicalAndAllowsForegroundSelection() throws {
        let tree = try #require(MCPTools.definitions.first { $0.name == "get_ui_tree" })
        #expect(try tree.command(["device": "phone-fixture"]) == ["tree", "--device=phone-fixture"])
        #expect(try tree.command(["device": "simulator-fixture", "platform": "simulator"]) == ["tree", "--simulator=simulator-fixture"])
        let args = try tree.command(["device": "phone-fixture", "platform": "physical", "pid": 123])
        #expect(summary(try request(args)) == ["physical", "phone-fixture", "tree", "123"])
        #expect(try physicalInput(args)?.operands == ["123"])
        #expect(try physicalInput(tree.command(["device": "fixture", "platform": "physical"]))?.operation == "tree")
        // A simulator tree needs a simulator UUID.
        #expect(throws: CommandFailure.self) { try request(tree.command(["device": "fixture", "platform": "simulator"])) }
        #expect(throws: CommandFailure.self) { try request(tree.command(["device": "fixture", "platform": "simulator", "pid": 123])) }
        #expect(throws: MCPError.self) { try tree.command(["device": "fixture", "platform": "physical", "pid": .double(1.5)]) }
        #expect(tree.readOnly)
    }

    @Test func disabledDeveloperModeStopsPhysicalTreeQuery() async throws {
        let data = try DeviceReadinessTests().fixture(mode: "disabled")
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.run(["tree", "--pid", "123", "--device", "fixture"])
            Issue.record("Disabled device reached AX tree backend")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
    }
}
