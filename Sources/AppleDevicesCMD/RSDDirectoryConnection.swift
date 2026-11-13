import AppleDeviceBridge
import Darwin
import Foundation

/// Own on one task, retain while using advertised services, then close explicitly.
/// This opt-in investigation path has no product routing or retry/fallback.
final class RSDDirectoryConnection {
    let accessibilityPort: UInt16
    private var owner: UnsafeMutableRawPointer?

    init(tunnelAddress: String, port: UInt16, expectedUDID: String) throws {
        try Task.checkCancellation()
        guard expectedUDID.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil else {
            throw CommandFailure(description: "RSD directory requires an explicit hardware UDID; no connection started.")
        }
        let descriptor = try Self.connect(address: tunnelAddress, port: port)
        var owner: UnsafeMutableRawPointer?
        var servicePort: UInt16 = 0
        var error = [CChar](repeating: 0, count: 1024)
        // Recorded Apple CoreDevice RemoteXPC version flags, not a new wire
        // encoder. This explicit probe does not retry other flag combinations.
        let status = ADCOpenRSDDirectory(descriptor, expectedUDID, 0x0100000000000006,
            { Task.isCancelled ? 1 : 0 }, &servicePort, &owner, &error, error.count)
        // The bridge consumes descriptor even if setup/validation fails.
        if Task.isCancelled {
            ADCCloseRSDDirectory(owner)
            throw CancellationError()
        }
        guard status == 0, let owner, servicePort > 0 else {
            ADCCloseRSDDirectory(owner)
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.owner = owner
        accessibilityPort = servicePort
    }

    deinit { close() }
    func close() {
        let saved = owner
        owner = nil
        ADCCloseRSDDirectory(saved)
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
