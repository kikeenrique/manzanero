import Darwin

/// Peer-side checks that a socket's other end has really been closed.
///
/// A `close()` drops only this process's reference. A child that another
/// parallel test is spawning (`fork`/`posix_spawn`) briefly holds a copy of the
/// whole descriptor table until it execs, close-on-exec descriptors included,
/// so the peer may observe the closure an instant later. These helpers wait for
/// the peer to observe it, and fail only if it never does within `timeout`.
enum SocketPeerClosure {
    /// Stream peer: waits until it reports EOF (a zero-length read). Fails if
    /// the peer reads data instead, or nothing happens before the timeout.
    static func streamReachesEOF(_ peer: Int32, timeout milliseconds: Int32 = 5000) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 10)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { return false }
            var byte: UInt8 = 0
            let count = recv(peer, &byte, 1, MSG_DONTWAIT)
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            return count == 0
        }
        return false
    }

    /// Datagram peer: waits until sending to the closed end fails. A send that
    /// succeeds only lands in the closing socket's buffer and is discarded with it.
    static func datagramSendFails(_ peer: Int32, timeout milliseconds: Int32 = 5000) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        var byte: UInt8 = 0
        while ContinuousClock.now < deadline {
            if send(peer, &byte, 1, MSG_NOSIGNAL) == -1 && errno != EINTR && errno != ENOBUFS { return true }
            usleep(1_000)
        }
        return false
    }
}
