import Foundation
import MCP
import Testing
@testable import Manzanero

struct AccessibilityArchiveTests {
    func fixture(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    func envelope(_ bytes: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["archive": bytes.base64EncodedString(), "format": "nskeyedarchive-base64", "parsedHierarchy": false, "experimental": true])
    }

    @Test func storesPrivateArchiveAndReturnsMetadataWithoutBase64() throws {
        try fixture { directory in
            let destination = directory.appendingPathComponent("archive.plist")
            let bytes = try NSKeyedArchiver.archivedData(withRootObject: "Synthetic fixture", requiringSecureCoding: true)
            try AccessibilityArchive.validateDestination(destination.path)
            let result = try AccessibilityArchive.save(envelope(bytes), to: destination.path)
            let value = try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])
            #expect(value["archive"] == nil)
            #expect(value["archivePath"] as? String == destination.path)
            #expect(value["archiveBytes"] as? Int == bytes.count)
            #expect(value["parsedHierarchy"] as? Bool == false)
            #expect(try Data(contentsOf: destination) == bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(throws: CommandFailure.self) { try AccessibilityArchive.validateDestination(destination.path) }
            #expect(throws: CommandFailure.self) { try AccessibilityArchive.save(envelope(bytes), to: destination.path) }
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }

    @Test func refusesSymlinksAndInvalidDataWithoutCreatingOrOverwriting() throws {
        try fixture { directory in
            let target = directory.appendingPathComponent("target"), link = directory.appendingPathComponent("link.plist")
            let sentinel = Data("sentinel".utf8)
            try sentinel.write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let bytes = try NSKeyedArchiver.archivedData(withRootObject: "fixture", requiringSecureCoding: true)
            #expect(throws: CommandFailure.self) { try AccessibilityArchive.save(envelope(bytes), to: link.path) }
            #expect(try Data(contentsOf: target) == sentinel)
            let missing = directory.appendingPathComponent("missing.plist")
            #expect(throws: CommandFailure.self) { try AccessibilityArchive.save(envelope(Data("invalid".utf8)), to: missing.path) }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(throws: CommandFailure.self) { try AccessibilityArchive.validateDestination(directory.appendingPathComponent("no-parent/archive.plist").path) }
        }
    }

    @Test func cliAndMCPPlanArchiveStorageAndOfflineDecoding() async throws {
        let definition = try #require(MCPTools.definitions.first { $0.name == "get_accessibility_archive" })
        let args = try definition.command(["device": "fixture", "path": "tmp/fixture.plist", "pairing_file": "tmp/fixture.pairing.plist"])
        let plan = try #require(try DeviceCommand.parse(args))
        #expect(plan.arguments == ["manzanero-idevice", "--pairing-file", "tmp/fixture.pairing.plist", "fixture", "ax-snapshot"])
        let output = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        let value = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(value["archiveDestination"] as? String == "tmp/fixture.plist")
        let decoder = try #require(MCPTools.definitions.first { $0.name == "decode_accessibility_archive" })
        let decode = try decoder.command(["path": "tmp/My Archive.plist"])
        #expect(try DeviceCommand.parse(decode) == nil)
        let inspection = try await CommandService(readinessQuery: { _ in Issue.record("Offline dry run queried device"); return Data() }).execute(decode, dryRun: true)
        let inspectionPlan = try #require(try JSONSerialization.jsonObject(with: inspection.data) as? [String: Any])
        #expect(inspectionPlan["backend"] as? String == "foundation" && inspectionPlan["executable"] == nil)
        for args in [["physical", "fixture", "ax-snapshot", "bad.json"], ["physical", "fixture", "ax-snapshot", "a.plist", "b.plist"], ["decode-ax-archive"]] {
            #expect(throws: CommandFailure.self) { try DeviceCommand.parse(args) }
        }
    }
}
