import Foundation
import ProbeCore

/// The events of one probe session as found in a pulled `touch-log.jsonl`.
public struct ProbeLogSession: Sendable, Equatable {
    public var session: String
    public var header: SessionHeaderRecord?
    /// In file order (which is `seq` order when the log is intact).
    public var events: [TouchEventRecord]
    public var truncation: TruncationRecord?

    /// Highest `seq` such that every event `1...seq` is present. Events above it are
    /// unreliable for windowing: a gap or a truncation lies below them.
    public var contiguousThrough: Int {
        var expected = 1
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if event.seq == expected { expected += 1 } else if event.seq > expected { break }
        }
        return expected - 1
    }

    /// Events with `lower < seq <= upper`, in `seq` order.
    public func events(after lower: Int, through upper: Int) -> [TouchEventRecord] {
        events.filter { $0.seq > lower && $0.seq <= upper }.sorted { $0.seq < $1.seq }
    }
}

/// A tolerant reading of the probe's JSON Lines log. Nothing here throws: every
/// irregularity is counted so the report can say what it could not use.
public struct ParsedProbeLog: Sendable, Equatable {
    public var sessions: [ProbeLogSession] = []
    /// 1-based line numbers that are not a valid probe record.
    public var malformedLines: [Int] = []
    /// The last line had no newline and did not parse: the pull raced a write.
    public var incompleteFinalLine = false
    /// Events whose `seq` did not follow the previous event of the same session by one.
    public var sequenceBreaks = 0

    public func session(_ id: String) -> ProbeLogSession? { sessions.first { $0.session == id } }

    public static func parse(_ data: Data) -> ParsedProbeLog {
        var log = ParsedProbeLog()
        let decoder = JSONDecoder()
        let endsWithNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var lastSeq: [String: Int] = [:]
        for (offset, line) in lines.enumerated() {
            let number = offset + 1
            let isFinal = offset == lines.count - 1
            if line.isEmpty { continue }
            guard let probe = try? decoder.decode(LineType.self, from: Data(line)) else {
                if isFinal, !endsWithNewline { log.incompleteFinalLine = true } else { log.malformedLines.append(number) }
                continue
            }
            func index(for session: String) -> Int {
                if let last = log.sessions.indices.last, log.sessions[last].session == session { return last }
                log.sessions.append(ProbeLogSession(session: session, header: nil, events: [], truncation: nil))
                return log.sessions.count - 1
            }
            switch probe.type {
            case "session":
                guard let header = try? decoder.decode(SessionHeaderRecord.self, from: Data(line)) else {
                    log.malformedLines.append(number); continue
                }
                log.sessions.append(ProbeLogSession(session: header.session, header: header, events: [], truncation: nil))
            case "event":
                guard let event = try? decoder.decode(TouchEventRecord.self, from: Data(line)) else {
                    if isFinal, !endsWithNewline { log.incompleteFinalLine = true } else { log.malformedLines.append(number) }
                    continue
                }
                let i = index(for: event.session)
                if event.seq != (lastSeq[event.session] ?? 0) + 1 { log.sequenceBreaks += 1 }
                lastSeq[event.session] = event.seq
                log.sessions[i].events.append(event)
            case "truncated":
                guard let marker = try? decoder.decode(TruncationRecord.self, from: Data(line)) else {
                    log.malformedLines.append(number); continue
                }
                log.sessions[index(for: marker.session)].truncation = marker
            default:
                log.malformedLines.append(number)
            }
        }
        return log
    }

    private struct LineType: Decodable { let type: String }
}
