import AppleDeviceBridge
import CLwIP
import Darwin
import Foundation

/// A tunnel of the tool's own to a device on its cable or on the network
/// (docs/transport.md#a-tunnel-of-the-tools-own).
///
/// Apple's MobileDevice framework opens the device's tunnel service with the
/// trust the Mac already has; the service then exchanges raw IPv6 packets,
/// and lwIP, in this process, turns them into TCP connections. On this
/// tunnel the tool is the device's only peer, so reading the device's
/// service directory here does not disturb the Mac's `remoted`, which the
/// route over Apple's tunnel does.
///
/// The rest of the tool reaches a device port through `relay(to:)`: a
/// listener on the loopback address that takes one connection and carries it
/// to that port, so code written for an address and a port needs no change.
///
/// lwIP keeps its state in globals: a process has one tunnel at a time, and
/// every lwIP call runs on `stack`.
final class DeviceTunnel: @unchecked Sendable {
    struct Info: Equatable, Sendable {
        let mtu: Int
        let serviceDirectoryPort: UInt16
        /// "cable" or "network": how the device was reached.
        let link: String
    }

    let info: Info
    private let owner: UnsafeMutableRawPointer
    private let serverAddress: [UInt8]
    private let stack = DispatchQueue(label: "manzanero.device-tunnel.stack")
    private let timer: DispatchSourceTimer
    private var relays: [ObjectIdentifier: Relay] = [:]
    private var closed = false

    /// The environment variable that turns the tunnel off for the
    /// accessibility commands, which use it by default: `0` to leave them
    /// on the route over Apple's tunnel.
    static let optOut = "MANZANERO_OWN_TUNNEL"

    /// Whether packets still arrive: false once the reader has seen the
    /// tunnel end (the cable pulled, the service closed).
    var isAlive: Bool { state.withLock { alive } }
    /// The accessibility service's port on this tunnel, once its directory
    /// has been read.
    var accessibilityPort: UInt16? {
        get { state.withLock { servicePort } }
        set { state.withLock { servicePort = newValue } }
    }
    private var servicePort: UInt16?
    private let state = NSLock()
    private var alive = true
    private let readerFinished = DispatchSemaphore(value: 0)

    private static let single = NSLock()
    nonisolated(unsafe) private static var open = false

    /// Opens the tunnel. Nothing is sent on it until a relay is used.
    init(device udid: String) throws {
        guard Self.single.withLock({ () -> Bool in
            if Self.open { return false }
            Self.open = true
            return true
        }) else {
            throw CommandFailure(.deviceBusy, "This process already has a device tunnel open; one at a time. Nothing was contacted.", inputSent: .none)
        }
        var raw = ADCDeviceTunnelInfo()
        var handle: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 1024)
        guard ADCOpenDeviceTunnel(udid, &raw, &handle, &error, error.count) == 0, let handle else {
            Self.single.withLock { Self.open = false }
            throw CommandFailure(.deviceNotReady, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        owner = handle
        info = Info(mtu: Int(raw.mtu), serviceDirectoryPort: raw.serviceDirectoryPort, link: raw.overNetwork == 1 ? "network" : "cable")
        serverAddress = withUnsafeBytes(of: raw.serverAddress) { Array($0) }
        let local = withUnsafeBytes(of: raw.clientAddress) { Array($0) }
        timer = DispatchSource.makeTimerSource(queue: stack)
        // The bridge's owner is safe to use from the reader's thread and the
        // stack's queue at once: one receives, the other sends.
        nonisolated(unsafe) let context = handle
        let started = stack.sync {
            ADLStart(local, raw.mtu, { context, packet, length in ADCDeviceTunnelSend(context, packet, length) }, context)
        }
        guard started == 0 else {
            ADCReleaseDeviceTunnel(handle)
            Self.single.withLock { Self.open = false }
            throw CommandFailure(.internal, "The user-space network stack did not start; the tunnel was closed.", inputSent: .none)
        }
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { ADLPoll() }
        timer.resume()
        // Packets from the device, one blocking read at a time on a thread
        // of its own, handed to the stack's queue.
        let stack = stack
        let finished = readerFinished
        let reader = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let length = ADCDeviceTunnelReceive(context, &buffer, buffer.count)
                guard length > 0 else { break }
                let packet = Array(buffer[0..<length])
                stack.async { _ = ADLInput(packet, packet.count) }
            }
            if let self { self.state.withLock { self.alive = false } }
            finished.signal()
        }
        reader.name = "manzanero.device-tunnel.reader"
        reader.start()
    }

    deinit { close() }

    /// Closes every relay, the stack's interface and the tunnel.
    func close() {
        let already = stack.sync { () -> Bool in
            if closed { return true }
            closed = true
            for relay in relays.values { relay.end() }
            relays.removeAll()
            timer.cancel()
            ADLStop()
            return false
        }
        guard !already else { return }
        // Ending the service connection unblocks the reader; the bridge's
        // owner is freed only once the reader has left it. A reader that
        // does not leave within two seconds keeps it, a small leak instead
        // of a use after free.
        ADCCloseDeviceTunnel(owner)
        if readerFinished.wait(timeout: .now() + .seconds(2)) == .success { ADCReleaseDeviceTunnel(owner) }
        Self.single.withLock { Self.open = false }
    }

    /// A listener on the loopback address that takes one connection and
    /// carries it to `port` on the device. Returns the local port. The
    /// listener is closed once that connection is accepted or after ten
    /// seconds.
    func relay(to port: UInt16) throws -> UInt16 {
        let listener = socket(AF_INET6, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listener, generic, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, generic, &length) == 0
            }
        }
        guard bound, fcntl(listener, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let localPort = UInt16(bigEndian: address.sin6_port)
        let relay = Relay(tunnel: self, port: port)
        stack.sync { relays[ObjectIdentifier(relay)] = relay }
        let acceptor = Thread { [weak self] in
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 10_000)
            let accepted = ready > 0 ? accept(listener, nil, nil) : -1
            Darwin.close(listener)
            guard accepted >= 0, let self else {
                if accepted >= 0 { Darwin.close(accepted) }
                return
            }
            var enabled: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            relay.run(local: accepted, on: self.stack, server: self.serverAddress)
        }
        acceptor.name = "manzanero.device-tunnel.relay"
        acceptor.start()
        return localPort
    }

    fileprivate func forget(_ relay: Relay) {
        relays[ObjectIdentifier(relay)] = nil
    }

    /// One local connection carried to one device port.
    fileprivate final class Relay: @unchecked Sendable {
        private weak var tunnel: DeviceTunnel?
        private let port: UInt16
        private var local: Int32 = -1
        private var connection: OpaquePointer?
        /// Bytes read from the local side that lwIP has not taken yet.
        private var pending: [UInt8] = []
        private let room = DispatchSemaphore(value: 0)
        private var ended = false
        private var stack: DispatchQueue?

        init(tunnel: DeviceTunnel, port: UInt16) {
            self.tunnel = tunnel
            self.port = port
        }

        /// Called on the acceptor's thread: starts the device connection and
        /// then reads the local side until it ends.
        func run(local descriptor: Int32, on stack: DispatchQueue, server: [UInt8]) {
            self.stack = stack
            local = descriptor
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callbacks = ADLCallbacks(context: context,
                connected: { _ in },
                received: { context, bytes, length in
                    guard let context, let bytes else { return }
                    Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue().deliver(bytes, length)
                },
                finished: { context in
                    guard let context else { return }
                    Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue().peerFinished()
                },
                failed: { context, _ in
                    guard let context else { return }
                    Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue().failed()
                })
            let started = stack.sync { () -> Bool in
                guard !ended else { return false }
                connection = ADLConnect(server, port, callbacks)
                return connection != nil
            }
            guard started else {
                Darwin.close(descriptor)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let got = read(descriptor, &buffer, buffer.count)
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { break }
                let chunk = Array(buffer[0..<got])
                stack.async { self.send(chunk) }
                // One chunk in flight at a time, so memory stays bounded.
                room.wait()
                if stack.sync(execute: { ended }) { break }
            }
            stack.sync { end() }
        }

        /// On the stack's queue: queues bytes for the device.
        private func send(_ chunk: [UInt8]) {
            pending += chunk
            flush()
        }

        /// On the stack's queue: gives lwIP as much of `pending` as it takes.
        private func flush() {
            guard let connection, !ended else {
                pending.removeAll()
                room.signal()
                return
            }
            while !pending.isEmpty {
                let taken = ADLWrite(connection, pending, pending.count)
                if taken < 0 {
                    end()
                    room.signal()
                    return
                }
                if taken == 0 {
                    // The send buffer is full: try again shortly.
                    stack?.asyncAfter(deadline: .now() + .milliseconds(5)) { self.flush() }
                    return
                }
                pending.removeFirst(taken)
            }
            room.signal()
        }

        /// On the stack's queue: bytes from the device, written to the local side.
        private func deliver(_ bytes: UnsafePointer<UInt8>, _ length: Int) {
            guard local >= 0, !ended else { return }
            var done = 0
            while done < length {
                let wrote = write(local, bytes + done, length - done)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else {
                    end()
                    return
                }
                done += wrote
            }
            if let connection { ADLAcknowledge(connection, length) }
        }

        /// On the stack's queue: the device closed its side.
        private func peerFinished() {
            if local >= 0 { shutdown(local, SHUT_WR) }
        }

        /// On the stack's queue: lwIP has already freed the connection.
        private func failed() {
            connection = nil
            end()
        }

        /// On the stack's queue: closes both sides once.
        func end() {
            guard !ended else { return }
            ended = true
            if let connection { ADLClose(connection) }
            connection = nil
            if local >= 0 {
                shutdown(local, SHUT_RDWR)
                Darwin.close(local)
                local = -1
            }
            pending.removeAll()
            room.signal()
            tunnel?.forget(self)
        }
    }
}
