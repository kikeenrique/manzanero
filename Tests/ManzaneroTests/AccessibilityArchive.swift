import Foundation
import MCP
import Testing
@testable import Manzanero

struct AccessibilityArchiveTests {
    @Test func offlineDecoderIsTheOnlyArchiveRoute() async throws {
        #expect(!MCPTools.definitions.contains { $0.name == "get_accessibility_archive" })
        let decoder = try #require(MCPTools.definitions.first { $0.name == "decode_accessibility_archive" })
        let decode = try decoder.command(["path": "tmp/My Archive.plist"])
        #expect(decode == ["decode-ax-archive", "--", "tmp/My Archive.plist"])
        #expect(try request(decode) == .decodeArchive(path: "tmp/My Archive.plist"))
        let inspection = try await CommandService(readinessQuery: { _ in Issue.record("Offline dry run queried device"); return Data() }).run(decode, dryRun: true)
        let inspectionPlan = try #require(try JSONSerialization.jsonObject(with: inspection.data) as? [String: Any])
        #expect(inspectionPlan["backend"] as? String == "foundation" && inspectionPlan["executable"] == nil)
        // A missing path is the parser's usage error; an empty one is refused by the command.
        let missing = try #require(throws: CommandFailure.self) { try CLI.parse(["decode-ax-archive"], environment: [:]) }
        #expect(missing.code == .usage)
        let empty = try #require(throws: CommandFailure.self) { try request(["decode-ax-archive", ""]) }
        #expect(empty.description == "Usage: decode-ax-archive <local-plist>")
    }
}
