import Foundation
import Testing
@testable import ProbeCore

/// Log files go under the repository's tmp/ directory. SwiftPM runs these tests
/// from the package directory, so the root is found from this file's path
/// (Fixtures/ProbeApp/ProbeCore/Tests/ProbeCoreTests/ is five levels deep).
private func scratchURL(file: String = #filePath) throws -> URL {
    var root = URL(fileURLWithPath: file)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    let directory = root.appendingPathComponent("tmp/probe-app/core-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("Documents/touch-log.jsonl")
}

private func header(_ session: String, reason: String = "launch") -> SessionHeaderRecord {
    SessionHeaderRecord(session: session, reason: reason, started: "2026-01-01T00:00:00Z", uptime: 1,
                        size: InterfaceSize(width: 400, height: 800), scale: 3)
}

private func lines(_ url: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    return try text.split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@Suite struct TouchLogTests {
    @Test func writesHeaderThenOneEventPerLine() throws {
        let url = try scratchURL()
        let log = TouchLog(url: url)
        log.start(header("one"))
        var recorder = TouchRecorder<Int>(session: "one", interface: InterfaceSize(width: 400, height: 800))
        for (phase, time) in [(TouchPhase.began, 1.0), (.moved, 1.1), (.ended, 1.2)] {
            log.append(try recorder.expectRecord(key: 1, phase: phase, point: ProbePoint(x: 10, y: 10), timestamp: time))
        }
        #expect(try lines(url).count == 1, "events stay buffered until flush")
        log.flush()
        let written = try lines(url)
        #expect(written.map { $0["type"] as? String } == ["session", "event", "event", "event"])
        #expect(written.dropFirst().map { $0["seq"] as? Int } == [1, 2, 3])
        let bytes = try Data(contentsOf: url).count
        #expect(log.status == LogStatus(lines: 4, bytes: bytes, dropped: 0))
    }

    @Test func flushesAutomaticallyPastTheThreshold() throws {
        let url = try scratchURL()
        let log = TouchLog(url: url, flushThreshold: 1)
        log.start(header("one"))
        var recorder = TouchRecorder<Int>(session: "one", interface: InterfaceSize(width: 400, height: 800))
        log.append(try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 1, y: 1), timestamp: 0))
        #expect(try lines(url).count == 2)
    }

    @Test func startReplacesThePreviousSession() throws {
        let url = try scratchURL()
        let log = TouchLog(url: url)
        log.start(header("old"))
        var recorder = TouchRecorder<Int>(session: "old", interface: InterfaceSize(width: 400, height: 800))
        log.append(try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 1, y: 1), timestamp: 0))
        log.start(header("new", reason: "reset"))
        let written = try lines(url)
        #expect(written.count == 1)
        #expect(written[0]["session"] as? String == "new")
        #expect(written[0]["reason"] as? String == "reset")
        #expect(log.status.lines == 1 && log.status.dropped == 0)
    }

    @Test func boundsGrowthAndMarksTruncationOnce() throws {
        let url = try scratchURL()
        let limit = 2048
        let log = TouchLog(url: url, limitBytes: limit)
        log.start(header("one"))
        var recorder = TouchRecorder<Int>(session: "one", interface: InterfaceSize(width: 400, height: 800))
        log.append(try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 1, y: 1), timestamp: 0))
        for index in 0..<99 {
            log.append(try recorder.expectRecord(key: 1, phase: .moved, point: ProbePoint(x: 1, y: Double(index)), timestamp: Double(index)))
        }
        log.flush()
        let data = try Data(contentsOf: url)
        #expect(data.count <= limit)
        let written = try lines(url)
        let truncation = written.filter { $0["type"] as? String == "truncated" }
        #expect(truncation.count == 1)
        #expect(written.last?["type"] as? String == "truncated")
        let events = written.filter { $0["type"] as? String == "event" }
        // Events kept are the first ones, in order, and the marker names the first one dropped.
        #expect(events.map { $0["seq"] as? Int } == Array(1...events.count).map(Optional.some))
        #expect(truncation[0]["firstDroppedSeq"] as? Int == events.count + 1)
        #expect(log.status.dropped == 100 - events.count)
        #expect(log.status.bytes == data.count)
    }

    @Test func reportsWriteErrorsWithoutCrashing() throws {
        let url = try scratchURL()
        let log = TouchLog(url: url)
        log.start(header("one"))
        try FileManager.default.removeItem(at: url)
        var recorder = TouchRecorder<Int>(session: "one", interface: InterfaceSize(width: 400, height: 800))
        log.append(try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 1, y: 1), timestamp: 0))
        log.flush()
        #expect(log.status.error != nil)
    }
}
