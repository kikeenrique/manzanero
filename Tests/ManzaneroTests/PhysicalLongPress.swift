import Foundation
import MCP
import Testing
@testable import Manzanero

struct PhysicalLongPressTests {
    @Test func validatesHoldBeforeDispatch() throws {
        let fixture = CoreDeviceInputTests()
        let command = try fixture.input(["long-press", "0.25", "0.75", "0.8"])
        #expect(command.operands == ["0.25", "0.75", "0.8"])
        for values in [["0", "0"], ["nan", "0", "1"], ["0", "inf", "1"], ["-0.1", "0", "1"], ["0", "1.1", "1"],
                       ["0", "0", "nan"], ["0", "0", "0.099"], ["0", "0", "10.001"], ["0", "0", "1", "extra"]] {
            #expect(throws: CommandFailure.self) { try fixture.input(["long-press"] + values) }
        }
        for seconds in ["0.1", "10"] { _ = try fixture.input(["long-press", "0", "1", seconds]) }
        #expect(throws: CommandFailure.self) { try DeviceCommand.plan(physical: true, device: fixture.udid, operation: "long-press", operands: ["0.5", "0.5", "1"]) }
    }

    @Test func MCPAndDryRunShareNativeValidationWithoutDeviceQueries() async throws {
        let fixture = CoreDeviceInputTests()
        let tool = try #require(MCPTools.definitions.first { $0.name == "long_press" })
        #expect(tool.readOnly == false)
        let args = try tool.command(["device": .string(fixture.udid), "x": 0.25, "y": 0.75, "seconds": 0.8])
        #expect(try physicalInput(args)?.operation == "long-press")
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let result = try await service.run(args, dryRun: true)
        #expect(String(decoding: result.data, as: UTF8.self).contains("coredevice-direct"))
    }
}
