import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilitySnapshotTests {
    typealias Value = AccessibilityArchiveValue

    private func token(_ id: UInt64, pid: Int32 = 42) -> Value {
        .object(className: "AXPTranslationObject", fields: ["pid": .signed(Int64(pid)), "objectID": .unsigned(id),
            "isApplicationElement": .boolean(id == 1), "didPopuldateAppInfo": .boolean(true),
            "rawElementData": .data(Data([0x91, 0x92])), "bridgeDelegateToken": .null])
    }

    private func record(_ id: UInt64 = 1, pid: Int32 = 42, attributes: [String: Value] = [:],
                        children: [Value] = [], count: Value? = nil) -> Value {
        .dictionary(["UIAccessibilitySnapshotKeyElement": token(id, pid: pid),
            "UIAccessibilitySnapshotKeyAttributes": .dictionary(attributes),
            "UIAccessibilitySnapshotKeyChildren": .array(children),
            "UIAccessibilitySnapshotKeyChildrenCount": count ?? .unsigned(UInt64(children.count))])
    }

    private func root() throws -> AccessibilityRequest.Token { try AccessibilityResponse.token(token(1)) }
    private func rectangle(_ text: String) -> Value { .object(className: "NSValue", fields: ["NS.rectval": .string(text)]) }

    @Test func preservesParentPathsAndOmitsPrivateTokensFromJSON() throws {
        let leaf = record(4, attributes: ["2001": .string("Leaf")])
        let snapshot = record(children: [record(2, children: [leaf]), record(3)])
        let nodes = try AccessibilitySnapshot.normalize(snapshot, root: root())
        #expect(nodes.map(\.id) == ["n0", "n1", "n2", "n3"])
        #expect(nodes[0].parentId == nil && nodes[0].children == ["n1", "n2"])
        #expect(nodes[1].children == ["n3"] && nodes[3].parentId == "n1" && nodes[3].depth == 2)
        #expect(nodes[3].label == .string("Leaf") && nodes[3].token.objectID == 4)
        let bytes = try JSONEncoder().encode(nodes)
        let json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(json[0]["parentId"] is NSNull)
        #expect(json[0]["label"] == nil && json[0]["visible"] == nil && json[0]["frame"] == nil)
        let text = String(decoding: bytes, as: UTF8.self)
        for key in ["token", "objectID", "rawElementData", "bridgeDelegateToken"] { #expect(text.contains(key) == false) }
    }

    @Test func scalarAttributesFramesTraitsAndVisibilityRetainTheirMeanings() throws {
        let snapshot = record(attributes: ["2001": .string("Fixture"), "2002": .string("Hint"), "5019": .string("row"),
            "2006": .real(1.5), "2003": rectangle("{{-1, 2.5}, {375, 812}}"), "2004": .signed(-1),
            "2025": .signed(1), "5003": .string("AXButton"), "5004": .string("FixtureClass"), "3003": .string("test.fixture")])
        let node = try #require(try AccessibilitySnapshot.normalize(snapshot, root: root()).first)
        #expect(node.identifier == .string("row") && node.value == .real(1.5) && node.visible == true)
        #expect(node.frame == .init(x: -1, y: 2.5, width: 375, height: 812))
        #expect(node.traits == String(UInt64.max) && node.nativeAttributes?["5003"] == "AXButton")
        let nullFrame = try AccessibilitySnapshot.normalize(record(attributes: ["2003": rectangle("{{inf, inf}, {0, 0}}")]), root: root())
        #expect(nullFrame[0].frame == nil && nullFrame[0].frameUnavailable == "CGRectNull")
    }

    @Test(arguments: ["{{0, 0}, {-1, 1}}", "{{nan, 0}, {1, 1}}", "{{inf, 1}, {0, 0}}", "{0,0,1,1}",
                      "{{0, 0}, {1, 1}} trailing", "{{0, 0}, {1, 1}"])
    func refusesMalformedAndNonFiniteRectangles(_ text: String) {
        #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.rectangle(rectangle(text)) }
    }

    @Test func refusesCountRootAndAttributeShapeMismatches() throws {
        for snapshot in [record(count: .unsigned(1)), record(count: .boolean(false)), record(2), record(pid: 43),
                         record(attributes: ["2001": .array([])]), record(attributes: ["2003": .string("rectangle")]),
                         record(attributes: ["2004": .boolean(true)]), record(attributes: ["2025": .real(1)]),
                         record(attributes: ["2025": .unsigned(2)]), record(attributes: ["5003": .signed(3)]), .dictionary([:])] {
            #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.normalize(snapshot, root: root()) }
        }
        let notApplication = try AccessibilityResponse.token(token(2))
        #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.normalize(record(2), root: notApplication) }
    }

    @Test func repeatedElementsRemainDistinctPathsAndForeignReferencesStayExplicit() throws {
        let repeated = record(2)
        let foreign = record(3, pid: 43, attributes: ["5003": .string("AXRemoteElement")])
        let nodes = try AccessibilitySnapshot.normalize(record(children: [repeated, repeated, foreign]), root: root())
        #expect(nodes.count == 4 && nodes[1].id != nodes[2].id && nodes[1].token.objectID == nodes[2].token.objectID)
        #expect(nodes[3].externalProcessReference == true && nodes[3].processIdentifier == 43)
        for child in [record(3, pid: 43), record(3, pid: 43, attributes: ["5003": .string("AXRemoteElement")], children: [record(4, pid: 43)])] {
            #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.normalize(record(children: [child]), root: root()) }
        }
    }

    @Test func enforcesExactNodeAndDepthBoundsWithoutPartialOutput() throws {
        let children = (2...512).map { record(UInt64($0)) }
        #expect(try AccessibilitySnapshot.normalize(record(children: children), root: root()).count == 512)
        #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.normalize(record(children: children + [record(513)]), root: root()) }
        var chain = record(34)
        for id in stride(from: 33, through: 2, by: -1) { chain = record(UInt64(id), children: [chain]) }
        #expect(throws: CommandFailure.self) { try AccessibilitySnapshot.normalize(record(children: [chain]), root: root()) }
        var valid = record(33)
        for id in stride(from: 32, through: 2, by: -1) { valid = record(UInt64(id), children: [valid]) }
        #expect(try AccessibilitySnapshot.normalize(record(children: [valid]), root: root()).last?.depth == 32)
    }

    @Test func binaryNativeSnapshotDecodesAndNormalizesBeyondOfflineInspectionDepth() throws {
        var children: [NSDictionary] = []
        for id in stride(from: 21, through: 1, by: -1) {
            children = [["UIAccessibilitySnapshotKeyElement": ArchiveToken(id: UInt64(id)),
                "UIAccessibilitySnapshotKeyAttributes": [NSNumber(value: 2001): "Fixture \(id)"],
                "UIAccessibilitySnapshotKeyChildren": children,
                "UIAccessibilitySnapshotKeyChildrenCount": children.count] as NSDictionary]
        }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslationObject", for: ArchiveToken.self)
        coder.encode(children[0], forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        let archive = coder.encodedData
        let decoded = try KeyedArchiveInspector.decodeProtocol(archive)
        let nodes = try AccessibilitySnapshot.normalize(decoded, root: root())
        #expect(nodes.count == 21 && nodes.last?.depth == 20 && nodes.last?.label == .string("Fixture 21"))
        #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.inspect(archive) }
    }

    @objc(ADCAXSnapshotTestToken)
    private final class ArchiveToken: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let id: UInt64
        init(id: UInt64) { self.id = id }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(Int32(42), forKey: "pid")
            coder.encode(NSNumber(value: id), forKey: "objectID")
            coder.encode(id == 1, forKey: "isApplicationElement")
            coder.encode(true, forKey: "didPopuldateAppInfo")
            coder.encode(nil as NSObject?, forKey: "rawElementData")
            coder.encode(nil as NSObject?, forKey: "bridgeDelegateToken")
        }
    }
}
