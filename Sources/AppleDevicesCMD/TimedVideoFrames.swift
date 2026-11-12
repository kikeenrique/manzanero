import Foundation

struct TimedVideoFrame: Sendable {
    let nanoseconds: UInt64
    let jpeg: Data
}

/// Incremental ADV1 framing. At most one bounded JPEG is buffered at a time.
struct TimedVideoFrames {
    static let maximumJPEGBytes = 8 * 1024 * 1024
    private var pending = Data()
    private var size: Int?
    private var timestamp: UInt64 = 0
    private var previous: UInt64?
    private var count = 0
    let maximumNanoseconds: UInt64

    mutating func feed(_ data: Data) throws -> [TimedVideoFrame] {
        var frames: [TimedVideoFrame] = []
        var offset = 0
        while offset < data.count {
            let target = size ?? 16
            let take = min(target - pending.count, data.count - offset)
            let start = data.index(data.startIndex, offsetBy: offset)
            pending.append(contentsOf: data[start..<data.index(start, offsetBy: take)])
            offset += take
            guard pending.count == target else { continue }
            if size == nil {
                guard pending.prefix(4) == Data("ADV1".utf8) else { throw CommandFailure(description: "Unsupported native video frame protocol.") }
                let bytes = Array(pending)
                let length = bytes[4..<8].reduce(0) { ($0 << 8) | Int($1) }
                timestamp = bytes[8..<16].reduce(0) { ($0 << 8) | UInt64($1) }
                guard (4...Self.maximumJPEGBytes).contains(length), timestamp < maximumNanoseconds,
                      previous.map({ timestamp > $0 }) ?? (timestamp == 0), count < 10000 else {
                    throw CommandFailure(description: "Invalid native video size, timestamp, or frame budget.")
                }
                size = length
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.prefix(2) == Data([0xff, 0xd8]), pending.suffix(2) == Data([0xff, 0xd9]) else {
                    throw CommandFailure(description: "Native video payload is not a complete JPEG.")
                }
                frames.append(TimedVideoFrame(nanoseconds: timestamp, jpeg: pending))
                previous = timestamp
                count += 1
                size = nil
                pending = Data()
            }
        }
        return frames
    }

    func finish() throws {
        guard pending.isEmpty, size == nil, count > 0 else {
            throw CommandFailure(description: "Native video ended without a complete frame stream.")
        }
    }
}
