import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct NativeTouchFramesTests {
    @Test(arguments: 2...5)
    func coordinatedFramesKeepEveryIdentityEndpointsAndRelease(count: Int) throws {
        let operands = ["0.5"] + Array(repeating: ["0", "1", "1", "0"], count: count).flatMap { $0 }
        let gesture = try NativeTouchFrames(device: "fixture", operation: "multi-drag", operands: operands)
        #expect(gesture.milliseconds == 500)
        #expect(gesture.reports.count == 32)
        for (index, report) in gesture.reports.enumerated() {
            #expect(report.count == 58)
            #expect(Array(report.prefix(3)) == [9, UInt8(count), 5])
            for id in 0..<count {
                #expect(report[3 + id * 5] == UInt8(id) | (index == 31 ? 0 : 0xc0))
            }
        }
        for id in 0..<count {
            let offset = 4 + id * 5
            #expect(Array(gesture.reports[0][offset..<(offset + 4)]) == [0, 0, 255, 255])
            #expect(Array(gesture.reports[15][offset..<(offset + 4)]) == [255, 127, 0, 128])
            #expect(Array(gesture.reports[30][offset..<(offset + 4)]) == [255, 255, 0, 0])
            #expect(Array(gesture.reports[31][offset..<(offset + 4)]) == [255, 255, 0, 0])
        }
        #expect(gesture.arguments.count == 33)
        #expect(gesture.arguments.dropFirst().allSatisfy { $0.count == 116 })
    }

    @Test func pinchUsesValidatedSharedPlannerAndNativeSurface() throws {
        let fixture = CoreDeviceInputTests()
        let pinch = try fixture.input(["pinch", "0.5", "0.5", "0.2", "0.6", "0.5"])
        let plan = try pinch.actionPlan(fixture.uuid, surface: "257")
        #expect(Array(plan.arguments.suffix(35).prefix(3)) == ["cd_multitouch", "257", "500"])
        let frames = try NativeTouchFrames(device: "fixture", operation: "pinch", operands: pinch.operands)
        let x = { (f: Int, id: Int) in
            Int(frames.reports[f][4 + id * 5]) | Int(frames.reports[f][5 + id * 5]) << 8
        }
        #expect(x(0, 0) > x(30, 0))
        #expect(x(0, 1) < x(30, 1))
        for operands in [["0.5", "0.5", "0.2", "0.2", "0.5"], ["0.1", "0.5", "0.2", "0.6", "0.5"], ["0.5", "0.5", "0.2", "0.6", "nan"]] {
            #expect(throws: CommandFailure.self) { try fixture.input(["pinch"] + operands) }
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "pinch" })
        let arguments: [String: MCP.Value] = ["device": .string(fixture.udid), "backend": .string("coredevice"),
            "center_x": .double(0.5), "center_y": .double(0.5), "start_span": .double(0.2), "end_span": .double(0.6), "seconds": .double(0.5)]
        #expect(try tool.command(arguments).prefix(2) == ["--physical-backend", "coredevice"])
        let multi = try #require(MCPTools.definitions.first { $0.name == "multi_drag" })
        let multiArgs = try multi.command(["device": .string(fixture.udid), "backend": "coredevice", "seconds": 0.5,
            "paths": .array([0.2, 0.3, 0.4, 0.3, 0.8, 0.3, 0.6, 0.3])])
        #expect(try CoreDeviceInput.parse(multiArgs)?.operation == "multi-drag")
    }
}
