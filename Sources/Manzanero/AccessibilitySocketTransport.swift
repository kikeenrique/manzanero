import AppleDeviceBridge
import Darwin
import Foundation

/// Consumes one stream descriptor and its optional RSD directory. Confine it
/// to a single session; neither the descriptor nor this object may be shared.
final class AccessibilitySocketTransport: AccessibilitySessionTransport {
    enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case deadline
        case closed
        case system(String, Int32)

        var description: String {
            switch self {
            case .deadline: return "Accessibility socket deadline exceeded."
            case .closed: return "Accessibility socket closed or reached EOF."
            case .system(let operation, let code): return "Accessibility socket \(operation): \(String(cString: strerror(code))) (\(code))."
            }
        }
    }

    private var descriptor: Int32
    private var directory: RSDDirectoryConnection?
    var isClosed: Bool { descriptor < 0 }

    /// Ownership transfers even when setup throws. Never close or reuse the
    /// original descriptor after calling this initializer.
    init(taking descriptor: Int32, directory: RSDDirectoryConnection? = nil) throws {
        self.descriptor = descriptor
        self.directory = directory
        do {
            guard descriptor >= 0 else { throw Failure.closed }
            var type: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: type))
            guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0 else { throw Failure.system("get socket type", errno) }
            guard type == SOCK_STREAM else { throw CommandFailure(.internal, "Accessibility transport requires a stream socket.", inputSent: .unknown) }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.system("set nonblocking mode", errno) }
            let fdFlags = fcntl(descriptor, F_GETFD)
            guard fdFlags >= 0, fcntl(descriptor, F_SETFD, fdFlags | FD_CLOEXEC) == 0 else { throw Failure.system("set close-on-exec", errno) }
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw Failure.system("disable SIGPIPE", errno)
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        let savedDescriptor = descriptor
        descriptor = -1
        if savedDescriptor >= 0 { ADCCloseAccessibilitySocket(savedDescriptor) }
        directory?.close()
        directory = nil
    }

    func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
        var transferred = 0
        do {
            return try AccessibilityDTX.read { count in
                var bytes = Data(count: count)
                var offset = 0
                while offset < count {
                    try wait(for: Int16(POLLIN), until: deadline, cancelled: cancelled)
                    let received = bytes.withUnsafeMutableBytes { buffer in
                        recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                    }
                    if received > 0 {
                        offset += received
                        transferred += received
                    } else if received == 0 {
                        throw Failure.closed
                    } else {
                        let code = errno
                        if code != EINTR && code != EAGAIN && code != EWOULDBLOCK { throw Failure.system("receive", code) }
                    }
                }
                try check(deadline, cancelled: cancelled)
                return bytes
            }
        } catch {
            invalidate(after: error, transferred: transferred)
            throw error
        }
    }

    func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
        let bytes = try message.encoded()
        var transferred = 0
        do {
            while transferred < bytes.count {
                try wait(for: Int16(POLLOUT), until: deadline, cancelled: cancelled)
                let sent = bytes.withUnsafeBytes { buffer in
                    send(descriptor, buffer.baseAddress!.advanced(by: transferred), bytes.count - transferred, 0)
                }
                if sent > 0 { transferred += sent }
                else if sent == 0 { throw Failure.closed }
                else {
                    let code = errno
                    if code != EINTR && code != EAGAIN && code != EWOULDBLOCK { throw Failure.system("send", code) }
                }
            }
            try check(deadline, cancelled: cancelled)
        } catch {
            invalidate(after: error, transferred: transferred, frameComplete: transferred == bytes.count)
            throw error
        }
    }

    private func invalidate(after error: any Error, transferred: Int, frameComplete: Bool = false) {
        // A partial frame cannot be followed by a disable frame or resumed as a
        // fresh read. Cancellation/deadline at a frame boundary (no bytes yet,
        // or a completely written frame) preserves bounded session cleanup.
        if (transferred > 0 && !frameComplete) || (!(error is CancellationError) && (error as? Failure) != .deadline) { close() }
    }

    private func check(_ deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
        guard descriptor >= 0 else { throw Failure.closed }
        if cancelled() { throw CancellationError() }
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
    }

    private func wait(for event: Int16, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
        while true {
            try check(deadline, cancelled: cancelled)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
            let interval = Int32(max(1, min(10, ceil(milliseconds))))
            var descriptor = pollfd(fd: self.descriptor, events: event, revents: 0)
            let status = poll(&descriptor, 1, interval)
            let pollError = errno
            try check(deadline, cancelled: cancelled)
            if status < 0 {
                if pollError == EINTR { continue }
                throw Failure.system("poll", pollError)
            }
            if status == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw Failure.closed }
            // On read, HUP can accompany final buffered bytes. Let recv drain
            // them; a subsequent zero read reports EOF. send reports EPIPE.
            if descriptor.revents & (event | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
        }
    }
}
