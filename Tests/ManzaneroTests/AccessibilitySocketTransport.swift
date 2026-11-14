import Darwin
import Foundation
import Testing
@testable import Manzanero

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
        var byte: UInt8 = 0
        // A closed descriptor number may already belong to another parallel
        // test. The still-owned peer observes this socket's actual closure.
        #expect(transport.isClosed && recv(peer, &byte, 1, MSG_DONTWAIT) == 0)
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
        var byte: UInt8 = 0
        #expect(send(peer, &byte, 1, MSG_NOSIGNAL) == -1)
        #expect(throws: AccessibilitySocketTransport.Failure.closed) { try AccessibilitySocketTransport(taking: -1) }
    }

    @Test func shortReadsAssembleOneCompleteFrame() async throws {
        let (owned, peer) = try pair()
        let bytes = try acknowledgement(13).encoded()
        let writer = Task.detached {
            defer { Darwin.close(peer) }
            for chunk in [Data(bytes.prefix(5)), Data(bytes[5..<21]), Data(bytes[21...])] {
                let sent = chunk.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
                guard sent == chunk.count else { throw POSIXError(.EIO) }
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        let transport = try AccessibilitySocketTransport(taking: owned)
        defer { transport.close() }
        #expect(try transport.read(until: .now.advanced(by: .seconds(2)), cancelled: { false }).identifier == 13)
        try await writer.value
    }

    @Test func realSocketSessionNegotiatesAndStopsWithoutDeviceOrHelper() async throws {
        let (owned, peer) = try pair()
        let server = Task.detached {
            let transport = try AccessibilitySocketTransport(taking: peer)
            defer { transport.close() }
            let limit = ContinuousClock.now.advanced(by: .seconds(2))
            let request = try transport.read(until: limit, cancelled: { false })
            let host = try AccessibilityDTX.invocation("hostAPIVersion", argument: nil, identifier: 77)
            try transport.write(host, until: limit, cancelled: { false })
            let version = try transport.read(until: limit, cancelled: { false })
            #expect(version.isReply(to: host))
            #expect(try KeyedArchiveInspector.decodeProtocol(version.object).unsignedInteger == 7)
            let archive = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 26), requiringSecureCoding: true)
            try transport.write(request.reply(object: archive), until: limit, cancelled: { false })
            for enabled in [true, false] {
                let toggle = try transport.read(until: limit, cancelled: { false })
                #expect(try KeyedArchiveInspector.decodeProtocol(toggle.archiveArgument()) == .boolean(enabled))
                try transport.write(toggle.reply(), until: limit, cancelled: { false })
            }
        }
        let transport = try AccessibilitySocketTransport(taking: owned)
        let session = AccessibilitySession(transport: transport)
        try session.start()
        #expect(session.close() == .stopAcknowledged && transport.isClosed)
        try await server.value
    }
}
