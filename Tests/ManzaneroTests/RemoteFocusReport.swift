import Foundation
import MCP
import Testing
@testable import Manzanero

/// `remote <button> --report-focus`: the press's receipt with the focused
/// element of a fresh tree, and never a failed press for a failed read.
struct RemoteFocusReportTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    private static func output(_ object: [String: Any], exitCode: Int32 = 0) throws -> CommandOutput {
        CommandOutput(data: try JSONSerialization.data(withJSONObject: object), exitCode: exitCode)
    }

    private static func receipt(_ output: CommandOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    private static var press: [String: Any] { ["operation": "remote", "remote": "down", "verified": false] }

    @Test func theFocusedNodeGoesIntoTheReceipt() async throws {
        let tree = try Self.output(["application": ["pid": 412, "selection": "frontmost"], "nodes": [
            ["id": "n1", "label": "Row 1"],
            ["id": "n2", "label": "Row 2", "identifier": "probe.list.row.2", "frame": ["x": 0, "y": 100, "width": 1920, "height": 80], "focused": true]]])
        let result = try Self.receipt(await RemoteFocusReport.annotate(try Self.output(Self.press)) { tree })
        let focus = try #require(result["focus"] as? [String: Any])
        #expect(focus["nodeId"] as? String == "n2" && focus["label"] as? String == "Row 2" && focus["identifier"] as? String == "probe.list.row.2")
        #expect(focus["value"] is NSNull && (focus["frame"] as? [String: Int])?["y"] == 100)
        #expect(result["remote"] as? String == "down" && result["focusUnavailable"] == nil)
        #expect((result["focusApplication"] as? [String: Any])?["pid"] as? Int == 412)
    }

    @Test func noFocusedNodeIsNullWithANote() async throws {
        let tree = try Self.output(["nodes": [["id": "n1", "label": "Row 1"]]])
        let result = try Self.receipt(await RemoteFocusReport.annotate(try Self.output(Self.press)) { tree })
        #expect(result["focus"] is NSNull && (result["focusNote"] as? String)?.contains("TVSystemUIService") == true)
    }

    @Test func aFailedReadKeepsThePressAndSaysWhy() async throws {
        let refused = CommandFailure(.unsupportedOperation, "An Apple TV's accessibility needs the tool's own tunnel.", inputSent: .none)
        let output = await RemoteFocusReport.annotate(try Self.output(Self.press)) { throw refused }
        let result = try Self.receipt(output)
        #expect(output.exitCode == 0 && result["focus"] == nil)
        #expect((result["focusUnavailable"] as? String)?.contains("own tunnel") == true)
        let cancelled = try Self.receipt(await RemoteFocusReport.annotate(try Self.output(Self.press)) { throw CancellationError() })
        #expect((cancelled["focusUnavailable"] as? String)?.hasPrefix("Cancelled") == true)
    }

    @Test func aPressThatDidNotSucceedIsNotFollowedByATree() async throws {
        let failed = try Self.output(Self.press, exitCode: 1)
        let output = await RemoteFocusReport.annotate(failed) { Issue.record("Tree read after a failed press"); return failed }
        #expect(output.data == failed.data && output.exitCode == 1)
    }

    @Test func theFlagBuildsThePressAndTheTreeAndRefusesSleepAndWake() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        let output = try await service.run(["remote", "down", "--report-focus", "--device", Self.uuid], dryRun: true)
        let plan = try Self.receipt(output)
        #expect(plan["remote"] as? String == "down" && (plan["reportFocus"] as? [String: Any])?["settleMilliseconds"] as? Int == 600)
        let request = try CLI.invocation(["remote", "select", "--report-focus", "--device", Self.uuid]).request
        guard case .reportingFocus(let press, let tree) = request else { Issue.record("Not a focus report: \(request)"); return }
        #expect(press.addressed?.operation == "remote" && tree.addressed?.operation == "tree")
        #expect(request.signalContext == "physical input" && !request.isReadOnly)
        for name in ["sleep", "wake"] {
            let failure = #expect(throws: CommandFailure.self) { try CLI.invocation(["remote", name, "--report-focus", "--device", Self.uuid]) }
            #expect(failure?.code == .usage)
        }
        let tool = try #require(MCPTools.definitions.first { $0.name == "press_remote" })
        let args = try tool.command(["device": .string(Self.uuid), "platform": "physical", "button": "down", "report_focus": true])
        #expect(args.contains(RemoteFocusReport.flag))
    }
}
