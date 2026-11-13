import AppleDeviceBridge
import Foundation
import Testing
@testable import AppleDevicesCMD

struct RSDPortDiscoveryTests {
    private let udid = "00000000-0000000000000001"
    private let address = "fd12:3456::1"

    private func inventory(_ rows: String) -> Data { Data((",interface,state,\n" + rows).utf8) }
    private func details(address: String = "fd12:3456::1", connected: Bool = true, physical: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": [
            "identifier": "11111111-1111-1111-1111-111111111111",
            "properties": ["hardware": ["udid": udid, "reality": physical ? "physical" : "simulated"],
                "connection": ["state": connected ? "connected" : "disconnected", "pairingState": "paired", "tunnelIPAddressString": address]]
        ]])
    }

    @Test func exactAddressAndLiveAppleOwnerAreRequired() throws {
        let bytes = inventory("""
        remoted.123,,,
        tcp6 fd12:3456::2.50000<->fd12:3456::1.51000,utun4,Established,
        tcp6 fd12:3456::2.50001<->fd12:3456::9.52000,utun4,Established,
        tcp6 fd12:3456::2.50002<->*.*,utun4,Listen,
        unrelated.234,,,
        tcp6 fd12:3456::2.50003<->fd12:3456::1.53000,utun4,Established,
        """)
        #expect(try RSDPortDiscovery.candidate(in: bytes, tunnelAddress: "fd12:3456:0:0:0:0:0:1", isRemoted: { $0 == 123 }) == 51000)
        #expect(throws: CommandFailure.self) { try RSDPortDiscovery.candidate(in: bytes, tunnelAddress: address, isRemoted: { _ in false }) }
        #expect(ADCIsRemotedProcess(0) == 0)
        #expect(ADCIsRemotedProcess(-1) == 0)
    }

    @Test func duplicateRowsDeduplicateButDifferentPortsAreAmbiguous() throws {
        let row = "tcp6 fd12:3456::2.50000<->fd12:3456::1.51000,utun4,Established,\n"
        #expect(try RSDPortDiscovery.candidate(in: inventory("remoted.123,,,\n" + row + row), tunnelAddress: address, isRemoted: { _ in true }) == 51000)
        #expect(throws: CommandFailure.self) {
            try RSDPortDiscovery.candidate(in: inventory("remoted.123,,,\n" + row + row.replacingOccurrences(of: "51000", with: "51001")), tunnelAddress: address, isRemoted: { _ in true })
        }
    }

    @Test func staleOwnerContextAndUnestablishedSocketsCannotSelectAPort() {
        for rows in [
            "tcp6 fd12:3456::2.50000<->fd12:3456::1.51000,utun4,Established,",
            "remoted.123,,,\nother.234,,,\ntcp6 fd12:3456::2.50000<->fd12:3456::1.51000,utun4,Established,",
            "remoted.123,,,\ntcp6 fd12:3456::2.50000<->fd12:3456::1.51000,utun4,CloseWait,",
            "remoted.123,,,\ntcp4 127.0.0.1:50000<->127.0.0.1:51000,lo0,Established,"
        ] {
            #expect(throws: CommandFailure.self) { try RSDPortDiscovery.candidate(in: inventory(rows), tunnelAddress: address, isRemoted: { _ in true }) }
        }
    }

    @Test func scopedLinkLocalAddressesRequireMatchingScopes() throws {
        let bytes = inventory("remoted.123,,,\ntcp6 fe80::2%4.50000<->fe80::1%4.51000,utun4,Established,")
        #expect(try RSDPortDiscovery.candidate(in: bytes, tunnelAddress: "fe80::1%4", isRemoted: { _ in true }) == 51000)
        for address in ["fe80::1", "fe80::1%5", "fe80::1%", "::", "::1", "::ffff:192.0.2.1", "ff02::1", "127.0.0.1", "bad"] {
            #expect(throws: CommandFailure.self) { try RSDPortDiscovery.candidate(in: bytes, tunnelAddress: address, isRemoted: { _ in true }) }
        }
    }

    @Test func invalidInventoryAndPortsFailClosed() {
        var samples = [Data([0xff]), Data("wrong-header\n".utf8), Data(repeating: 32, count: 1024 * 1024 + 1),
            inventory("remoted.123,,,\nmalformed,row")]
        for port in ["0", "65536", "-1", "+51000", "abc"] {
            samples.append(inventory("remoted.123,,,\ntcp6 fd12:3456::2.50000<->fd12:3456::1.\(port),utun4,Established,"))
        }
        samples.append(inventory("remoted.123,,,\ntcp6 fd12:3456::2.50000<->bad.123,utun4,Established,"))
        samples.append(inventory(String(repeating: "other.234,,,\n", count: 16385)))
        for bytes in samples {
            #expect(throws: CommandFailure.self) { try RSDPortDiscovery.candidate(in: bytes, tunnelAddress: address, isRemoted: { _ in true }) }
        }
    }

    @Test func tunnelComesFromFreshPairedPhysicalHardwareDetails() throws {
        #expect(try RSDPortDiscovery.tunnelAddress(details: details(), expectedUDID: udid) == address)
        for data in [try details(connected: false), try details(physical: false), try details(address: "::1"), Data("{}".utf8)] {
            #expect(throws: CommandFailure.self) { try RSDPortDiscovery.tunnelAddress(details: data, expectedUDID: udid) }
        }
        for requested in ["alias", "11111111-1111-1111-1111-111111111111", "00000000-0000000000000002"] {
            #expect(throws: CommandFailure.self) { try RSDPortDiscovery.tunnelAddress(details: details(), expectedUDID: requested) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_PORT_DEVICE"] != nil))
    func explicitLiveDeviceHasOneCurrentRemotedPortWithoutServiceConnection() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_RSD_PORT_DEVICE"])
        let input = CoreDeviceInput(device: device, operation: "tree", operands: [])
        let plan = try input.identityPlan()
        func currentAddress() throws -> String {
            try RSDPortDiscovery.tunnelAddress(details: ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20), expectedUDID: device)
        }
        let address = try currentAddress()
        let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
        guard try currentAddress() == address else { throw CommandFailure(description: "Tunnel changed during discovery; candidate discarded.") }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/rsd-port-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["device": device, "tunnelAddress": address, "candidatePort": port,
            "source": "Apple nettop; exact remoted executable path", "serviceConnectionStarted": false, "hardwareHandshakeVerified": false]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        #expect(port > 0)
    }
}
