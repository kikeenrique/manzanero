import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct PhysicalTreeTests {
    @Test func physicalPIDAndPairingAreValidatedBeforeBackendExecution() throws {
        let plan = try #require(try DeviceCommand.parse(["--pairing-file", "tmp/fixture.pairing.plist", "physical", "fixture", "tree", "123"]))
        #expect(plan.arguments == ["appledevices-idevice", "--pairing-file", "tmp/fixture.pairing.plist", "fixture", "tree", "123"])
        #expect(try DeviceCommand.parse(["physical", "fixture", "tree"])?.arguments == ["appledevices-idevice", "fixture", "tree"])
        for operands in [["0"], ["-1"], ["2147483648"], ["nan"], ["1", "2"]] {
            #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", "fixture", "tree"] + operands) }
        }
    }

    @Test func mcpTreePreservesSimulatorDefaultAndAllowsForegroundPhysicalSelection() throws {
        let tree = try #require(MCPTools.definitions.first { $0.name == "get_ui_tree" })
        #expect(try tree.command(["device": "simulator-fixture"]) == ["simulator", "simulator-fixture", "tree"])
        let args = try tree.command(["device": "phone-fixture", "platform": "physical", "pid": 123])
        #expect(args == ["physical", "phone-fixture", "tree", "123"])
        #expect(try DeviceCommand.parse(args)?.arguments.suffix(2) == ["tree", "123"])
        #expect(try DeviceCommand.parse(tree.command(["device": "fixture", "platform": "physical"]))?.arguments.last == "tree")
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(tree.command(["device": "fixture", "pid": 123])) }
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
