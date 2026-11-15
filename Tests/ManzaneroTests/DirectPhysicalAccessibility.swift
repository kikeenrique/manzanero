import Foundation
import MCP
import Testing
@testable import Manzanero

struct DirectPhysicalAccessibilityTests {
    @Test func foregroundCaptureBracketsTreeWithProcessAndDisplayChecks() throws {
        let fixture = AccessibilitySessionTests()
        for failure in ["none", "pid-changed", "display-changed"] {
            let wire = AccessibilitySessionTests.Transport([try fixture.reply(1, value: NSNumber(value: 26)), try fixture.reply(2),
                try fixture.reply(3), try fixture.callback(kind: 6, rootID: 5),
                try fixture.reply(4), try fixture.callback(kind: 1, rootID: 1),
                try fixture.reply(5), try fixture.callback(kind: 2, attribute: 52, rootID: 1, nativeSnapshot: true),
                try fixture.reply(6), try fixture.callback(kind: 1, rootID: 1),
                try fixture.reply(7), try fixture.callback(kind: 6, pid: failure == "pid-changed" ? 43 : 42, rootID: 7),
                try fixture.reply(8)])
            var queries = 0
            let capture = {
                try DirectPhysicalAccessibility.capture(device: "fixture", resolved: UUID().uuidString, pid: nil,
                    session: AccessibilitySession(transport: wire), display: {
                        queries += 1
                        return try AccessibilityDisplay(AccessibilityDisplayTests.data(scale: queries == 2 && failure == "display-changed" ? 2 : 3))
                    })
            }
            if failure == "none" {
                let tree = try #require(JSONSerialization.jsonObject(with: capture()) as? [String: Any])
                #expect((tree["application"] as? [String: Any])?["selection"] as? String == "centre-hit-test")
                #expect((tree["application"] as? [String: Any])?["pid"] as? Int == 42)
                #expect((tree["display"] as? [String: Any])?["pointScale"] as? Int == 3)
                #expect(tree["nodeCount"] as? Int == 1)
            } else { #expect(throws: CommandFailure.self) { try capture() } }
            #expect(queries == (failure == "pid-changed" ? 1 : 2))
            #expect(wire.closed && wire.incoming.isEmpty)
            // Only read request types 6/1/2/1/6; never type 7 actions.
            let requests = try wire.outgoing.filter { $0.kind == .invocation }.compactMap { message -> AccessibilityArchiveValue? in
                guard try KeyedArchiveInspector.decodeProtocol(message.object) == .string("processDataFromHost:") else { return nil }
                return try KeyedArchiveInspector.decodeProtocol(message.archiveArgument())
            }
            #expect(requests.count == 5)
            for request in requests {
                guard case .object(_, let fields) = request else { Issue.record("Missing request"); continue }
                #expect([1, 2, 6].contains(fields["requestType"]?.unsignedInteger ?? 0))
            }
        }
    }
    @Test func nativePipelineRejectsInvalidPIDsBeforeAnyQueryAndRetainsCleanupUncertainty() async throws {
        for operands in [["0"], ["-1"], ["42", "extra"]] {
            await #expect(throws: CommandFailure.self) {
                try await DirectPhysicalAccessibility.executeNativeRSD(.init(device: "fixture", operation: "tree", operands: operands),
                    query: { _ in Issue.record("Invalid native tree queried"); return Data() })
            }
        }
        let bytes = try DirectPhysicalAccessibility.capture(device: "fixture", resolved: UUID().uuidString, pid: 42,
            session: AccessibilitySession(transport: wire()))
        let annotated = try DirectPhysicalAccessibility.annotateNativeCleanup(bytes,
            release: .init(confirmed: false, status: "unconfirmed", diagnostic: "Fixture release lost"))
        let root = try #require(JSONSerialization.jsonObject(with: annotated) as? [String: Any])
        #expect((root["cleanup"] as? [String: Any])?["confirmed"] as? Bool == true)
        #expect((root["connectionCleanup"] as? [String: Any])?["confirmed"] as? Bool == false)
        #expect((root["connectionCleanup"] as? [String: Any])?["diagnostic"] as? String == "Fixture release lost")
        #expect(root["transport"] as? String == "apple-network-rsd")
    }
    private func wire(afterRoot: UInt64 = 1, validSnapshot: Bool = true, cleanup: Bool = true) throws -> AccessibilitySessionTests.Transport {
        let fixture = AccessibilitySessionTests()
        var incoming = [try fixture.reply(1, value: NSNumber(value: 26)), try fixture.reply(2),
            try fixture.callback(kind: 1, rootID: 1), try fixture.reply(3), try fixture.reply(4),
            try fixture.callback(kind: 2, attribute: 52, rootID: 1, nativeSnapshot: validSnapshot)]
        if validSnapshot { incoming += [try fixture.callback(kind: 1, rootID: afterRoot), try fixture.reply(5)] }
        if cleanup { incoming.append(try fixture.reply(validSnapshot ? 6 : 5)) }
        return AccessibilitySessionTests.Transport(incoming)
    }

    @Test func captureRechecksRootAndEncodesAnHonestObservation() throws {
        let transport = try wire()
        let bytes = try DirectPhysicalAccessibility.capture(device: "fixture", resolved: UUID().uuidString, pid: 42,
            session: AccessibilitySession(transport: transport))
        let value = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(value["format"] as? String == "accessibility-tree" && value["nodeCount"] as? Int == 1)
        #expect(value["parsedHierarchy"] as? Bool == true && value["atomic"] as? Bool == false)
        #expect(value["rootStabilityScope"] as? String == "application-identity")
        #expect((value["application"] as? [String: Any])?["selection"] as? String == "explicit-pid")
        #expect((value["cleanup"] as? [String: Any])?["subscriptionStop"] as? String == "acknowledged")
        #expect(transport.closed && transport.incoming.isEmpty)
        #expect(String(decoding: bytes, as: UTF8.self).contains("objectID") == false)
    }

    @Test func changedRootsAndMalformedSnapshotsNeverReturnAPartialTree() throws {
        for transport in [try wire(afterRoot: 2), try wire(validSnapshot: false)] {
            #expect(throws: CommandFailure.self) {
                try DirectPhysicalAccessibility.capture(device: "fixture", resolved: UUID().uuidString, pid: 42,
                    session: AccessibilitySession(transport: transport))
            }
            #expect(transport.closed)
        }
    }

    @Test func cleanupLossDoesNotBecomeConfirmedTeardown() throws {
        let transport = try wire(cleanup: false)
        let bytes = try DirectPhysicalAccessibility.capture(device: "fixture", resolved: UUID().uuidString, pid: 42,
            session: AccessibilitySession(transport: transport))
        let value = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let cleanup = try #require(value["cleanup"] as? [String: Any])
        #expect(cleanup["confirmed"] as? Bool == false && cleanup["subscriptionStop"] as? String == "unconfirmed")
        #expect(cleanup["diagnostic"] as? String != nil && transport.closed)
    }

    @Test func cliAndMCPDryRunsShareTheOptInRouteWithoutQuerying() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "get_ui_tree" })
        let args = try tool.command(["platform": "physical", "device": "fixture", "pid": 42])
        #expect(args == ["physical", "fixture", "tree", "42"])
        #expect(try tool.command(["device": "fixture"]) == ["physical", "fixture", "tree"])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried a device"); return Data() })
        let cli = try await service.execute(args, dryRun: true)
        let mcp = try await MCPTools.call(name: "get_ui_tree", arguments: ["device": "fixture", "pid": 42]) {
            try await service.execute($0, dryRun: true)
        }
        #expect(mcp.isError == false && mcp.structuredContent?.objectValue?["result"]?.objectValue?["pid"] == 42)
        let plan = try #require(try JSONSerialization.jsonObject(with: cli.data) as? [String: Any])
        #expect(plan["liveVerified"] as? Bool == false && plan["executable"] == nil)
        let foreground = try await service.execute(["physical", "fixture", "tree"], dryRun: true)
        let foregroundPlan = try #require(JSONSerialization.jsonObject(with: foreground.data) as? [String: Any])
        #expect(foregroundPlan["pid"] is NSNull)
        for invalid in [["--physical-backend", "coredevice", "simulator", "fixture", "tree", "42"],
                        ["--physical-backend", "coredevice", "physical", "fixture", "tree", "0"]] {
            await #expect(throws: CommandFailure.self) { try await service.execute(invalid, dryRun: true) }
        }
    }
}
