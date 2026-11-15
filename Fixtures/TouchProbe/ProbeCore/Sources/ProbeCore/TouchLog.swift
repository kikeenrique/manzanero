import Foundation

/// Append-only JSON Lines log for one session at a time.
///
/// Growth is bounded per session: once the next event line would take the file
/// past `limitBytes`, that event and every later one in the session is dropped,
/// and a single `truncated` line is written in space reserved for it. The start
/// of a session is therefore always intact. Starting a session (launch or reset)
/// replaces the file. Lines are buffered in memory and written by `flush()` or
/// when the buffer passes `flushThreshold`.
public final class TouchLog {
    public let url: URL
    public let limitBytes: Int
    public let flushThreshold: Int
    /// Bytes kept free for the truncation line.
    static let truncationReserve = 256

    private var buffer = Data()
    private var session = ""
    private var truncated = false
    public private(set) var status = LogStatus()

    public init(url: URL, limitBytes: Int = 4 * 1024 * 1024, flushThreshold: Int = 64 * 1024) {
        precondition(limitBytes > Self.truncationReserve * 2, "log limit too small")
        self.url = url
        self.limitBytes = limitBytes
        self.flushThreshold = flushThreshold
    }

    /// Replace the file with a new session that starts with `header`.
    public func start(_ header: SessionHeaderRecord) {
        buffer.removeAll()
        session = header.session
        truncated = false
        status = LogStatus()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
        } catch {
            status.error = String(describing: error)
        }
        enqueue(ProbeJSON.encode(header))
        flush()
    }

    /// Append one event, or drop it if the session has reached its limit.
    public func append(_ event: TouchEventRecord) {
        guard !truncated else { status.dropped += 1; return }
        let line = ProbeJSON.encode(event)
        guard status.bytes + line.count + 1 <= limitBytes - Self.truncationReserve else {
            truncated = true
            status.dropped += 1
            enqueue(ProbeJSON.encode(TruncationRecord(session: session, firstDroppedSeq: event.seq, limitBytes: limitBytes)))
            flush()
            return
        }
        enqueue(line)
        if buffer.count >= flushThreshold { flush() }
    }

    /// Write buffered lines to the file.
    public func flush() {
        guard !buffer.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            // Keep the counters: they describe what the probe meant to write.
            status.error = String(describing: error)
            buffer.removeAll()
        }
    }

    private func enqueue(_ line: Data) {
        buffer.append(line)
        buffer.append(0x0A)
        status.lines += 1
        status.bytes += line.count + 1
    }
}
