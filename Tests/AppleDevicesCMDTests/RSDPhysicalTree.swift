import Foundation
import Testing
@testable import AppleDevicesCMD

struct RSDPhysicalTreeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_TREE_DEVICE"] != nil))
    func explicitLiveTreeRetainsNativeDirectoryThroughDTXCleanup() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_TREE_DEVICE"])
        let pid = try #require(Int32(ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_TREE_PID"] ?? ""))
        try #require(pid > 0)
        let input = CoreDeviceInput(device: device, operation: "tree", operands: [String(pid)])
        let plan = try input.identityPlan()
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/rsd-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = ["device": device, "pid": pid, "stage": "identity", "axSocketOpened": false,
            "nativeTunnelRequested": ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_TREE_NATIVE_TUNNEL"] == "1"]
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
            let session = AccessibilitySession(transport: transport)
            let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: pid, session: session)
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
