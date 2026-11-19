import Foundation
import Testing
@testable import Manzanero

/// Opt-in live check of the tool's own tunnel on a device on its cable or on the network
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

/// Opt-in live check of the accessibility daemon reached through the Mac's
/// own remoted, by the shim MobileDevice is served: one read-only tree of
/// the app in front. Enabled by MANZANERO_SHIM_DEVICE, the hardware UDID.
struct AccessibilityShimProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_DEVICE"] != nil))
    func aTreeIsReadThroughTheShim() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_SHIM_DEVICE"])
        let run: (DeviceCommand) throws -> Data = { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) }
        let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: device, operation: "tree", operands: []), query: run)
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let session = AccessibilitySession(transport: shim.transport)
        let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: nil, session: session,
            display: { try AccessibilityDisplay(run(AccessibilityDisplay.plan(device: identity.uuid))) })
        let tree = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nodes = tree["nodeCount"] as? Int ?? 0
        #expect(nodes > 0)
        FileHandle.standardError.write(Data("tree through the shim: \(nodes) nodes, \(bytes.count) bytes\n".utf8))
    }
}

/// Opt-in: which requests does the daemon behind the shim answer? Sends a
/// few read-only requests and prints the kind of each reply. Enabled by
/// MANZANERO_SHIM_SELECTORS, the hardware UDID.
struct AccessibilityShimSelectorProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"] != nil))
    func theDaemonBehindTheShimAnswersTheseRequests() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"])
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let transport = shim.transport
        var identifier: UInt32 = 1
        func ask(_ selector: String, _ argument: NSObject? = nil) throws {
            let message = try AccessibilityDTX.invocation(selector, argument: argument, identifier: identifier)
            identifier += 1
            let limit = ContinuousClock.now.advanced(by: .seconds(4))
            try transport.write(message, until: limit, cancelled: { false })
            while true {
                let frame = try transport.read(until: limit, cancelled: { false })
                if frame.kind == .invocation {
                    let name = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "?"
                    FileHandle.standardError.write(Data("  device calls \(name.prefix(80)) expectsReply=\(frame.expectsReply)\n".utf8))
                    if frame.expectsReply {
                        let seven = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
                        try transport.write(frame.reply(object: name.contains("ersion") ? seven : Data()), until: limit, cancelled: { false })
                    }
                    continue
                }
                guard frame.isReply(to: message) else { continue }
                let value = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "(\(frame.object.count) bytes)"
                FileHandle.standardError.write(Data("\(selector) -> \(frame.kind) \(value.prefix(selector == "deviceCapabilities" ? 6000 : 300))\n".utf8))
                return
            }
        }
        for selector in ["deviceApiVersion", "deviceAPIVersion", "deviceCapabilities", "deviceAccessibilitySettings", "deviceAllAuditCaseIDs"] {
            do { try ask(selector) } catch { FileHandle.standardError.write(Data("\(selector) -> threw \(error)\n".utf8)); break }
        }
        do { try ask("clientNeedsAccessibility:", NSNumber(value: false)) } catch { FileHandle.standardError.write(Data("clientNeedsAccessibility: -> threw \(error)\n".utf8)) }
    }
}
