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

/// Opt-in: what the audit server behind the shim answers. Asks for its
/// version, then for one element and a few of that element's attributes, in
/// the server's own requests, and prints each reply. Read-only. Enabled by
/// MANZANERO_SHIM_SELECTORS, the hardware UDID.
struct AccessibilityShimSelectorProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"] != nil))
    func theDaemonBehindTheShimAnswersTheseRequests() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"])
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let transport = shim.transport
        var identifier: UInt32 = 1
        @discardableResult func ask(_ selector: String, _ arguments: [NSObject] = [], show: Int = 1600) throws -> Data {
            let message = try AccessibilityDTX.invocation(selector, arguments: arguments, identifier: identifier)
            identifier += 1
            let limit = ContinuousClock.now.advanced(by: .seconds(6))
            try transport.write(message, until: limit, cancelled: { false })
            while true {
                let frame = try transport.read(until: limit, cancelled: { false })
                if frame.kind == .invocation {
                    let name = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "?"
                    if frame.expectsReply {
                        let seven = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
                        try transport.write(frame.reply(object: name.contains("ersion") ? seven : Data()), until: limit, cancelled: { false })
                    }
                    continue
                }
                guard frame.isReply(to: message) else { continue }
                let value = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "(\(frame.object.count) bytes)"
                let text = value.replacingOccurrences(of: "Manzanero.AccessibilityArchiveValue.", with: "")
                FileHandle.standardError.write(Data("\(selector)\(arguments.count == 2 ? " \(arguments[1])" : "") -> \(frame.kind) [\(frame.object.count) bytes] \(text.prefix(show))\n".utf8))
                return frame.object
            }
        }
        try ask("deviceApiVersion")
        let reply = try ask("deviceFetchSpecialElement:", [NSNumber(value: 1)])
        // The element is a dictionary of property-list values.
        let element = try #require(try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSData.self, NSNumber.self, NSArray.self], from: reply) as? NSDictionary)
        #expect(element["ObjectType"] as? String == "AXAuditElement_v1")
        // Do NOT ask for an attribute here by guessing its form. On
        // 2026-11-20 `deviceElement:valueForAttribute:` with the element as
        // received and the attribute's name as a plain string made the
        // Apple TV's axauditd abort (SIGABRT), twice. The form the server
        // expects has to be read from Apple's AccessibilityAudit framework
        // first (docs/verification.md#an-element-read-through-the-shim).
    }
}
