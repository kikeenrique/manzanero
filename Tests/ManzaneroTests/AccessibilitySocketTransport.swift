import Darwin
import Foundation
import Synchronization
import Testing
@testable import Manzanero

/// Runs blocking socket work on a thread started synchronously by the caller.
/// The transport polls against real deadlines, so running either peer as a
/// Swift concurrency task would make its progress depend on a free pool thread,
/// which a loaded runner with few cores does not guarantee.
private final class DedicatedThread<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var waiter: CheckedContinuation<Value, any Error>?
    }

    private let state = Mutex(State())

    init(_ body: @escaping @Sendable () throws -> Value) {
        Thread { [self] in
            let result = Result { try body() }
            self.state.withLock { state in
                state.result = result
                return state.waiter.take()
            }?.resume(with: result)
        }.start()
    }

    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let finished: Result<Value, any Error>? = state.withLock { state in
                    if state.result == nil { state.waiter = continuation }
                    return state.result
                }
                if let finished { continuation.resume(with: finished) }
            }
        }
    }
}

// Synchronous bodies poll real sockets against real deadlines; each test gets
// its own thread so that blocking never holds a cooperative pool thread.
@Suite(.dedicatedThread)
struct AccessibilitySocketTransportTests {
    private func pair(type: Int32 = SOCK_STREAM) throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, type, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
        return (descriptors[0], descriptors[1])
    }

    private func acknowledgement(_ id: UInt32) -> AccessibilityDTX {
        AccessibilityDTX(identifier: id, conversation: 1, channel: 0, expectsReply: false,
            kind: .acknowledgement, auxiliary: Data(), object: Data())
    }

    private func sendFixture(_ bytes: Data, to descriptor: Int32) throws {
        let count = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        #expect(count == bytes.count)
        guard count == bytes.count else { throw POSIXError(.EIO) }
    }

    @Test func ownsStreamFlagsAndConsumesExactlyOneFrameAtATime() throws {
        let (owned, peer) = try pair()
        defer { Darwin.close(peer) }
        let transport = try AccessibilitySocketTransport(taking: owned)
        defer { transport.close() }
        #expect(fcntl(owned, F_GETFL) & O_NONBLOCK != 0)
        #expect(fcntl(owned, F_GETFD) & FD_CLOEXEC != 0)
        var enabled: Int32 = 0
        var size = socklen_t(MemoryLayout.size(ofValue: enabled))
        #expect(getsockopt(owned, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size) == 0 && enabled == 1)
        let first = try acknowledgement(1).encoded(), second = try acknowledgement(2).encoded()
        try sendFixture(first + second, to: peer)
        #expect(try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { false }).identifier == 1)
        #expect(try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { false }).identifier == 2)
        try transport.write(acknowledgement(3), until: .now.advanced(by: .seconds(1)), cancelled: { false })
        var received = Data(count: 48)
        let count = received.withUnsafeMutableBytes { recv(peer, $0.baseAddress, $0.count, 0) }
        let expected = try acknowledgement(3).encoded()
        #expect(count == 48 && received == expected)
        transport.close()
        transport.close()
        // A closed descriptor number may already belong to another parallel
        // test. The still-owned peer observes this socket's actual closure.
        #expect(transport.isClosed && SocketPeerClosure.streamReachesEOF(peer))
    }

    @Test func cancellationAndExpiryAtFrameBoundaryKeepCleanupPossible() throws {
        let (owned, peer) = try pair()
        defer { Darwin.close(peer) }
        let transport = try AccessibilitySocketTransport(taking: owned)
        defer { transport.close() }
        #expect(throws: CancellationError.self) {
            try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { true })
        }
        #expect(throws: AccessibilitySocketTransport.Failure.deadline) {
            try transport.read(until: .now.advanced(by: .milliseconds(25)), cancelled: { false })
        }
        #expect(transport.isClosed == false)
        try sendFixture(acknowledgement(4).encoded(), to: peer)
        #expect(try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { false }).identifier == 4)
    }

    @Test func partialReadTimeoutClosesInsteadOfReusingAnIncompleteFrame() throws {
        let (owned, peer) = try pair()
        defer { Darwin.close(peer) }
        let transport = try AccessibilitySocketTransport(taking: owned)
        try sendFixture(Data(try acknowledgement(1).encoded().prefix(20)), to: peer)
        #expect(throws: AccessibilitySocketTransport.Failure.deadline) {
            try transport.read(until: .now.advanced(by: .milliseconds(25)), cancelled: { false })
        }
        #expect(transport.isClosed)
        #expect(throws: AccessibilitySocketTransport.Failure.closed) {
            try transport.write(acknowledgement(2), until: .now.advanced(by: .seconds(1)), cancelled: { false })
        }
    }

    @Test func cancellationAfterACompleteWritePreservesTheCleanupBoundary() throws {
        let (owned, peer) = try pair()
        defer { Darwin.close(peer) }
        let transport = try AccessibilitySocketTransport(taking: owned)
        defer { transport.close() }
        #expect(throws: CancellationError.self) {
            try transport.write(acknowledgement(1), until: .now.advanced(by: .seconds(1)), cancelled: {
                // Cancel once the peer can observe the transmitted frame,
                // independently of how often the transport polls cancellation.
                var byte: UInt8 = 0
                return recv(peer, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
            })
        }
        #expect(transport.isClosed == false)
        var received = Data(count: 48)
        let count = received.withUnsafeMutableBytes { recv(peer, $0.baseAddress, $0.count, 0) }
        let expected = try acknowledgement(1).encoded()
        #expect(count == 48 && received == expected)
        try transport.write(acknowledgement(2), until: .now.advanced(by: .seconds(1)), cancelled: { false })
    }

    @Test func partialBodyCancellationClosesTheStream() throws {
        let (owned, peer) = try pair()
        defer { Darwin.close(peer) }
        let transport = try AccessibilitySocketTransport(taking: owned)
        try sendFixture(Data(try acknowledgement(1).encoded().prefix(32)), to: peer)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { checks += 1; return checks > 12 })
        }
        #expect(transport.isClosed)
    }

    @Test func stalledPartialWriteClosesAndClosedPeerDoesNotRaiseSIGPIPE() throws {
        let (owned, peer) = try pair()
        let transport = try AccessibilitySocketTransport(taking: owned)
        var size: Int32 = 1024
        #expect(setsockopt(owned, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0)
        let large = AccessibilityDTX(identifier: 1, conversation: 0, channel: 0, expectsReply: false,
            kind: .object, auxiliary: Data(), object: Data(count: 8 * 1024 * 1024))
        #expect(throws: AccessibilitySocketTransport.Failure.deadline) {
            try transport.write(large, until: .now.advanced(by: .milliseconds(200)), cancelled: { false })
        }
        #expect(transport.isClosed)
        Darwin.close(peer)
        let (other, closedPeer) = try pair()
        let second = try AccessibilitySocketTransport(taking: other)
        Darwin.close(closedPeer)
        // Wait until the closure is visible from this end; a child spawned by
        // a parallel test can hold the peer open for an instant.
        #expect(SocketPeerClosure.streamReachesEOF(other))
        #expect(throws: (any Error).self) {
            try second.write(acknowledgement(2), until: .now.advanced(by: .seconds(1)), cancelled: { false })
        }
        #expect(second.isClosed)
    }

    @Test func EOFAndInvalidHeadersCloseWithoutReadingAnUnboundedBody() throws {
        let (owned, peer) = try pair()
        let transport = try AccessibilitySocketTransport(taking: owned)
        Darwin.close(peer)
        #expect(throws: AccessibilitySocketTransport.Failure.closed) {
            try transport.read(until: .now.advanced(by: .seconds(1)), cancelled: { false })
        }
        #expect(transport.isClosed)
        let (other, writer) = try pair()
        defer { Darwin.close(writer) }
        let second = try AccessibilitySocketTransport(taking: other)
        var header = Data(try acknowledgement(1).encoded().prefix(32))
        header.replaceSubrange(12..<16, with: [0xff, 0xff, 0xff, 0x7f])
        try sendFixture(header, to: writer)
        #expect(throws: CommandFailure.self) {
            try second.read(until: .now.advanced(by: .seconds(1)), cancelled: { false })
        }
        #expect(second.isClosed)
    }

    @Test func rejectsAndClosesNonStreamDescriptors() throws {
        let (owned, peer) = try pair(type: SOCK_DGRAM)
        defer { Darwin.close(peer) }
        #expect(throws: CommandFailure.self) { try AccessibilitySocketTransport(taking: owned) }
        #expect(SocketPeerClosure.datagramSendFails(peer))
        #expect(throws: AccessibilitySocketTransport.Failure.closed) { try AccessibilitySocketTransport(taking: -1) }
    }

    @Test func shortReadsAssembleOneCompleteFrame() async throws {
        let (owned, peer) = try pair()
        let bytes = try acknowledgement(13).encoded()
        let writer = DedicatedThread {
            defer { Darwin.close(peer) }
            for chunk in [Data(bytes.prefix(5)), Data(bytes[5..<21]), Data(bytes[21...])] {
                let sent = chunk.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
                guard sent == chunk.count else { throw POSIXError(.EIO) }
                usleep(3_000)
            }
        }
        let reader = DedicatedThread {
            let transport = try AccessibilitySocketTransport(taking: owned)
            defer { transport.close() }
            return try transport.read(until: .now.advanced(by: .seconds(2)), cancelled: { false }).identifier
        }
        #expect(try await reader.value == 13)
        try await writer.value
    }

    @Test func realSocketSessionNegotiatesAndStopsWithoutDeviceOrHelper() async throws {
        let (owned, peer) = try pair()
        struct ServerObservations: Sendable {
            var versionIsReply = false
            var protocolVersion: UInt64?
            var toggles: [Bool] = []
        }
        let server = DedicatedThread { () throws -> ServerObservations in
            var observed = ServerObservations()
            let transport = try AccessibilitySocketTransport(taking: peer)
            defer { transport.close() }
            let limit = ContinuousClock.now.advanced(by: .seconds(2))
            let request = try transport.read(until: limit, cancelled: { false })
            let host = try AccessibilityDTX.invocation("hostAPIVersion", argument: nil, identifier: 77)
            try transport.write(host, until: limit, cancelled: { false })
            let version = try transport.read(until: limit, cancelled: { false })
            observed.versionIsReply = version.isReply(to: host)
            observed.protocolVersion = try KeyedArchiveInspector.decodeProtocol(version.object).unsignedInteger
            let archive = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 26), requiringSecureCoding: true)
            try transport.write(request.reply(object: archive), until: limit, cancelled: { false })
            for enabled in [true, false] {
                let toggle = try transport.read(until: limit, cancelled: { false })
                if try KeyedArchiveInspector.decodeProtocol(toggle.archiveArgument()) == .boolean(enabled) {
                    observed.toggles.append(enabled)
                }
                try transport.write(toggle.reply(), until: limit, cancelled: { false })
            }
            return observed
        }
        let client = DedicatedThread {
            let transport = try AccessibilitySocketTransport(taking: owned)
            let session = AccessibilitySession(transport: transport)
            try session.start()
            return session.close() == .stopAcknowledged && transport.isClosed
        }
        #expect(try await client.value)
        let observed = try await server.value
        #expect(observed.versionIsReply)
        #expect(observed.protocolVersion == 7)
        #expect(observed.toggles == [true, false])
    }
}
