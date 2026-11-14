import AppleDeviceBridge
import Foundation
import MCP
import Testing
@testable import Manzanero

struct DirectTwoContactTouchTests {
    func input(_ operands: [String]) throws -> CoreDeviceInput { try CoreDeviceInputTests().input(operands) }
    func display(_ rotation: String = "rot0") throws -> DirectTouchDisplay { try DirectTouchDisplay(DirectPhysicalTouchTests().display(rotation: rotation)) }

    @Test func pinchInterpolatesBothContactsAndLiftsAtTheirFinalPositions() throws {
        let command = try input(["pinch", "0.5", "0.4", "0.2", "0.6", "0.5"])
        let plan = try DirectPhysicalTouch.plan(command, display: display())
        #expect(plan.count == 32)
        #expect(plan.first?.x == 0.4 && plan.first?.second?.x == 0.6)
        #expect(abs(try #require(plan.last?.x) - 0.2) < 0.000001)
        #expect(abs(try #require(plan.last?.second?.x) - 0.8) < 0.000001)
        #expect(plan.last?.y == 0.4 && plan.last?.second?.y == 0.4)
        #expect(plan.first?.phase == 0 && plan.last?.phase == 2)
        #expect(plan.last?.nanoseconds == 501_000_000)
        #expect(plan.allSatisfy { $0.second != nil })
        #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.nanoseconds < $1.nanoseconds })
        let rotated = try DirectPhysicalTouch.plan(command, display: display("rot90"))
        #expect(rotated.first?.x == 0.4 && rotated.first?.second?.x == 0.4)
        #expect(abs(try #require(rotated.first?.y) - 0.6) < 0.000001)
        #expect(abs(try #require(rotated.first?.second?.y) - 0.4) < 0.000001)
    }

    @Test func coordinatedDragPreservesSlotOrderAndRejectsBetweenFrameCrossing() throws {
        let command = try input(["multi-drag", "1", "0.1", "0.2", "0.2", "0.8", "0.7", "0.3", "0.8", "0.9"])
        let plan = try DirectPhysicalTouch.plan(command, display: display())
        #expect(plan.first?.x == 0.1 && plan.first?.second?.x == 0.7)
        #expect(plan.last?.x == 0.2 && plan.last?.second?.x == 0.8)
        let crossing = try input(["multi-drag", "1", "0.1", "0.5", "0.7", "0.5", "0.7", "0.5", "0.2", "0.5"])
        #expect(throws: CommandFailure.self) { try DirectPhysicalTouch.plan(crossing, display: display()) }
    }

    @Test func threeContactInputFailsBeforeAnyDeviceQuery() throws {
        let command = try input(["multi-drag", "1", "0.1", "0.1", "0.2", "0.1", "0.3", "0.3", "0.4", "0.3", "0.5", "0.5", "0.6", "0.5"])
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTouch.execute(command, query: { _ in Issue.record("Unsupported contact count queried device"); return Data() }, send: { _, _, _ in Issue.record("Unsupported contact count sent input") })
        }
    }

    @Test func mcpAndDefaultDryRunRouteToDirectBackendWithoutQueries() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "pinch" })
        let args = try tool.command(["device": .string(CoreDeviceInputTests().udid), "center_x": 0.5, "center_y": 0.4, "start_span": 0.2, "end_span": 0.6, "seconds": 0.5])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let result = try await service.execute(args, dryRun: true)
        #expect(String(decoding: result.data, as: UTF8.self).contains("coredevice-direct"))
    }

    @Test func cBoundaryRejectsMalformedSecondContactsBeforeOpeningAConnection() {
        let first = [ADCTouchSample(nanoseconds: 0, x: 0.2, y: 0.3, phase: 0), ADCTouchSample(nanoseconds: 10, x: 0.2, y: 0.3, phase: 2)]
        for point in [ADCTouchPoint(x: .nan, y: 0.5), ADCTouchPoint(x: 1.1, y: 0.5), ADCTouchPoint(x: 0.2, y: 0.3)] {
            let second = [point, point]
            var error = [CChar](repeating: 0, count: 1024)
            let status = first.withUnsafeBufferPointer { first in
                second.withUnsafeBufferPointer { ADCPerformTwoContactTouch("invalid", "invalid", first.baseAddress, $0.baseAddress, first.count, nil, &error, error.count) }
            }
            #expect(status != 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("second contact"))
        }
    }
}
