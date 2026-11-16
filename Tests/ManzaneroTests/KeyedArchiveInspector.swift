import Foundation
import Testing
@testable import Manzanero

struct KeyedArchiveInspectorTests {
    @Test func protocolDepthAccommodatesSnapshotWrappersWithoutWideningOfflineInspection() throws {
        var nested: NSObject = "leaf" as NSString
        for _ in 0..<100 { nested = [nested] as NSArray }
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: nested, requiringSecureCoding: true)
        var decoded = try KeyedArchiveInspector.decodeProtocol(bytes)
        for _ in 0..<100 {
            guard case .array(let children) = decoded, children.count == 1 else { Issue.record("Missing nested collection"); return }
            decoded = children[0]
        }
        #expect(decoded == .string("leaf"))
        #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.inspect(bytes) }
        for _ in 0..<100 { nested = [nested] as NSArray }
        let tooDeep = try NSKeyedArchiver.archivedData(withRootObject: nested, requiringSecureCoding: true)
        #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.decodeProtocol(tooDeep) }
    }

    /// Foundation creates genuine binary UID scalars; table contents below are
    /// independent malformed/unknown-class fixtures, not decoded Swift objects.
    private func references() throws -> (root: Any, two: Any, three: Any) {
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: ["first", "second"] as NSArray, requiringSecureCoding: true)
        let envelope = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let table = try #require(envelope["$objects"] as? [Any])
        let collection = try #require(table[1] as? [String: Any])
        let references = try #require(collection["NS.objects"] as? [Any])
        let top = try #require(envelope["$top"] as? [String: Any])
        return (try #require(top["root"]), references[0], references[1])
    }

    private func fixture(_ objects: [Any], root: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$version": 100000,
            "$objects": objects, "$top": ["root": root]], format: .binary, options: 0)
    }

    @Test func decodesFoundationCollectionsNestedArchiveAndOpaqueData() throws {
        let inner = try NSKeyedArchiver.archivedData(withRootObject: "nested" as NSString, requiringSecureCoding: true)
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: ["label": "Fixture", "enabled": true,
            "count": 42, "opaque": Data([1, 2, 3]), "nested": inner] as NSDictionary, requiringSecureCoding: true)
        let result = try #require(try JSONSerialization.jsonObject(with: KeyedArchiveInspector.inspect(bytes)) as? [String: Any])
        let decoded = try #require(result["decoded"] as? [String: Any])
        #expect(decoded["label"] as? String == "Fixture" && decoded["enabled"] as? Bool == true)
        #expect(decoded["count"] as? Int == 42 && (decoded["opaque"] as? [String: Int])?["dataBytes"] == 3)
        #expect((decoded["nested"] as? [String: Any])?["nestedArchive"] as? String == "nested")
        #expect((result["statistics"] as? [String: Int])?["archives"] == 2)
        #expect(result["parsedHierarchy"] as? Bool == false)
    }

    @Test func unknownClassRemainsDataWithoutRuntimeClassLookup() throws {
        let refs = try references()
        let bytes = try fixture(["$null", ["$class": refs.three, "label": refs.two], "fixture label",
            ["$classname": "UninstalledDeviceClass", "$classes": ["UninstalledDeviceClass", "NSObject"]]], root: refs.root)
        let result = try #require(try JSONSerialization.jsonObject(with: KeyedArchiveInspector.inspect(bytes)) as? [String: Any])
        let decoded = try #require(result["decoded"] as? [String: Any])
        #expect(decoded["className"] as? String == "UninstalledDeviceClass")
        #expect((decoded["fields"] as? [String: Any])?["label"] as? String == "fixture label")
    }

    @Test func rejectsCyclesOutOfRangeReferencesDuplicateKeysAndMalformedTables() throws {
        let refs = try references()
        let cyclic = try fixture(["$null", ["$class": refs.three, "NS.objects": [refs.root]], "unused", ["$classname": "NSArray"]], root: refs.root)
        let missing = try fixture(["$null", refs.three], root: refs.root)
        let duplicate = try fixture(["$null", ["$class": refs.three, "NS.keys": [refs.two, refs.two],
            "NS.objects": [refs.two, refs.two]], "same", ["$classname": "NSDictionary"]], root: refs.root)
        let badClass = try fixture(["$null", ["$class": "not a UID"]], root: refs.root)
        for bytes in [cyclic, missing, duplicate, badClass, Data(), Data("not a plist".utf8)] {
            #expect(throws: (any Error).self) { try KeyedArchiveInspector.inspect(bytes) }
        }
    }

    @Test func enforcesExpansionDepthNestingBytesAndFiniteNumbers() throws {
        let refs = try references()
        var nested: Any = "leaf"
        for _ in 0..<70 { nested = [nested] }
        let depth = try fixture(["$null", nested], root: refs.root)
        let expanded = try fixture(["$null", ["$class": refs.three, "NS.objects": Array(repeating: refs.two, count: 1000)],
            String(repeating: "x", count: 40000), ["$classname": "NSArray"]], root: refs.root)
        let infinite = try fixture(["$null", Double.infinity], root: refs.root)
        var wrapped = try NSKeyedArchiver.archivedData(withRootObject: "leaf", requiringSecureCoding: true)
        for _ in 0..<4 { wrapped = try NSKeyedArchiver.archivedData(withRootObject: wrapped as NSData, requiringSecureCoding: true) }
        for bytes in [depth, expanded, infinite, wrapped, Data(repeating: 0, count: KeyedArchiveInspector.maximumBytes + 1)] {
            #expect(throws: (any Error).self) { try KeyedArchiveInspector.inspect(bytes) }
        }
    }

    @Test func rejectsWideUIDBeforeFoundationCanNarrowIt() throws {
        // Independent binary-plist fixture: one eight-byte UID 0x1_0000_0001,
        // an offset table at 17, and its standard 32-byte trailer.
        var bytes = Data("bplist00".utf8)
        bytes.append(contentsOf: [0x87, 0, 0, 0, 1, 0, 0, 0, 1, 8])
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 1, 1])
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 17])
        do {
            _ = try KeyedArchiveInspector.inspect(bytes)
            Issue.record("Wide UID was not rejected")
        } catch { #expect(String(describing: error).contains("UID value or width")) }
    }

    @Test func cliAndMCPInspectLocalFileWithoutDeviceOrHelper() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/archive-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.plist").path
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: "local fixture", requiringSecureCoding: true)
        try bytes.write(to: URL(fileURLWithPath: path))
        let service = CommandService(readinessQuery: { _ in Issue.record("Offline inspection queried device"); return Data() })
        let cli = try await service.run(["decode-ax-archive", path])
        let expected = try KeyedArchiveInspector.inspect(bytes)
        #expect(cli.data == expected)
        let mcp = try await MCPTools.call(name: "decode_accessibility_archive", arguments: ["path": .string(path)]) {
            try await service.run($0)
        }
        #expect(mcp.isError == false)
    }
}
