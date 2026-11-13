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
        let details = try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: device)
        let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
        let directory = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: device)
        defer { directory.close() }
        let transport = try directory.openAccessibility()
        let session = AccessibilitySession(transport: transport)
        let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: pid, session: session)
        let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nodes = try #require(root["nodes"] as? [[String: Any]])
        #expect(nodes.count > 1)
        #expect((root["application"] as? [String: Any])?["pid"] as? Int32 == pid)
        #expect(root["parsedHierarchy"] as? Bool == true)
        #expect(transport.isClosed)
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/rsd-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: artifacts.appendingPathComponent("tree.json"))
        let metadata: [String: Any] = ["device": device, "pid": pid, "nodeCount": nodes.count,
            "hardwareHandshakeVerified": true, "transportClosed": transport.isClosed,
            "cleanup": root["cleanup"] ?? [:], "backend": "Apple RemoteXPC directory plus raw AX DTX in process"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("result.json"))
    }
}
