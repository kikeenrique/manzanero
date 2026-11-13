import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalAccessibilityTests {
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

    @Test func invalidArgumentsAndDisabledReadinessNeverOpenTransport() throws {
        let device = CoreDeviceInputTests().udid
        for operands in [[], ["0"], ["-1"], ["2147483648"], ["42", "extra"]] {
            #expect(throws: CommandFailure.self) {
                try DirectPhysicalAccessibility.execute(.init(device: device, operation: "tree", operands: operands),
                    query: { _ in Issue.record("Invalid PID queried"); return Data() },
                    open: { _, _ in Issue.record("Invalid PID opened transport"); throw CancellationError() })
            }
        }
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalAccessibility.execute(.init(device: device, operation: "tree", operands: ["42"]),
                query: { _ in try DirectPhysicalInputTests().details(mode: "disabled") },
                open: { _, _ in Issue.record("Disabled device opened transport"); throw CancellationError() })
        }
    }

    @Test func freshIdentityPrecedesSingleOwnedCaptureWithoutHelper() throws {
        let transport = try wire()
        var queries = 0, opens = 0
        _ = try DirectPhysicalAccessibility.execute(.init(device: CoreDeviceInputTests().udid, operation: "tree", operands: ["42"]),
            query: { _ in queries += 1; return try DirectPhysicalInputTests().details() }, open: { uuid, version in
                #expect(queries == 1 && uuid == CoreDeviceInputTests().uuid && version == "651.32")
                opens += 1
                return transport
            })
        #expect(opens == 1 && transport.closed)
    }

    @Test func cliAndMCPDryRunsShareTheOptInRouteWithoutQuerying() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "get_ui_tree" })
        let args = try tool.command(["platform": "physical", "device": "fixture", "pid": 42, "backend": "coredevice"])
        #expect(args == ["--physical-backend", "coredevice", "physical", "fixture", "tree", "42"])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried a device"); return Data() })
        let cli = try await service.execute(args, dryRun: true)
        let mcp = try await MCPTools.call(name: "get_ui_tree", arguments: ["platform": "physical", "device": "fixture", "pid": 42, "backend": "coredevice"]) {
            try await service.execute($0, dryRun: true)
        }
        #expect(mcp.isError == false && mcp.structuredContent?.objectValue?["result"]?.objectValue?["pid"] == 42)
        let plan = try #require(try JSONSerialization.jsonObject(with: cli.data) as? [String: Any])
        #expect(plan["liveVerified"] as? Bool == false && plan["executable"] == nil)
        for invalid in [["--physical-backend", "coredevice", "physical", "fixture", "tree"],
                        ["--physical-backend", "coredevice", "simulator", "fixture", "tree", "42"],
                        ["--physical-backend", "coredevice", "physical", "fixture", "tree", "0"]] {
            await #expect(throws: CommandFailure.self) { try await service.execute(invalid, dryRun: true) }
        }
    }
}
