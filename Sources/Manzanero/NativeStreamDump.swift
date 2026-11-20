import Foundation

/// Experiment only, with `MANZANERO_TV_CAPTURE=1`: keeps a capture's video as
/// it arrived, beside the frames, so that it can be read and decoded again
/// without the device. `stream.h265` is the access units in Annex B form,
/// with the parameter sets before each random-access picture; `packets.txt`
/// has one line for each RTP packet: sequence number, timestamp, marker,
/// payload bytes, and the header extension's profile and data when there is
/// one. An Apple TV 4K marks one later picture in that extension as it marks
/// its key frame (docs/verification.md#the-apple-tvs-video-stream-read-packet-by-packet).
struct NativeStreamDump {
    static let streamName = "stream.h265", packetsName = "packets.txt"
    static let maximumBytes = 256 * 1024 * 1024, maximumPackets = 500_000
    private(set) var stream = Data()
    private(set) var lines: [String] = []

    /// One line for a datagram that is an RTP packet; nothing for another.
    mutating func packet(_ datagram: Data) {
        let bytes = [UInt8](datagram)
        guard bytes.count >= 12, bytes[0] >> 6 == 2, lines.count < Self.maximumPackets else { return }
        func word(_ offset: Int) -> UInt32 { bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
        var begin = 12 + 4 * Int(bytes[0] & 15), line = "\(Int(bytes[2]) << 8 | Int(bytes[3])) \(word(4)) \(bytes[1] >> 7)"
        var extensionText = "-"
        if bytes[0] & 16 != 0, bytes.count >= begin + 4 {
            let size = (Int(bytes[begin + 2]) << 8 | Int(bytes[begin + 3])) * 4
            if bytes.count >= begin + 4 + size {
                extensionText = Self.hex(bytes[begin..<(begin + 2)]) + ":" + Self.hex(bytes[(begin + 4)..<(begin + 4 + size)])
                begin += 4 + size
            }
        }
        line += " \(max(0, bytes.count - begin)) \(extensionText)"
        lines.append(line)
    }

    /// One access unit, each NAL unit after a start code.
    mutating func unit(_ unit: MediaHEVCAccessUnit) {
        // A key frame's own units usually begin with the parameter sets;
        // they are added only when they do not.
        let sets = unit.randomAccess ? unit.parameterSets.filter { !unit.nals.contains($0) } : []
        for nal in sets + unit.nals where stream.count + nal.count + 4 <= Self.maximumBytes {
            stream.append(contentsOf: [0, 0, 0, 1])
            stream.append(nal)
        }
    }

    func write(to directory: URL) throws {
        try stream.write(to: directory.appendingPathComponent(Self.streamName))
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent(Self.packetsName))
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
