import Foundation

/// RFC 3550 section 5.1. The caller supplies the negotiated payload type;
/// packet parsing does not infer a codec from that dynamic number.
struct MediaRTPPacket: Sendable, Equatable {
    let sequence: UInt16
    let timestamp: UInt32
    let source: UInt32
    let marker: Bool
    let payload: Data

    init?(_ datagram: Data, payloadType: UInt8) {
        guard payloadType <= 127, (13...65_535).contains(datagram.count) else { return nil }
        // Data slices need not start at index zero. One bounded copy also avoids
        // alignment assumptions when reading network-order integers.
        let bytes = Array(datagram)
        guard bytes[0] >> 6 == 2, bytes[1] & 127 == payloadType else { return nil }
        var begin = 12 + 4 * Int(bytes[0] & 15)
        var end = bytes.count
        guard begin < end else { return nil }
        if bytes[0] & 16 != 0 {
            guard end - begin >= 4 else { return nil }
            let words = Int(bytes[begin + 2]) << 8 | Int(bytes[begin + 3])
            let extensionSize = 4 + words * 4
            guard extensionSize < end - begin else { return nil }
            begin += extensionSize
        }
        if bytes[0] & 32 != 0 {
            let padding = Int(bytes[end - 1])
            guard padding > 0, padding < end - begin else { return nil }
            end -= padding
        }
        func word(_ offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = word(4)
        source = word(8)
        marker = bytes[1] & 128 != 0
        payload = Data(bytes[begin..<end])
    }
}
