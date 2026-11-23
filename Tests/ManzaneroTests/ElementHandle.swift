import Foundation
import MCP
import Testing
@testable import Manzanero

/// A node's `handle` and `--handle`: the same live element in a fresh
/// snapshot, never a field that happens to read the same.
struct ElementHandleTests {
    typealias Value = AccessibilityArchiveValue

    private func token(_ id: UInt64, pid: Int32 = 42) -> Value {
        .object(className: "AXPTranslationObject", fields: ["pid": .signed(Int64(pid)), "objectID": .unsigned(id),
            "isApplicationElement": .boolean(id == 1), "didPopuldateAppInfo": .boolean(true),
            "rawElementData": .data(Data([0x91])), "bridgeDelegateToken": .null])
    }

    private func record(_ id: UInt64, label: String? = nil, children: [Value] = []) -> Value {
        .dictionary(["UIAccessibilitySnapshotKeyElement": token(id),
            "UIAccessibilitySnapshotKeyAttributes": .dictionary(label.map { ["2001": .string($0)] } ?? [:]),
            "UIAccessibilitySnapshotKeyChildren": .array(children),
            "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(UInt64(children.count))])
    }

    @Test func aHandleNamesTheProcessAndObjectAndReadsBack() throws {
        let handle = ElementHandle(pid: 412, objectID: 0xd5af395d9595be1b)
        #expect(handle.description == "ax:412:d5af395d9595be1b")
        #expect(try ElementHandle(handle.description) == handle)
        for bad in ["412:d5af", "ax:412", "ax:0:1", "ax:-3:1", "ax:412:zz", "ax:412:1:2", ""] {
            #expect(throws: CommandFailure.self) { try ElementHandle(bad) }
        }
    }

    @Test func treeNodesCarryTheirHandle() throws {
        let snapshot = record(1, children: [record(7, label: "OK")])
        let nodes = try AccessibilitySnapshot.normalize(snapshot, root: AccessibilityResponse.token(token(1)))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes)) as? [[String: Any]])
        #expect(json.map { $0["handle"] as? String } == ["ax:42:1", "ax:42:7"])
    }

    /// Two elements with the same label: the handle picks the one it names,
    /// and a handle no node has matches nothing.
    @Test func theHandleSelectsItsOwnElementAmongLookAlikes() throws {
        let snapshot = record(1, children: [record(7, label: "OK"), record(9, label: "OK")])
        let root = try AccessibilityResponse.token(token(1))
        func found(_ text: String) throws -> [UInt64] {
            try AccessibilitySelector(by: "handle", text: text).matches(snapshot, root: root) { CommandFailure(description: $0) }
                .map(\.node.token.objectID)
        }
        #expect(try found("ax:42:9") == [9])
        #expect(try found("ax:42:8").isEmpty && found("ax:43:9").isEmpty)
        #expect(try AccessibilitySelector(by: "label", text: "OK").matches(snapshot, root: root) { CommandFailure(description: $0) }.count == 2)
    }

    @Test func theCommandsTakeAHandleAloneAndMCPPassesIt() throws {
        let device = "00008110-000A11112222801E"
        let press = try #require(try physicalInput(["press", "--handle", "ax:42:9", "--device", device]))
        #expect(press.operation == "press-handle" && press.operands == ["ax:42:9"])
        #expect(try physicalInput(["wait", "--handle", "ax:42:9", "--until", "gone", "--device", device])?.operation == "wait-handle")
        for refused in [["press", "--handle", "ax:42:9", "--match", "contains"], ["press", "--handle", "ax:42:9", "--index", "2"],
                        ["press", "--handle", "42:9"], ["press", "--handle", "ax:42:9", "--label", "OK"],
                        ["detect-layout", "--handle", "ax:42:9"]] {
            #expect(throws: (any Error).self) { try request(refused + ["--device", device]) }
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_element" })
        let args = try tool.command(["device": .string(device), "by": "handle", "text": "ax:42:9"])
        #expect(args.contains("--handle=ax:42:9"))
    }
}
