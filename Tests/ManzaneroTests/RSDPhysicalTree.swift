import Foundation
import Testing
@testable import Manzanero

struct RSDPhysicalTreeTests {
    /// Opt-in probe only: retain at most four unsupported/malformed archives for
    /// offline data-only diagnosis. Never added to the production session.
    private final class DiagnosticTransport: AccessibilitySessionTransport {
        let base: AccessibilitySocketTransport
        let artifacts: URL
        var saved = 0
        var events: [[String: Any]] = []
        init(_ base: AccessibilitySocketTransport, artifacts: URL) { self.base = base; self.artifacts = artifacts }
        func record(_ frame: AccessibilityDTX, direction: String) throws {
            guard events.count < 320 else { return }
            var event: [String: Any] = ["direction": direction, "id": frame.identifier,
                "conversation": frame.conversation, "kind": String(describing: frame.kind)]
            if frame.kind == .invocation,
               case .string(let selector) = try? KeyedArchiveInspector.decodeProtocol(frame.object) {
                event["selector"] = selector
                if selector == "processDataFromRemoteDevice:", let bytes = try? frame.archiveArgument() {
                    event["responseType"] = try? KeyedArchiveInspector.protocolResponseType(bytes)
                }
                if direction == "write", selector == "processDataFromHost:", events.count < 32 {
                    let bytes = try frame.archiveArgument()
                    guard FileManager.default.createFile(atPath: artifacts.appendingPathComponent("request-\(frame.identifier).plist").path,
                        contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                        throw CommandFailure(description: "Cannot save private request diagnostic.")
                    }
                }
            }
            events.append(event)
            try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
                .write(to: artifacts.appendingPathComponent("frame-structure.json"))
        }
        func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
            let frame = try base.read(until: deadline, cancelled: cancelled)
            try record(frame, direction: "read")
            if frame.kind == .invocation, saved < 4,
               (try? KeyedArchiveInspector.decodeProtocol(frame.object)) == .string("processDataFromRemoteDevice:"),
               let bytes = try? frame.archiveArgument(), bytes.count <= KeyedArchiveInspector.maximumBytes {
                do { _ = try AccessibilityResponse(archive: bytes) }
                catch {
                    saved += 1
                    let file = artifacts.appendingPathComponent("malformed-callback-\(saved).plist")
                    guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                        throw CommandFailure(description: "Cannot save private callback diagnostic.")
                    }
                }
            }
            return frame
        }
        func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
            try record(message, direction: "write")
            try base.write(message, until: deadline, cancelled: cancelled)
        }
        func close() { base.close() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_RSD_TREE_DEVICE"] != nil))
    func explicitLiveTreeRetainsNativeDirectoryThroughDTXCleanup() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_RSD_TREE_DEVICE"])
        let pid = try #require(Int32(ProcessInfo.processInfo.environment["MANZANERO_RSD_TREE_PID"] ?? ""))
        try #require(pid > 0)
        let input = CoreDeviceInput(device: device, operation: "tree", operands: [String(pid)])
        let foreground = ProcessInfo.processInfo.environment["MANZANERO_RSD_TREE_FOREGROUND"] == "1"
        let plan = try input.identityPlan()
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/rsd-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = ["device": device, "pid": pid, "stage": "identity", "axSocketOpened": false,
            "nativeTunnelRequested": ProcessInfo.processInfo.environment["MANZANERO_RSD_TREE_NATIVE_TUNNEL"] == "1"]
        metadata["directoryTransport"] = "network"
        metadata["selection"] = foreground ? "centre-hit-test" : "explicit-pid"
        var assertion: NativeTunnelAssertion?
        var directory: RSDDirectoryConnection?
        defer { directory?.close(); assertion?.close() }
        func record() throws {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("result.json"))
        }
        func close() {
            directory?.close()
            if let release = assertion?.close() {
                metadata["assertionReleaseConfirmed"] = release.confirmed
                metadata["assertionReleaseStatus"] = release.status
                metadata["assertionReleaseDiagnostic"] = release.diagnostic ?? ""
            }
        }
        do {
            let details = try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
            let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
            let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: device)
            if metadata["nativeTunnelRequested"] as? Bool == true {
                metadata["stage"] = "assertion-acquisition"
                assertion = try NativeTunnelAssertion(device: device, details: details)
                metadata["assertionAcquired"] = true
            }
            metadata["stage"] = "port-discovery"
            let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
            metadata["stage"] = "directory-handshake"
            directory = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: device)
            metadata["hardwareHandshakeVerified"] = true
            metadata["stage"] = "ax-socket"
            let transport = try #require(directory).openAccessibility()
            metadata["axSocketOpened"] = true
            metadata["stage"] = "tree-read"
            let session = AccessibilitySession(transport: DiagnosticTransport(transport, artifacts: artifacts))
            let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: foreground ? nil : pid, session: session,
                display: { try AccessibilityDisplay(ToolRunner().run(AccessibilityDisplay.plan(device: identity.uuid).arguments, timeout: 15)) })
            let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let nodes = try #require(root["nodes"] as? [[String: Any]])
            try #require(nodes.count > 1)
            #expect((root["application"] as? [String: Any])?["pid"] as? Int32 == pid)
            #expect(root["parsedHierarchy"] as? Bool == true)
            #expect(transport.isClosed)
            try bytes.write(to: artifacts.appendingPathComponent("tree.json"))
            metadata["nodeCount"] = nodes.count
            metadata["transportClosed"] = transport.isClosed
            metadata["cleanup"] = root["cleanup"] ?? [:]
            metadata["outcome"] = "captured"
            close()
            try record()
        } catch {
            close()
            metadata["outcome"] = "failed"
            metadata["error"] = String(describing: error)
            try? record()
            throw error
        }
    }
}
