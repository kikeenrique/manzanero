import AppleDeviceBridge
import Darwin
import Foundation

private actor RSDInventoryBuffer {
    var bytes = Data()
    func append(_ chunk: Data) { bytes.append(chunk) }
}

/// Candidate discovery only: an established remoted socket is not an RSD
/// handshake. The connection layer must verify the advertised hardware identity.
enum RSDPortDiscovery {
    private struct Address: Equatable {
        let bytes: [UInt8]
        let scope: UInt32

        init(_ text: String) throws {
            let parts = text.split(separator: "%", omittingEmptySubsequences: false)
            var address = in6_addr()
            guard parts.count <= 2, let host = parts.first,
                  inet_pton(AF_INET6, String(host), &address) == 1 else { throw failure("Invalid IPv6 tunnel address.") }
            bytes = withUnsafeBytes(of: address) { Array($0) }
            if parts.count == 2 {
                let zone = String(parts[1])
                scope = UInt32(zone) ?? if_nametoindex(zone)
                guard scope > 0 else { throw failure("Invalid IPv6 scope.") }
            } else { scope = 0 }
            guard bytes.contains(where: { $0 != 0 }), bytes != Array(repeating: 0, count: 15) + [1],
                  bytes[0] != 0xff,
                  !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff),
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && scope == 0) else {
                throw failure("Expected a unicast tunnel address with an explicit scope for link-local IPv6.")
            }
        }
    }

    static func tunnelAddress(details: Data, expectedUDID: String) throws -> String {
        guard expectedUDID.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil,
              details.count <= 1024 * 1024 else { throw failure("Provide an explicit hardware UDID and bounded device details.") }
        _ = try CoreDeviceInput.resolve(details, requested: expectedUDID)
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let properties = result["properties"] as? [String: Any],
              (properties["hardware"] as? [String: Any])?["reality"] as? String == "physical",
              let connection = properties["connection"] as? [String: Any],
              connection["state"] as? String == "connected", connection["pairingState"] as? String == "paired",
              let address = connection["tunnelIPAddressString"] as? String else {
            throw failure("Fresh details must identify a connected paired physical device and its tunnel address.", .deviceNotReady)
        }
        _ = try Address(address)
        return address
    }

    static func socketAddress(_ text: String, port: UInt16) throws -> sockaddr_in6 {
        let parsed = try Address(text)
        guard port > 0 else { throw failure("Invalid zero port.") }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_scope_id = parsed.scope
        withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: parsed.bytes) }
        return address
    }

    static func candidate(in inventory: Data, tunnelAddress: String,
                          isRemoted: (Int32) -> Bool = { ADCIsRemotedProcess($0) == 1 }) throws -> UInt16 {
        let target = try Address(tunnelAddress)
        guard inventory.count <= 1024 * 1024, let text = String(data: inventory, encoding: .utf8) else {
            throw failure("Invalid or oversized nettop inventory.")
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first == ",interface,state,", lines.count <= 16384 else {
            throw failure("Unexpected nettop CSV header or row count.")
        }
        var owner: Int32?
        var ports = Set<UInt16>()
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[3].isEmpty else { throw failure("Malformed nettop CSV row.") }
            let name = fields[0]
            if name.hasPrefix("tcp") {
                guard let owner, name.hasPrefix("tcp6 "), fields[2] == "Established" else { continue }
                guard let arrow = name.range(of: "<->"), let dot = name[arrow.upperBound...].lastIndex(of: "."),
                      name[name.index(after: dot)...].utf8.allSatisfy({ (48...57).contains($0) }),
                      let port = UInt16(name[name.index(after: dot)...]), port > 0 else {
                    throw failure("Malformed established remoted endpoint.")
                }
                let remote = try Address(String(name[arrow.upperBound..<dot]))
                if remote.bytes == target.bytes && (target.scope == 0 || target.scope == remote.scope) {
                    guard isRemoted(owner) else { throw failure("Socket owner is no longer Apple's remoted process.") }
                    ports.insert(port)
                }
            } else {
                owner = nil
                guard fields[1].isEmpty, fields[2].isEmpty, let dot = name.lastIndex(of: "."),
                      name[..<dot] == "remoted", name[name.index(after: dot)...].utf8.allSatisfy({ (48...57).contains($0) }),
                      let pid = Int32(name[name.index(after: dot)...]), pid > 0 else { continue }
                owner = pid
            }
        }
        guard ports.count == 1, let port = ports.first else {
            throw failure("Expected exactly one established remoted port for the exact current tunnel address; found \(ports.count).")
        }
        return port
    }

    static func discover(tunnelAddress: String) async throws -> UInt16 {
        try Task.checkCancellation()
        _ = try Address(tunnelAddress)
        let buffer = RSDInventoryBuffer()
        try await StreamingToolRunner().run(executable: "/usr/bin/nettop",
            arguments: ["-n", "-x", "-L", "1", "-m", "tcp", "-p", "remoted", "-J", "interface,state"],
            timeout: 10, maximumOutputBytes: 1024 * 1024, receive: { await buffer.append($0) })
        try Task.checkCancellation()
        return try candidate(in: await buffer.bytes, tunnelAddress: tunnelAddress)
    }

    /// Discovery reads local state only and starts no service connection.
    private static func failure(_ text: String, _ code: CommandFailure.Code = .transportFailed) -> CommandFailure {
        CommandFailure(code, "RSD port discovery: \(text) No service connection started.", inputSent: .none)
    }
}
