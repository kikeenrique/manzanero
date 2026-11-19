import Foundation
import Testing
@testable import Manzanero

/// The note a query timeout gets when remoted lists a device connection
/// as attached but not connected.
struct StaleDeviceConnectionTests {
    static func dump(_ state: String) -> Data {
        Data("""
        Local device
        \tUUID: 11111111-2222-3333-4444-555555555555
        \tServices:
        Found ncm-1 (ncm-device)
        \tState: attached
        Found coredevice-7 (coredevice-device)
        \t\(state)
        \tProperties: {
        """.utf8)
    }

    static let timeout = CommandFailure(.toolFailed, "xcrun failed (2): ERROR: Command timeout of 10.0 seconds exceeded.", inputSent: .none)

    @Test func onlyAnAttachedCoreDeviceConnectionCounts() {
        #expect(StaleDeviceConnection.isListed(in: Self.dump("State: attached")))
        // A healthy connection, and another kind of device that is attached.
        #expect(!StaleDeviceConnection.isListed(in: Self.dump("State: connected (connectable)")))
        #expect(!StaleDeviceConnection.isListed(in: Data("not a dump".utf8)))
    }

    static let udid = "00008110-000A11112222801E"

    /// Two CoreDevice connections: the first healthy, the second in `state`.
    static func twoDevices(_ state: String) -> Data {
        Data("""
        Found coredevice-3 (coredevice-device)
        \tState: connected (connectable)
        \tProperties: {
        \t\tUniqueDeviceID => 00008101-000B33334444001E
        Found coredevice-7 (coredevice-device)
        \t\(state)
        \t No connect() results
        \tProperties: {
        \t\tUniqueDeviceID => \(udid)
        """.utf8)
    }

    @Test func aStaleConnectionIsToldApartByDevice() {
        #expect(StaleDeviceConnection.isListed(in: Self.twoDevices("State: attached"), device: Self.udid))
        // The other device's connection is healthy, and so is this one's here.
        #expect(!StaleDeviceConnection.isListed(in: Self.twoDevices("State: attached"), device: "00008101-000B33334444001E"))
        #expect(!StaleDeviceConnection.isListed(in: Self.twoDevices("State: connected (connectable)"), device: Self.udid))
    }

    @Test func anAccessibilityCommandIsRefusedBeforeItStartsOnAStaleConnection() throws {
        let failure = try #require(throws: CommandFailure.self) {
            try StaleDeviceConnection.refuseIfStale(device: Self.udid, operation: "tree", dump: { Self.twoDevices("State: attached") })
        }
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none && failure.description.hasSuffix(StaleDeviceConnection.note))
        // A healthy connection, another device's stale one and an unreadable dump refuse nothing.
        try StaleDeviceConnection.refuseIfStale(device: Self.udid, operation: "tree", dump: { Self.twoDevices("State: connected (connectable)") })
        try StaleDeviceConnection.refuseIfStale(device: "00008101-000B33334444001E", operation: "tree", dump: { Self.twoDevices("State: attached") })
        try StaleDeviceConnection.refuseIfStale(device: Self.udid, operation: "tree", dump: { throw CommandFailure(.toolFailed, "no remotectl", inputSent: .none) })
    }

    @Test func aPortIsRememberedPerDeviceAndTunnel() {
        let ports = AccessibilityServicePorts()
        #expect(ports.port(device: Self.udid, tunnelAddress: "fd00::1") == nil)
        ports.remember(63582, device: Self.udid, tunnelAddress: "fd00::1")
        #expect(ports.port(device: Self.udid, tunnelAddress: "fd00::1")?.port == 63582)
        #expect(ports.port(device: Self.udid, tunnelAddress: "fd00::1")?.source == "reused-port")
        // A new tunnel has a new address, and another device its own entry.
        #expect(ports.port(device: Self.udid, tunnelAddress: "fd00::2") == nil)
        #expect(ports.port(device: "00008101-000B33334444001E", tunnelAddress: "fd00::1") == nil)
        ports.forget(device: Self.udid, tunnelAddress: "fd00::1")
        #expect(ports.port(device: Self.udid, tunnelAddress: "fd00::1") == nil)
        // An answer from the service keeps the port; a transport failure does not.
        #expect(!AccessibilityServicePorts.doubts(CommandFailure(.targetUnresolved, "no match", inputSent: .none)))
        #expect(AccessibilityServicePorts.doubts(CommandFailure(.transportFailed, "broken pipe", inputSent: .none)))
        #expect(AccessibilityServicePorts.doubts(AccessibilitySocketTransport.Failure.closed))
    }

    /// A clock a test can move.
    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func aSavedPortIsReadByAnotherProcessUntilItIsOldOrForgotten() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/service-ports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service-ports.json")
        let clock = Clock()
        // Two objects on one file stand for two processes.
        let first = AccessibilityServicePorts(file: file, now: { clock.date })
        let second = AccessibilityServicePorts(file: file, now: { clock.date })
        first.remember(63582, device: Self.udid, tunnelAddress: "fd00::1")
        let saved = try #require(second.port(device: Self.udid, tunnelAddress: "fd00::1"))
        #expect(saved.port == 63582 && saved.source == "reused-saved-port")
        // Once read, it is in that process's memory.
        #expect(second.port(device: Self.udid, tunnelAddress: "fd00::1")?.source == "reused-port")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Forgotten by one, gone for a third.
        second.forget(device: Self.udid, tunnelAddress: "fd00::1")
        #expect(AccessibilityServicePorts(file: file, now: { clock.date }).port(device: Self.udid, tunnelAddress: "fd00::1") == nil)
        // An old entry is not used, and a file that is not the expected JSON is no entries.
        first.remember(63590, device: Self.udid, tunnelAddress: "fd00::2")
        clock.date += AccessibilityServicePorts.maximumAge + 1
        #expect(AccessibilityServicePorts(file: file, now: { clock.date }).port(device: Self.udid, tunnelAddress: "fd00::2") == nil)
        try Data("not json".utf8).write(to: file)
        #expect(AccessibilityServicePorts(file: file, now: { clock.date }).port(device: Self.udid, tunnelAddress: "fd00::2") == nil)
    }

    @Test func theTunnelPoolOffersNothingUnlessAskedAndSaysWhyItCannotOpen() throws {
        // Not asked for: no tunnel, and nothing is opened.
        let off = DeviceTunnelPool(open: { _ in Issue.record("A tunnel was opened without being asked for"); throw CancellationError() },
                                   enabled: { false })
        #expect(off.acquire(Self.udid) == nil)
        // Asked for and refused: the reason comes back, and the next command asks again.
        let refusal = CommandFailure(.deviceNotReady, "The device is not connected by cable.", inputSent: .none)
        let on = DeviceTunnelPool(open: { _ in throw refusal }, enabled: { true })
        for _ in 0..<2 {
            guard case .failure(let failure) = on.acquire(Self.udid) else {
                Issue.record("Expected the refusal")
                return
            }
            #expect(failure.code == .deviceNotReady && failure.description == refusal.description)
        }
        on.closeIfIdle()
        // The reason reaches the command's result.
        let annotated = try DirectPhysicalAccessibility.annotateNativeCleanup(Data("{}".utf8),
            release: .init(confirmed: true, status: "acknowledged", diagnostic: nil), serviceDirectory: "opened", ownTunnelUnavailable: refusal.description)
        let root = try #require(try JSONSerialization.jsonObject(with: annotated) as? [String: Any])
        #expect(root["ownTunnelUnavailable"] as? String == refusal.description && root["serviceDirectory"] as? String == "opened")
        #expect(root["ownTunnelLink"] == nil)
        // On the tunnel, the result says how the device was reached.
        let onTunnel = try DirectPhysicalAccessibility.annotateNativeCleanup(Data("{}".utf8),
            release: .init(confirmed: true, status: "acknowledged", diagnostic: nil), serviceDirectory: "own-tunnel", ownTunnelLink: "network")
        let tunnelRoot = try #require(try JSONSerialization.jsonObject(with: onTunnel) as? [String: Any])
        #expect(tunnelRoot["ownTunnelLink"] as? String == "network" && tunnelRoot["ownTunnelUnavailable"] == nil)
        // A second attempt's result carries the first one's failure.
        let second = try DirectPhysicalAccessibility.annotateNativeCleanup(Data("{}".utf8),
            release: .init(confirmed: true, status: "acknowledged", diagnostic: nil), serviceDirectory: "own-tunnel", ownTunnelLink: "network",
            retriedAfter: "Accessibility socket deadline exceeded.")
        let secondRoot = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        #expect(secondRoot["retriedAfter"] as? String == "Accessibility socket deadline exceeded." && tunnelRoot["retriedAfter"] == nil)
        // detect-layout and a watching handoff pass the route fields on.
        let passedOn = try #require(DirectPhysicalAccessibility.route(of: second))
        #expect(passedOn.keys.sorted() == ["ownTunnelLink", "retriedAfter", "serviceDirectory"])
        #expect(DirectPhysicalAccessibility.route(of: Data(#"{"status":"condition-met"}"#.utf8)) == nil)
        // Only a command that sends no input, on the tool's own tunnel, with
        // a failure of the connection, is tried once more.
        let dropped = CommandFailure(.transportFailed, "Accessibility socket deadline exceeded.", inputSent: .none)
        let missing = CommandFailure(.targetUnresolved, "No element matched.", inputSent: .none)
        #expect(DirectPhysicalAccessibility.retriesOnce(sendsInput: false, serviceDirectory: "own-tunnel", error: dropped))
        #expect(!DirectPhysicalAccessibility.retriesOnce(sendsInput: true, serviceDirectory: "own-tunnel", error: dropped))
        #expect(!DirectPhysicalAccessibility.retriesOnce(sendsInput: false, serviceDirectory: "reused-saved-port", error: dropped))
        #expect(!DirectPhysicalAccessibility.retriesOnce(sendsInput: false, serviceDirectory: nil, error: dropped))
        #expect(!DirectPhysicalAccessibility.retriesOnce(sendsInput: false, serviceDirectory: "own-tunnel", error: missing))
        #expect(!DirectPhysicalAccessibility.retriesOnce(sendsInput: false, serviceDirectory: "own-tunnel", error: CancellationError()))
        // A failure has no result, so its message names the route.
        #expect(DirectPhysicalAccessibility.routeNote(serviceDirectory: "own-tunnel", ownTunnelLink: "network", ownTunnelUnavailable: nil)
            == "Route: serviceDirectory=own-tunnel, ownTunnelLink=network.")
        #expect(DirectPhysicalAccessibility.routeNote(serviceDirectory: "reused-saved-port", ownTunnelLink: nil, ownTunnelUnavailable: "Locked.")
            == "Route: serviceDirectory=reused-saved-port. The tool's own tunnel was asked for and not used: Locked.")
    }

    @Test func aQueryTimeoutIsNamedWhenTheStateIsListed() {
        let named = StaleDeviceConnection.annotate(Self.timeout, dump: { Self.dump("State: attached") })
        #expect(named.description.hasSuffix(StaleDeviceConnection.note) && named.code == .toolFailed && named.inputSent == .none)
        // Once only.
        #expect(StaleDeviceConnection.annotate(named, dump: { Self.dump("State: attached") }).description == named.description)
    }

    @Test func otherFailuresAndHealthyConnectionsAreLeftAlone() {
        let healthy = StaleDeviceConnection.annotate(Self.timeout, dump: { Self.dump("State: connected (connectable)") })
        #expect(healthy.description == Self.timeout.description)
        let unreadable = StaleDeviceConnection.annotate(Self.timeout, dump: { throw CommandFailure(.toolFailed, "no remotectl", inputSent: .none) })
        #expect(unreadable.description == Self.timeout.description)
        // Another failure does not even read the state.
        let other = CommandFailure(.targetUnresolved, "selector has no match", inputSent: .none)
        let untouched = StaleDeviceConnection.annotate(other, dump: { Issue.record("The state was read for an unrelated failure"); return Data() })
        #expect(untouched.description == other.description)
    }
}

@Suite struct DeviceTunnelLinksTests {
    /// `devices` says, for each physical device, whether a tunnel of the
    /// tool's own can be opened to it, and names what usbmuxd lists.
    @Test func theInventorySaysWhichDevicesTheOwnTunnelReaches() throws {
        let inventory = Data(#"""
        {"result":{"devices":[
          {"deviceProperties":{"name":"Phone"},"hardwareProperties":{"reality":"physical","udid":"00008110-000A11112222801E"}},
          {"deviceProperties":{"name":"TV"},"hardwareProperties":{"reality":"physical","udid":"00008110-000B11112222801E"}},
          {"deviceProperties":{"name":"Sim"},"hardwareProperties":{"reality":"simulated","udid":"11111111-2222-3333-4444-555555555555"}}]}}
        """#.utf8)
        let links = ["00008110-000A11112222801E": "cable", "00008110-000C11112222801E": "network"]
        let annotated = try DeviceTunnelLinks.annotate(inventory, links: links)
        let root = try #require(try JSONSerialization.jsonObject(with: annotated.data) as? [String: Any])
        let devices = try #require((root["result"] as? [String: Any])?["devices"] as? [[String: Any]])
        #expect(devices.map { $0["ownTunnel"] as? String } == ["cable", "unavailable", nil])
        let listed = try #require((root["ownTunnel"] as? [String: Any])?["devices"] as? [[String: Any]])
        #expect(listed.count == 2 && listed.contains { $0["name"] as? String == "Phone" && $0["link"] as? String == "cable" })
        #expect(listed.contains { $0["udid"] as? String == "00008110-000C11112222801E" && $0["name"] == nil })
        #expect(annotated.summary.contains("  Phone: cable"))
        #expect(annotated.summary.contains("  00008110-000C11112222801E (not in the list above): network"))
        // With nothing listed, every physical device reads unavailable.
        let none = try DeviceTunnelLinks.annotate(inventory, links: [:])
        #expect(none.summary.contains("  none"))
    }
}
