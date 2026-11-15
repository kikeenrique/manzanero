import Foundation
import MCP
import Testing
@testable import Manzanero

struct NativeTouchFramesTests {
    @Test(arguments: 1...5)
    func reportEncodesEverySlotPositionAndActiveState(count: Int) {
        let positions = (0..<count).map { [$0 * 0x0101, 0xffff - $0] }
        let active = Set((0..<count).filter { $0.isMultiple(of: 2) })
        let report = NativeTouchFrames.report(positions: positions, active: active)
        #expect(report.count == 58)
        #expect(Array(report.prefix(3)) == [9, UInt8(count), 5])
        #expect(report[40] == 2)
        for id in 0..<count {
            let offset = 3 + id * 5
            #expect(report[offset] == UInt8(id) | (active.contains(id) ? 0xc0 : 0))
            #expect(Array(report[(offset + 1)...(offset + 4)]) == [UInt8(positions[id][0] & 255), UInt8(positions[id][0] >> 8),
                                                                   UInt8(positions[id][1] & 255), UInt8(positions[id][1] >> 8)])
        }
    }

    @Test func pinchAndMultiDragShareNativeValidationAndMCPRouting() throws {
        let fixture = CoreDeviceInputTests()
        #expect(try fixture.input(["pinch", "0.5", "0.5", "0.2", "0.6", "0.5"]).operation == "pinch")
        for operands in [["0.5", "0.5", "0.2", "0.2", "0.5"], ["0.1", "0.5", "0.2", "0.6", "0.5"], ["0.5", "0.5", "0.2", "0.6", "nan"]] {
            #expect(throws: CommandFailure.self) { try fixture.input(["pinch"] + operands) }
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "pinch" })
        let arguments: [String: MCP.Value] = ["device": .string(fixture.udid),
            "center_x": .double(0.5), "center_y": .double(0.5), "start_span": .double(0.2), "end_span": .double(0.6), "seconds": .double(0.5)]
        let pinchArgs = try tool.command(arguments)
        #expect(Array(pinchArgs.prefix(3)) == ["physical", fixture.udid, "pinch"])
        #expect(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(pinchArgs))?.operation == "pinch")
        let multi = try #require(MCPTools.definitions.first { $0.name == "multi_drag" })
        let multiArgs = try multi.command(["device": .string(fixture.udid), "seconds": 0.5,
            "paths": .array([0.2, 0.3, 0.4, 0.3, 0.8, 0.3, 0.6, 0.3])])
        #expect(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(multiArgs))?.operation == "multi-drag")
    }
}
