import Foundation
import MCP
import Testing
@testable import Manzanero

struct NativeGestureSequenceTests {
    let doubleTap = #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.25,"y":0.75}]},{"ms":60,"touches":[]},{"ms":180,"touches":[{"id":0,"x":0.25,"y":0.75}]},{"ms":240,"touches":[]}]}"#

    @Test func repeatedContactKeepsCoordinatesAcrossRelease() throws {
        let sequence = try NativeGestureSequence(json: doubleTap)
        #expect(sequence.times == [0, 60, 180, 240])
        #expect(sequence.contactCount == 1)
        #expect(sequence.reports.map { $0[3] } == [0xc0, 0, 0xc0, 0])
        #expect(sequence.reports.allSatisfy { Array($0[4..<8]) == [0, 64, 255, 191] })
        #expect(try CoreDeviceInputTests().input(["gesture", doubleTap]).operands == [doubleTap])
    }

    @Test func independentContactsArriveLiftAndMoveWithStableSlots() throws {
        let json = #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0,"y":1}]},{"ms":10,"touches":[{"id":1,"x":1,"y":0},{"id":0,"x":0.5,"y":0.5}]},{"ms":20,"touches":[{"id":1,"x":0.8,"y":0.2}]},{"ms":30,"touches":[]}]}"#
        let sequence = try NativeGestureSequence(json: json)
        #expect(sequence.contactCount == 2)
        #expect(sequence.reports.map { $0[3] } == [0xc0, 0xc0, 0, 0])
        #expect(sequence.reports.map { $0[8] } == [1, 0xc1, 0xc1, 1])
        #expect(Array(sequence.reports[1][4..<8]) == Array(sequence.reports[2][4..<8]))
        #expect(Array(sequence.reports[2][9..<13]) == Array(sequence.reports[3][9..<13]))
        #expect(sequence.reports.allSatisfy { $0.count == 58 && $0[1] == 2 && $0[40] == 2 })
    }

    @Test func rejectsInvalidWholeSchedulesBeforeDeviceDiscovery() throws {
        let invalid = ["{}", "[]", "{", #"{"frames":[]}"#,
            doubleTap.replacingOccurrences(of: #""ms":0"#, with: #""ms":1"#),
            doubleTap.replacingOccurrences(of: #""ms":180"#, with: #""ms":60"#),
            doubleTap.replacingOccurrences(of: #""ms":240"#, with: #""ms":10001"#),
            doubleTap.replacingOccurrences(of: #""id":0"#, with: #""id":2"#),
            doubleTap.replacingOccurrences(of: #""x":0.25"#, with: #""x":1.1"#),
            doubleTap.replacingOccurrences(of: #""y":0.75"#, with: #""y":-0.1"#),
            doubleTap.replacingOccurrences(of: #""touches":[]"#, with: #""touches":[{"id":0,"x":0,"y":0}]"#),
            doubleTap.replacingOccurrences(of: #"{"id":0,"x":0.25,"y":0.75}"#, with: #"{"id":0,"x":0,"y":0},{"id":0,"x":1,"y":1}"#),
            String(repeating: "x", count: 65537)]
        for json in invalid {
            #expect(throws: CommandFailure.self) { try CoreDeviceInputTests().input(["gesture", json]) }
        }
    }

    @Test func supportsBoundedFrameCountAndFiveSlots() throws {
        let touches = (0..<5).map { ["id": $0, "x": 0, "y": 1] }
        let sparse: [[String: Any]] = (0..<512).map { ["ms": $0, "touches": $0 == 0 ? [["id":0,"x":0,"y":0]] : []] }
        let small = String(decoding: try JSONSerialization.data(withJSONObject: ["frames": sparse]), as: UTF8.self)
        #expect(try NativeGestureSequence(json: small).times.count == 512)
        let tooMany = sparse + [["ms":512,"touches":[]]]
        #expect(throws: CommandFailure.self) { try NativeGestureSequence(json: String(decoding: JSONSerialization.data(withJSONObject: ["frames":tooMany]), as: UTF8.self)) }
        let oversized = doubleTap + String(repeating: " ", count: 65536)
        #expect(throws: CommandFailure.self) { try NativeGestureSequence(json: oversized) }
        let five = String(decoding: try JSONSerialization.data(withJSONObject: ["frames":[["ms":0,"touches":touches],["ms":10000,"touches":[]]]]), as: UTF8.self)
        #expect(try NativeGestureSequence(json: five).contactCount == 5)
    }

    @Test func sharedMCPRouteAndDryRunUseTheDirectBackend() async throws {
        let fixture = CoreDeviceInputTests()
        let tool = try #require(MCPTools.definitions.first { $0.name == "perform_gesture" })
        #expect(tool.readOnly == false)
        let args = try tool.command(["device": .string(fixture.udid), "sequence": .string(doubleTap)])
        let command = try #require(try CoreDeviceInput.parse(args))
        #expect(command.operands == [doubleTap])
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("coredevice-direct"))
    }
}
