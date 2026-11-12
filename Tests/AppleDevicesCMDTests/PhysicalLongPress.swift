import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct PhysicalLongPressTests {
    @Test func validatesHoldBeforeDiscoveryAndUsesExistingNativeHelper() throws {
        let fixture = CoreDeviceInputTests()
        let command = try fixture.input(["long-press", "0.25", "0.75", "0.8"])
        #expect(try command.actionPlan(fixture.uuid, surface: "257").arguments.suffix(5) == ["cd_uhid_long", "257", "0.25", "0.75", "0.8"])
        #expect(throws: CommandFailure.self) { try command.actionPlan(fixture.uuid, surface: nil) }
        for values in [["0", "0"], ["nan", "0", "1"], ["0", "inf", "1"], ["-0.1", "0", "1"], ["0", "1.1", "1"],
                       ["0", "0", "nan"], ["0", "0", "0.099"], ["0", "0", "10.001"], ["0", "0", "1", "extra"]] {
            #expect(throws: CommandFailure.self) { try fixture.input(["long-press"] + values) }
        }
        for seconds in ["0.1", "10"] { _ = try fixture.input(["long-press", "0", "1", seconds]) }
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["physical", fixture.udid, "long-press", "0.5", "0.5", "1"]) }
    }

    @Test func discoversOnceDispatchesOnceAndKeepsUnverifiedReceipt() throws {
        let fixture = CoreDeviceInputTests()
        let command = try fixture.input(["long-press", "0.25", "0.75", "0.8"])
        var phases: [String] = []
        let data = try command.execute { plan in
            if plan.arguments.contains("details") { phases.append("identity"); return try fixture.details() }
            if plan.arguments.contains("cd_connected_descriptors_async_raw") {
                phases.append("discover")
                return Data("connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"".utf8)
            }
            phases.append("hold")
            #expect(plan.arguments.suffix(5) == ["cd_uhid_long", "257", "0.25", "0.75", "0.8"])
            return Data()
        }
        #expect(phases == ["identity", "discover", "hold"])
        let result = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["operation"] as? String == "long-press")
        #expect(result["verified"] as? Bool == false)
        #expect(result["releaseVerified"] as? Bool == false)
        #expect(result["holdSeconds"] as? Double == 0.8)
    }

    @Test(arguments: ["disabled", "identity", "discovery", "dispatch"])
    func failuresStopAtTheirPhaseAndNeverReplay(failure: String) throws {
        let fixture = CoreDeviceInputTests()
        let command = try fixture.input(["long-press", "0.25", "0.75", "0.8"])
        var dispatches = 0
        do {
            _ = try command.execute { plan in
                if plan.arguments.contains("details") {
                    return try fixture.details(mode: failure == "disabled" ? "disabled" : "enabled", hardware: failure == "identity" ? "different" : nil)
                }
                if plan.arguments.contains("cd_connected_descriptors_async_raw") {
                    return failure == "discovery" ? Data() : Data("connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"".utf8)
                }
                dispatches += 1
                throw CommandFailure(description: "fixture dispatch failure")
            }
            Issue.record("Expected long-press failure")
        } catch {
            if failure == "dispatch" { #expect(String(describing: error).contains("UI effect and contact release are unknown")) }
        }
        #expect(dispatches == (failure == "dispatch" ? 1 : 0))
    }

    @Test func MCPAndDryRunShareNativeValidationWithoutDeviceQueries() async throws {
        let fixture = CoreDeviceInputTests()
        let tool = try #require(MCPTools.definitions.first { $0.name == "long_press" })
        #expect(tool.readOnly == false)
        let args = try tool.command(["device": .string(fixture.udid), "x": 0.25, "y": 0.75, "seconds": 0.8])
        #expect(try CoreDeviceInput.parse(args)?.operation == "long-press")
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let result = try await service.execute(args, dryRun: true)
        #expect(String(decoding: result.data, as: UTF8.self).contains("coredevice-direct"))
    }
}
