import Darwin
import Foundation

struct NativeMediaEndpoint: Sendable {
    struct Interface: Sendable {
        let name: String
        let address: String
        let mask: [UInt8]
        let up: Bool
    }
    let uuid: String
    let interface: String
    let host: String
    let device: String

    static func resolve(details: Data, inventory: Data, requested: String, interfaces: [Interface]? = nil) throws -> Self {
        try DeviceReadiness.decode(details, device: requested).requireDeveloperMode(operation: "record screen")
        let uuid = try CoreDeviceInput.resolve(details, requested: requested)
        guard let value = try JSONSerialization.jsonObject(with: inventory) as? [String: Any],
              (value["info"] as? [String: Any])?["outcome"] as? String == "success",
              let devices = (value["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            throw CommandFailure(.toolFailed, "Cannot read CoreDevice tunnel inventory.", inputSent: .none)
        }
        let matches = devices.filter { ($0["identifier"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame }
        guard matches.count == 1, let properties = matches[0]["connectionProperties"] as? [String: Any],
              properties["tunnelState"] as? String == "connected", let device = properties["tunnelIPAddress"] as? String,
              let bytes = ipv6(device) else {
            throw CommandFailure(.deviceNotReady, "CoreDevice did not identify one connected IPv6 media tunnel for this device.", inputSent: .none)
        }
        let addresses = try interfaces ?? systemInterfaces()
        let prefixMask = Array(repeating: UInt8(255), count: 8) + Array(repeating: UInt8(0), count: 8)
        let hosts = addresses.filter { candidate in
            guard candidate.up, candidate.name.hasPrefix("utun"), candidate.mask == prefixMask,
                  let address = ipv6(candidate.address) else { return false }
            return address != bytes && address.prefix(8) == bytes.prefix(8)
        }
        guard hosts.count == 1 else {
            throw CommandFailure(.transportFailed, "Expected exactly one active host utun address matching the device's /64; found \(hosts.count).", inputSent: .none)
        }
        return Self(uuid: uuid, interface: hosts[0].name, host: hosts[0].address, device: device)
    }

    private static func ipv6(_ string: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, string, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func systemInterfaces() throws -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw CommandFailure(.hostRequirement, "Cannot enumerate host tunnel interfaces.", inputSent: .none) }
        defer { freeifaddrs(first) }
        var result: [Interface] = []
        var current = first
        while let pointer = current {
            let value = pointer.pointee
            current = value.ifa_next
            guard let address = value.ifa_addr, let mask = value.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET6), mask.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let rawMask = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
            let addressText = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(Interface(name: String(cString: value.ifa_name), address: addressText,
                mask: withUnsafeBytes(of: rawMask) { Array($0) }, up: value.ifa_flags & UInt32(IFF_UP) != 0))
        }
        return result
    }
}
