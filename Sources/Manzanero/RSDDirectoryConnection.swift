import AppleDeviceBridge
import Darwin
import Foundation

/// Own on one task, retain while using advertised services, then close explicitly.
/// Uses Apple's Network/RemoteXPC directory bootstrap; no retry or fallback.
final class RSDDirectoryConnection {
    let accessibilityPort: UInt16
    private var owner: UnsafeMutableRawPointer?
    private let tunnelAddress: String
    private var serviceOpened = false

    /// `relayed`: the address is the loopback end of a relay of the tool's
    /// own tunnel, not a device's tunnel address.
    init(tunnelAddress: String, port: UInt16, expectedUDID: String, relayed: Bool = false) throws {
        try Task.checkCancellation()
        guard expectedUDID.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil else {
            throw CommandFailure(.internal, "RSD directory requires an explicit hardware UDID; no connection started.", inputSent: .none)
        }
        _ = try RSDPortDiscovery.socketAddress(tunnelAddress, port: port, relayed: relayed)
        let host = try Self.localPeerUUID(in: ToolRunner().run(["dumpstate"], executable: "/usr/libexec/remotectl", timeout: 5))
        var owner: UnsafeMutableRawPointer?
        var servicePort: UInt16 = 0
        var error = [CChar](repeating: 0, count: 1024)
        // Native bootstrap flags come from Apple's failsafe getter. These flags
        // are only the host's RSD capability advertisement.
        var target = try RSDPortDiscovery.socketAddress(tunnelAddress, port: port, relayed: relayed)
        let status = withUnsafePointer(to: &target) {
            ADCOpenRSDDirectoryNetwork($0, MemoryLayout<sockaddr_in6>.size, expectedUDID, host, 0x0100000000000006,
                { Task.isCancelled ? 1 : 0 }, &servicePort, &owner, &error, error.count)
        }
        if Task.isCancelled {
            ADCCloseRSDDirectory(owner)
            throw CancellationError()
        }
        guard status == 0, let owner, servicePort > 0 else {
            ADCCloseRSDDirectory(owner)
            throw CommandFailure(.transportFailed, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        self.owner = owner
        self.tunnelAddress = tunnelAddress
        accessibilityPort = servicePort
    }

    static func localPeerUUID(in dump: Data) throws -> String {
        guard dump.count <= 4 * 1024 * 1024, let text = String(data: dump, encoding: .utf8) else {
            throw CommandFailure(.toolFailed, "Invalid or oversized Apple RSD host inventory; no connection started.", inputSent: .none)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2, lines[0] == "Local device",
              lines[1].trimmingCharacters(in: .whitespaces).hasPrefix("UUID: "),
              let uuid = UUID(uuidString: String(lines[1].trimmingCharacters(in: .whitespaces).dropFirst(6))) else {
            throw CommandFailure(.toolFailed, "Apple RSD host identity was not available; no connection started.", inputSent: .none)
        }
        return uuid.uuidString
    }

    /// Whether the directory connection is still open and has not failed.
    var isActive: Bool { owner.map { ADCIsRSDDirectoryActive($0) == 1 } ?? false }

    deinit { close() }
    func close() {
        let saved = owner
        owner = nil
        ADCCloseRSDDirectory(saved)
    }

    /// Transfers lifetime responsibility to the one owned AX transport. It must
    /// close its service socket before releasing the directory connection.
    func openAccessibility() throws -> AccessibilitySocketTransport {
        guard let owner, !serviceOpened, ADCIsRSDDirectoryActive(owner) == 1 else {
            throw CommandFailure(.transportFailed, "RSD directory is closed, failed or already has an AX service owner; no new service connection started.", inputSent: .none)
        }
        serviceOpened = true
        do {
            let descriptor = try Self.connect(address: tunnelAddress, port: accessibilityPort)
            return try AccessibilitySocketTransport(taking: descriptor, directory: self)
        } catch {
            close()
            throw error
        }
    }

    /// Connects to the accessibility service on a port an earlier directory
    /// of the same tunnel gave, without opening a directory again.
    static func openAccessibility(tunnelAddress: String, port: UInt16, relayed: Bool = false) throws -> AccessibilitySocketTransport {
        try AccessibilitySocketTransport(taking: connect(address: tunnelAddress, port: port, relayed: relayed))
    }

    /// Connects to one lockdown shim service the directory advertises (a
    /// name ending in `.shim.remote`), such as the log relay. The caller owns
    /// the returned blocking stream descriptor and closes it before this
    /// directory. For a directory read over Apple's tunnel; on the tool's own
    /// tunnel, relay `shimServicePort` instead.
    func openShimService(_ name: String) throws -> Int32 {
        try Self.connect(address: tunnelAddress, port: shimServicePort(name))
    }

    /// The device port the directory advertises for one shim service.
    func shimServicePort(_ name: String) throws -> UInt16 {
        guard let owner, ADCIsRSDDirectoryActive(owner) == 1 else {
            throw CommandFailure(.transportFailed, "RSD directory is closed or failed; no service connection started.", inputSent: .none)
        }
        var port: UInt16 = 0
        var error = [CChar](repeating: 0, count: 512)
        guard ADCCopyRSDShimServicePort(owner, name, &port, &error, error.count) == 0, port > 0 else {
            throw CommandFailure(.transportFailed, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        return port
    }

    /// A blocking stream socket to a device port: on Apple's tunnel, or on
    /// the loopback end of a relay of the tool's own (`relayed`).
    static func connectStream(address: String, port: UInt16, relayed: Bool) throws -> Int32 {
        try connect(address: address, port: port, relayed: relayed)
    }

    private static func connect(address: String, port: UInt16, relayed: Bool = false) throws -> Int32 {
        var target = try RSDPortDiscovery.socketAddress(address, port: port, relayed: relayed)
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        let flags = fcntl(descriptor, F_GETFL)
        var enabled: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Task.checkCancellation()
        let result = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw CommandFailure(.timeout, "RSD TCP connection exceeded its eight-second deadline.", inputSent: .none) }
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&event, 1, 10)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                var code: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: code))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &size) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                break
            }
        }
        try Task.checkCancellation()
        // Apple RemoteXPC takes over transport flags and the owned descriptor.
        guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        transferred = true
        return descriptor
    }
}
