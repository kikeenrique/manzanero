import Foundation
import MCP
import Testing
@testable import Manzanero

struct PhysicalTreeTests {
    func native(_ args: [String]) throws -> CoreDeviceInput? {
        try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args))
    }

    @Test func physicalPIDIsValidatedBeforeNativeExecution() throws {
        #expect(try native(["physical", "fixture", "tree", "123"])?.operands == ["123"])
        #expect(try native(["physical", "fixture", "tree"])?.operands == [])
        for operands in [["0"], ["-1"], ["2147483648"], ["nan"], ["1", "2"]] {
            #expect(throws: CommandFailure.self) { try native(["physical", "fixture", "tree"] + operands) }
        }
    }

    @Test func mcpTreeDefaultsToPhysicalAndAllowsForegroundSelection() throws {
        let tree = try #require(MCPTools.definitions.first { $0.name == "get_ui_tree" })
        #expect(try tree.command(["device": "phone-fixture"]) == ["physical", "phone-fixture", "tree"])
        #expect(try tree.command(["device": "simulator-fixture", "platform": "simulator"]) == ["simulator", "simulator-fixture", "tree"])
        let args = try tree.command(["device": "phone-fixture", "platform": "physical", "pid": 123])
        #expect(args == ["physical", "phone-fixture", "tree", "123"])
        #expect(try native(args)?.operands == ["123"])
        #expect(try native(tree.command(["device": "fixture", "platform": "physical"]))?.operation == "tree")
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(tree.command(["device": "fixture", "platform": "simulator"])) }
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(tree.command(["device": "fixture", "platform": "simulator", "pid": 123])) }
        #expect(throws: MCPError.self) { try tree.command(["device": "fixture", "platform": "physical", "pid": .double(1.5)]) }
        #expect(tree.readOnly)
    }

    @Test func disabledDeveloperModeStopsPhysicalTreeQuery() async throws {
        let data = try DeviceReadinessTests().fixture(mode: "disabled")
        let service = CommandService(readinessQuery: { _ in data })
        do {
            _ = try await service.execute(["physical", "fixture", "tree", "123"])
            Issue.record("Disabled device reached AX tree backend")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
    }
}
