import Foundation

struct MediaHEVCAccessUnit: Sendable, Equatable {
    let timestamp: UInt32
    let parameterSets: [Data] // VPS, SPS, PPS
    let nals: [Data]
    let randomAccess: Bool

    var lengthPrefixed: Data {
        var data = Data()
        for nal in nals {
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            data.append(nal)
        }
        return data
    }
}

/// RFC 7798, single-layer, non-interleaved HEVC without DONL fields.
/// Loss discards the current picture and gates dependent pictures until IRAP.
struct MediaHEVCAssembler {
    private let maximumBytes: Int
    private var source: UInt32?
    private var sequence: UInt16?
    private var timestamp: UInt32?
    private var damaged = false
    private var reference = false
    private var nals: [Data] = []
    private var bytes = 0
    private var fragment: Data?
    private var parameters: [Int: Data] = [:]

    init(maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumBytes = max(2, min(maximumBytes, 8 * 1024 * 1024))
    }

    mutating func accept(_ packet: MediaRTPPacket) throws -> MediaHEVCAccessUnit? {
        if let source, source != packet.source {
            throw CommandFailure(description: "RTP video source changed during capture.")
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
        if !damaged, !append(packet.payload) { damaged = true; reference = false }
        guard packet.marker else { return nil }
        defer { resetPicture() }
        guard !damaged, fragment == nil else { reference = false; return nil }
        let types = nals.map { Int(($0[0] >> 1) & 63) }
        guard types.contains(where: { $0 < 32 }) else { return nil }
        let randomAccess = types.contains { (16...21).contains($0) }
        let sets = [32, 33, 34].compactMap { parameters[$0] }
        if randomAccess { reference = sets.count == 3 }
        guard reference, sets.count == 3 else { return nil }
        return MediaHEVCAccessUnit(timestamp: packet.timestamp, parameterSets: sets, nals: nals, randomAccess: randomAccess)
    }

    private static func type(_ nal: Data) -> Int? {
        guard nal.count >= 2, nal[0] & 0x81 == 0, nal[1] >> 3 == 0, nal[1] & 7 != 0 else { return nil }
        return Int((nal[0] >> 1) & 63)
    }

    private mutating func append(_ payload: Data) -> Bool {
        guard let type = Self.type(payload) else { return false }
        switch type {
        case 0...47:
            return fragment == nil && appendNAL(payload)
        case 48:
            guard fragment == nil else { return false }
            var offset = 2, aggregate: [Data] = []
            var total = 0
            while offset < payload.count {
                guard payload.count - offset >= 2, aggregate.count < 256 else { return false }
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1]); offset += 2
                guard size >= 2, size <= payload.count - offset, total + size + 4 <= maximumBytes - bytes else { return false }
                let nal = Data(payload[offset..<(offset + size)])
                guard let type = Self.type(nal), type < 48 else { return false }
                aggregate.append(nal); total += size + 4; offset += size
            }
            guard !aggregate.isEmpty, nals.count + aggregate.count <= 256 else { return false }
            for nal in aggregate { if !appendNAL(nal) { return false } }
            return true
        case 49:
            guard payload.count >= 4 else { return false }
            let flags = payload[2], type = flags & 63
            let start = flags & 128 != 0, end = flags & 64 != 0
            guard type < 48, !(start && end) else { return false }
            let header = Data([(payload[0] & 0x81) | type << 1, payload[1]])
            let body = payload.dropFirst(3)
            if start {
                guard fragment == nil, body.count + 6 <= maximumBytes - bytes else { return false }
                fragment = header + body
            } else {
                guard let fragment, fragment.prefix(2) == header, body.count + fragment.count + 4 <= maximumBytes - bytes else { return false }
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
        guard let type = Self.type(nal), type < 48, nals.count < 256, nal.count + 4 <= maximumBytes - bytes else { return false }
        if (32...34).contains(type) {
            guard nal.count <= 65_535 else { return false }
            if parameters[type] != nal { reference = false }
            parameters[type] = nal
        }
        nals.append(nal); bytes += nal.count + 4
        return true
    }

    private mutating func resetPicture() {
        timestamp = nil; damaged = false; nals.removeAll(keepingCapacity: true); bytes = 0; fragment = nil
    }
}
