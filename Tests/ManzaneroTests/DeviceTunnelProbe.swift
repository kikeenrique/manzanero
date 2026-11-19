import Foundation
import Testing
@testable import Manzanero

/// Opt-in live check of the tool's own tunnel on a device connected by cable
/// and unlocked: open the tunnel, relay to the device's service directory,
/// and read the directory through the tool's existing directory code. Reads
/// only; nothing is sent to an app. Enabled by MANZANERO_TUNNEL_DEVICE, the
/// hardware UDID.
struct DeviceTunnelProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_TUNNEL_DEVICE"] != nil))
    func theDirectoryIsReadThroughTheToolsOwnTunnel() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_TUNNEL_DEVICE"])
        let tunnel = try DeviceTunnel(device: device)
        defer { tunnel.close() }
        #expect(tunnel.info.mtu >= 1280 && tunnel.info.serviceDirectoryPort > 0)
        let port = try tunnel.relay(to: tunnel.info.serviceDirectoryPort)
        // The directory's handshake checks the device's identity itself.
        let directory = try RSDDirectoryConnection(tunnelAddress: "::1", port: port, expectedUDID: device, relayed: true)
        defer { directory.close() }
        #expect(directory.accessibilityPort > 0)
        FileHandle.standardError.write(Data("tunnel mtu \(tunnel.info.mtu), accessibility service found: \(directory.accessibilityPort > 0)\n".utf8))

        // One read-only tree of the app in front, over a second relay to
        // the accessibility service's port.
        let run: (DeviceCommand) throws -> Data = { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) }
        let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: device, operation: "tree", operands: []), query: run)
        let servicePort = try tunnel.relay(to: directory.accessibilityPort)
        let transport = try RSDDirectoryConnection.openAccessibility(tunnelAddress: "::1", port: servicePort, relayed: true)
        let session = AccessibilitySession(transport: transport)
        let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: nil, session: session,
            display: { try AccessibilityDisplay(run(AccessibilityDisplay.plan(device: identity.uuid))) })
        let tree = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nodes = tree["nodeCount"] as? Int ?? 0
        #expect(nodes > 0)
        FileHandle.standardError.write(Data("tree through the tunnel: \(nodes) nodes, \(bytes.count) bytes\n".utf8))
    }
}
