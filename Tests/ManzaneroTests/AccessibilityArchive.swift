import Foundation
import MCP
import Testing
@testable import Manzanero

struct AccessibilityArchiveTests {
    @Test func offlineDecoderIsTheOnlyArchiveRoute() async throws {
        #expect(!MCPTools.definitions.contains { $0.name == "get_accessibility_archive" })
        let decoder = try #require(MCPTools.definitions.first { $0.name == "decode_accessibility_archive" })
        let decode = try decoder.command(["path": "tmp/My Archive.plist"])
        #expect(try DeviceCommand.parse(decode) == nil)
        let inspection = try await CommandService(readinessQuery: { _ in Issue.record("Offline dry run queried device"); return Data() }).execute(decode, dryRun: true)
        let inspectionPlan = try #require(try JSONSerialization.jsonObject(with: inspection.data) as? [String: Any])
        #expect(inspectionPlan["backend"] as? String == "foundation" && inspectionPlan["executable"] == nil)
        #expect(throws: CommandFailure.self) { try DeviceCommand.parse(["decode-ax-archive"]) }
    }
}
