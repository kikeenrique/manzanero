import CLwIP
import Foundation
import Testing

/// lwIP driven by hand, with no device: the test plays the peer, reading the
/// packets lwIP sends and answering with packets it builds itself. lwIP has
/// one stack per process, so everything is one serialized test.
@Suite(.serialized)
struct UserSpaceTCPTests {
    static let local: [UInt8] = [0xfd, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
    static let remote: [UInt8] = [0xfd, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

    /// What the stack sent and what its connection reported.
    final class Peer {
        var sent: [[UInt8]] = []
        var connected = false
        var received: [UInt8] = []
        var finished = false
        var failure: Int32?
    }

    struct Segment {
        var sourcePort: UInt16, destinationPort: UInt16
        var sequence: UInt32, acknowledgement: UInt32
        var flags: UInt8
        var payload: [UInt8]

        static let syn: UInt8 = 0x02, ack: UInt8 = 0x10, push: UInt8 = 0x08, fin: UInt8 = 0x01

        /// Parses an IPv6 packet carrying TCP with no extension headers.
        init?(packet: [UInt8]) {
            guard packet.count >= 60, packet[0] >> 4 == 6, packet[6] == 6 else { return nil }
            let tcp = Array(packet[40...])
            let offset = Int(tcp[12] >> 4) * 4
            guard offset >= 20, tcp.count >= offset else { return nil }
            sourcePort = UInt16(tcp[0]) << 8 | UInt16(tcp[1])
            destinationPort = UInt16(tcp[2]) << 8 | UInt16(tcp[3])
            sequence = tcp[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
            acknowledgement = tcp[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
            flags = tcp[13]
            payload = Array(tcp[offset...])
        }

        init(sourcePort: UInt16, destinationPort: UInt16, sequence: UInt32, acknowledgement: UInt32, flags: UInt8, payload: [UInt8] = []) {
            self.sourcePort = sourcePort; self.destinationPort = destinationPort
            self.sequence = sequence; self.acknowledgement = acknowledgement
            self.flags = flags; self.payload = payload
        }

        /// The segment as an IPv6 packet from `source` to `destination`, with its checksum.
        func packet(from source: [UInt8], to destination: [UInt8]) -> [UInt8] {
            func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
            func bytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - 8 * UInt32($0)) & 0xff) } }
            var tcp = bytes(sourcePort) + bytes(destinationPort) + bytes(sequence) + bytes(acknowledgement)
            tcp += [0x50, flags] + bytes(UInt16(32 * 1220)) + [0, 0, 0, 0] + payload
            let length = UInt32(tcp.count)
            var sum: UInt32 = 0
            let pseudo = source + destination + bytes(length) + [0, 0, 0, 6] + tcp + (tcp.count % 2 == 1 ? [0] : [])
            for index in stride(from: 0, to: pseudo.count, by: 2) { sum += UInt32(pseudo[index]) << 8 | UInt32(pseudo[index + 1]) }
            while sum >> 16 != 0 { sum = sum & 0xffff + sum >> 16 }
            let checksum = ~UInt16(sum)
            tcp[16] = UInt8(checksum >> 8); tcp[17] = UInt8(checksum & 0xff)
            return [0x60, 0, 0, 0] + bytes(UInt16(tcp.count)) + [6, 64] + source + destination + tcp
        }
    }

    @Test func aConnectionIsOpenedAndDataArrivesThroughPacketsAlone() throws {
        let peer = Peer()
        let context = Unmanaged.passUnretained(peer).toOpaque()
        #expect(ADLStart(Self.local, 1280, { context, packet, length in
            Unmanaged<Peer>.fromOpaque(context!).takeUnretainedValue().sent.append(Array(UnsafeBufferPointer(start: packet, count: length)))
            return 0
        }, context) == 0)
        defer { ADLStop() }

        let callbacks = ADLCallbacks(context: context,
            connected: { Unmanaged<Peer>.fromOpaque($0!).takeUnretainedValue().connected = true },
            received: { context, bytes, length in
                Unmanaged<Peer>.fromOpaque(context!).takeUnretainedValue().received += Array(UnsafeBufferPointer(start: bytes, count: length))
            },
            finished: { Unmanaged<Peer>.fromOpaque($0!).takeUnretainedValue().finished = true },
            failed: { context, error in Unmanaged<Peer>.fromOpaque(context!).takeUnretainedValue().failure = error })
        let connection = try #require(ADLConnect(Self.remote, 58783, callbacks))
        defer { ADLClose(connection) }

        // The request: one IPv6 packet from the local address to the remote
        // one, a TCP SYN to the port asked for.
        let first = try #require(peer.sent.first)
        #expect(Array(first[8..<24]) == Self.local && Array(first[24..<40]) == Self.remote)
        let syn = try #require(Segment(packet: first))
        #expect(syn.destinationPort == 58783 && syn.flags & Segment.syn != 0 && syn.flags & Segment.ack == 0)
        #expect(!peer.connected)

        // The peer accepts; lwIP reports the connection and acknowledges.
        peer.sent.removeAll()
        let accept = Segment(sourcePort: 58783, destinationPort: syn.sourcePort, sequence: 7000, acknowledgement: syn.sequence &+ 1,
                             flags: Segment.syn | Segment.ack)
        #expect(ADLInput(accept.packet(from: Self.remote, to: Self.local), 60) == 0)
        #expect(peer.connected && peer.failure == nil)
        let acknowledged = try #require(peer.sent.compactMap(Segment.init(packet:)).last)
        #expect(acknowledged.flags & Segment.ack != 0 && acknowledged.acknowledgement == 7001)

        // Bytes from the peer are delivered in order.
        let greeting = Array("PRI * HTTP/2.0".utf8)
        let data = Segment(sourcePort: 58783, destinationPort: syn.sourcePort, sequence: 7001, acknowledgement: syn.sequence &+ 1,
                           flags: Segment.ack | Segment.push, payload: greeting)
        let dataPacket = data.packet(from: Self.remote, to: Self.local)
        #expect(ADLInput(dataPacket, dataPacket.count) == 0)
        #expect(peer.received == greeting)
        ADLAcknowledge(connection, greeting.count)

        // Bytes written go out as a segment that carries them.
        peer.sent.removeAll()
        let reply = Array("hello".utf8)
        #expect(ADLWrite(connection, reply, reply.count) == 5)
        ADLPoll()
        #expect(peer.sent.compactMap(Segment.init(packet:)).contains { $0.payload == reply && $0.acknowledgement == 7001 + UInt32(greeting.count) })

        // A packet that is not IPv6, or too short to be one, is refused.
        #expect(ADLInput([0x45, 0, 0, 20], 4) != 0)
    }
}
