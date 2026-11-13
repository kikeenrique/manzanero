import AppleDeviceBridge
import Darwin
import Foundation

/// Own on one task, retain while using advertised services, then close explicitly.
/// The product selects Network transport; connected-FD remains diagnostic.
/// No retry or alternate-transport fallback is attempted.
final class RSDDirectoryConnection {
    enum Transport: String { case connectedFD = "connected-fd", network }
    let accessibilityPort: UInt16
    private var owner: UnsafeMutableRawPointer?
    private let tunnelAddress: String
    private var serviceOpened = false

    init(tunnelAddress: String, port: UInt16, expectedUDID: String, transport: Transport = .connectedFD) throws {
        try Task.checkCancellation()
        guard expectedUDID.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil else {
            throw CommandFailure(description: "RSD directory requires an explicit hardware UDID; no connection started.")
        }
        _ = try RSDPortDiscovery.socketAddress(tunnelAddress, port: port)
        let host = try Self.localPeerUUID(in: ToolRunner().run(["dumpstate"], executable: "/usr/libexec/remotectl", timeout: 5))
        var owner: UnsafeMutableRawPointer?
        var servicePort: UInt16 = 0
        var error = [CChar](repeating: 0, count: 1024)
        // Native bootstrap flags come from Apple's failsafe getter. These flags
        // are only the host's RSD capability advertisement. Connected-FD mode
        // remains separate from Apple's unstarted Network-connection mode.
        let status: Int32
        switch transport {
        case .connectedFD:
            let descriptor = try Self.connect(address: tunnelAddress, port: port)
            status = ADCOpenRSDDirectory(descriptor, expectedUDID, host, 0x0100000000000006, 0,
                { Task.isCancelled ? 1 : 0 }, &servicePort, &owner, &error, error.count)
        case .network:
            var target = try RSDPortDiscovery.socketAddress(tunnelAddress, port: port)
            status = withUnsafePointer(to: &target) {
                ADCOpenRSDDirectoryNetwork($0, MemoryLayout<sockaddr_in6>.size, expectedUDID, host, 0x0100000000000006,
                    { Task.isCancelled ? 1 : 0 }, &servicePort, &owner, &error, error.count)
            }
        }
        if Task.isCancelled {
            ADCCloseRSDDirectory(owner)
            throw CancellationError()
        }
        guard status == 0, let owner, servicePort > 0 else {
            ADCCloseRSDDirectory(owner)
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.owner = owner
        self.tunnelAddress = tunnelAddress
        accessibilityPort = servicePort
    }

    static func localPeerUUID(in dump: Data) throws -> String {
        guard dump.count <= 4 * 1024 * 1024, let text = String(data: dump, encoding: .utf8) else {
            throw CommandFailure(description: "Invalid or oversized Apple RSD host inventory; no connection started.")
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2, lines[0] == "Local device",
              lines[1].trimmingCharacters(in: .whitespaces).hasPrefix("UUID: "),
              let uuid = UUID(uuidString: String(lines[1].trimmingCharacters(in: .whitespaces).dropFirst(6))) else {
            throw CommandFailure(description: "Apple RSD host identity was not available; no connection started.")
        }
        return uuid.uuidString
    }

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
            throw CommandFailure(description: "RSD directory is closed, failed or already has an AX service owner; no new service connection started.")
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

    private static func connect(address: String, port: UInt16) throws -> Int32 {
        var target = try RSDPortDiscovery.socketAddress(address, port: port)
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
                guard ContinuousClock.now < deadline else { throw CommandFailure(description: "RSD TCP connection exceeded its eight-second deadline.") }
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
