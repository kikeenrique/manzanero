import Foundation

/// RFC 6184, non-interleaved H.264: single NAL units, STAP-A and FU-A, as an
/// Apple Watch sends its screen (watchOS 27.2.1, 2026-11-25). Its stream does
/// not carry the parameter sets in band: its first packet is a QuickTime
/// sample description (four bytes, then an `avc1` entry whose `avcC` holds
/// the SPS and PPS), which this reads instead. Loss discards the current
/// picture and gates dependent pictures until an IDR, as for HEVC.
struct MediaH264Assembler {
    private let maximumBytes: Int
    private var source: UInt32?
    private var sequence: UInt16?
    private var timestamp: UInt32?
    private var damaged = false
    private var reference = false
    private var nals: [Data] = []
    private var bytes = 0
    private var fragment: Data?
    private var sps: Data?
    private var pps: Data?

    init(maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumBytes = max(2, min(maximumBytes, 8 * 1024 * 1024))
    }

    mutating func accept(_ packet: MediaRTPPacket) throws -> MediaHEVCAccessUnit? {
        if let source, source != packet.source {
            throw CommandFailure(.transportFailed, "RTP video source changed during capture.", inputSent: .none)
        }
        source = packet.source
        var gap = false
        if let sequence {
            let distance = packet.sequence &- sequence
            if distance == 0 || distance >= 32_768 { return nil }
            gap = distance != 1
        }
        sequence = packet.sequence
        if let timestamp, timestamp != packet.timestamp {
            reference = false
            resetPicture()
        }
        timestamp = packet.timestamp
        if gap { damaged = true; reference = false }
        if let sets = Self.descriptionParameterSets(packet.payload) {
            if sets.sps != sps || sets.pps != pps { reference = false }
            sps = sets.sps; pps = sets.pps
        } else if !damaged, !append(packet.payload) { damaged = true; reference = false }
        guard packet.marker else { return nil }
        defer { resetPicture() }
        guard !damaged, fragment == nil else { reference = false; return nil }
        let types = nals.map { Int($0[0] & 31) }
        guard types.contains(where: { (1...5).contains($0) }) else { return nil }
        let randomAccess = types.contains(5)
        guard let sps, let pps else { return nil }
        if randomAccess { reference = true }
        guard reference else { return nil }
        return MediaHEVCAccessUnit(timestamp: packet.timestamp, parameterSets: [sps, pps], nals: nals,
                                   randomAccess: randomAccess, codec: .h264)
    }

    /// A NAL unit's type, for a header with the forbidden bit clear.
    static func type(_ nal: Data) -> Int? {
        guard let first = nal.first, first & 0x80 == 0, first & 31 != 0 else { return nil }
        return Int(first & 31)
    }

    /// The SPS and PPS of a sample-description packet: a 32-bit size and
    /// `avc1` at byte 4, and an `avcC` box inside.
    static func descriptionParameterSets(_ payload: Data) -> (sps: Data, pps: Data)? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 12, bytes[8...11].elementsEqual(Array("avc1".utf8)) else { return nil }
        let tag = Array("avcC".utf8)
        guard let at = (4..<(bytes.count - 4)).first(where: { bytes[$0..<($0 + 4)].elementsEqual(tag) }) else { return nil }
        var offset = at + 4 + 5
        func set() -> Data? {
            guard offset + 2 <= bytes.count else { return nil }
            let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
            guard size >= 2, size <= 65_535, offset + size <= bytes.count else { return nil }
            defer { offset += size }
            return Data(bytes[offset..<(offset + size)])
        }
        guard offset < bytes.count, bytes[offset] & 31 >= 1 else { return nil }
        offset += 1
        guard let sps = set(), type(sps) == 7, offset < bytes.count, bytes[offset] >= 1 else { return nil }
        offset += 1
        guard let pps = set(), type(pps) == 8 else { return nil }
        return (sps, pps)
    }

    private mutating func append(_ payload: Data) -> Bool {
        guard let type = Self.type(payload) else { return false }
        switch type {
        case 1...23:
            return fragment == nil && appendNAL(payload)
        case 24:
            guard fragment == nil else { return false }
            var offset = 1, aggregate: [Data] = []
            while offset < payload.count {
                guard payload.count - offset >= 2, aggregate.count < 256 else { return false }
                let size = Int(payload[payload.startIndex + offset]) << 8 | Int(payload[payload.startIndex + offset + 1]); offset += 2
                guard size >= 1, size <= payload.count - offset else { return false }
                let nal = Data(payload.dropFirst(offset).prefix(size))
                guard let inner = Self.type(nal), inner <= 23 else { return false }
                aggregate.append(nal); offset += size
            }
            guard !aggregate.isEmpty else { return false }
            for nal in aggregate { if !appendNAL(nal) { return false } }
            return true
        case 28:
            guard payload.count >= 3 else { return false }
            let indicator = payload[payload.startIndex], flags = payload[payload.startIndex + 1]
            let inner = flags & 31, start = flags & 128 != 0, end = flags & 64 != 0
            guard inner >= 1, inner <= 23, !(start && end) else { return false }
            let header = Data([(indicator & 0xE0) | inner])
            let body = payload.dropFirst(2)
            if start {
                guard fragment == nil, body.count + 5 <= maximumBytes - bytes else { return false }
                fragment = header + body
            } else {
                guard let fragment, fragment.prefix(1) == header, body.count + fragment.count + 4 <= maximumBytes - bytes else { return false }
                self.fragment?.append(body)
            }
            if end, let complete = fragment {
                fragment = nil
                return appendNAL(complete)
            }
            return true
        default: return false
        }
    }

    private mutating func appendNAL(_ nal: Data) -> Bool {
        guard let type = Self.type(nal), type <= 23, nals.count < 256, nal.count + 4 <= maximumBytes - bytes else { return false }
        // Parameter sets in band replace the described ones and are not
        // sample data.
        if type == 7 || type == 8 {
            guard nal.count <= 65_535 else { return false }
            if type == 7 { if sps != nal { reference = false }; sps = nal } else { if pps != nal { reference = false }; pps = nal }
            return true
        }
        nals.append(nal); bytes += nal.count + 4
        return true
    }

    private mutating func resetPicture() {
        timestamp = nil; damaged = false; nals.removeAll(keepingCapacity: true); bytes = 0; fragment = nil
    }
}

/// The capture loops' assembler: HEVC, as a phone and an Apple TV send, or
/// H.264, as an Apple Watch does, told apart by the stream's first packet
/// that only one of them reads.
struct MediaVideoAssembler {
    private enum Mode { case undecided, hevc, h264 }
    private var mode = Mode.undecided
    private var hevc = MediaHEVCAssembler()
    private var h264 = MediaH264Assembler()

    mutating func accept(_ packet: MediaRTPPacket) throws -> MediaHEVCAccessUnit? {
        if mode == .undecided {
            if MediaH264Assembler.descriptionParameterSets(packet.payload) != nil { mode = .h264 }
            else if MediaHEVCAssembler.type(packet.payload) != nil { mode = .hevc }
            else if let type = MediaH264Assembler.type(packet.payload), type <= 24 || type == 28 { mode = .h264 }
        }
        switch mode {
        case .hevc: return try hevc.accept(packet)
        case .h264: return try h264.accept(packet)
        case .undecided: return nil
        }
    }
}
