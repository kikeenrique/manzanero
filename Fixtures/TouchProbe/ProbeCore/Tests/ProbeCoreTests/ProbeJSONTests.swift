import Foundation
import Testing
@testable import ProbeCore

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func keys(_ value: [String: Any]) -> Set<String> { Set(value.keys) }

@Suite struct ProbeJSONTests {
    @Test func eventRecordShape() throws {
        var recorder = TouchRecorder<Int>(session: "abc", interface: InterfaceSize(width: 390, height: 844))
        let record = try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 195.123, y: 422),
                                               timestamp: 1234.56789012, kind: "direct", radius: 20.833333)
        let data = ProbeJSON.encode(record)
        #expect(!data.contains(0x0A), "a record must fit on one JSON Lines line")
        let json = try object(data)
        #expect(keys(json) == ["type", "session", "seq", "contact", "phase", "x", "y", "nx", "ny", "t", "active", "kind", "radius"])
        #expect(json["type"] as? String == "event")
        #expect(json["session"] as? String == "abc")
        #expect(json["seq"] as? Int == 1)
        #expect(json["contact"] as? Int == 0)
        #expect(json["phase"] as? String == "began")
        #expect(json["x"] as? Double == 195.12)
        #expect(json["y"] as? Double == 422)
        #expect(json["nx"] as? Double == 0.50032)
        #expect(json["ny"] as? Double == 0.5)
        #expect(json["t"] as? Double == 1234.56789)
        #expect(json["active"] as? Int == 1)
        #expect(json["kind"] as? String == "direct")
        #expect(json["radius"] as? Double == 20.83)
    }

    @Test func summaryShape() throws {
        var recorder = TouchRecorder<Int>(session: "abc", interface: InterfaceSize(width: 390, height: 844))
        _ = recorder.record(key: 1, phase: .began, point: ProbePoint(x: 1, y: 1), timestamp: 0)
        let json = try object(ProbeJSON.encode(recorder.summary(log: LogStatus(lines: 2, bytes: 300, dropped: 0))))
        #expect(keys(json) == ["v", "session", "size", "events", "began", "moved", "ended", "cancelled", "unmatched",
                               "active", "maxActive", "gestures", "log"])
        #expect(json["v"] as? Int == 1)
        #expect(json["size"] as? [Double] == [390, 844])
        #expect(json["began"] as? Int == 1)
        #expect(json["active"] as? Int == 1)
        let log = try #require(json["log"] as? [String: Any])
        // `error` is omitted when there is none.
        #expect(keys(log) == ["lines", "bytes", "dropped"])
        #expect(log["bytes"] as? Int == 300)
        let failing = try object(ProbeJSON.encode(LogStatus(error: "disk full")))
        #expect(failing["error"] as? String == "disk full")
    }

    @Test func lastGestureShape() throws {
        var recorder = TouchRecorder<Int>(session: "abc", interface: InterfaceSize(width: 400, height: 800))
        let empty = try object(ProbeJSON.encode(recorder.lastGesture))
        #expect(keys(empty) == ["v", "session", "gesture", "maxActive", "duration", "contacts"])
        #expect(empty["gesture"] as? Int == 0)
        #expect((empty["contacts"] as? [Any])?.isEmpty == true)

        _ = recorder.record(key: 1, phase: .began, point: ProbePoint(x: 100, y: 200), timestamp: 2)
        _ = recorder.record(key: 1, phase: .ended, point: ProbePoint(x: 100, y: 200), timestamp: 2.8)
        let json = try object(ProbeJSON.encode(recorder.lastGesture))
        #expect(json["gesture"] as? Int == 1)
        #expect(json["duration"] as? Double == 0.8)
        let contacts = try #require(json["contacts"] as? [[String: Any]])
        #expect(contacts.count == 1)
        #expect(keys(contacts[0]) == ["c", "from", "to", "began", "duration", "end", "moves"])
        #expect(contacts[0]["from"] as? [Double] == [0.25, 0.25])
        #expect(contacts[0]["end"] as? String == "ended")
        #expect(contacts[0]["duration"] as? Double == 0.8)
    }

    @Test func sessionAndTruncationShapes() throws {
        let header = SessionHeaderRecord(session: "abc", reason: "launch", started: "2026-01-01T00:00:00Z",
                                         uptime: 99.1234567, size: InterfaceSize(width: 390, height: 844), scale: 3)
        let json = try object(ProbeJSON.encode(header))
        #expect(keys(json) == ["type", "v", "session", "reason", "started", "uptime", "size", "scale"])
        #expect(json["type"] as? String == "session")
        #expect(json["uptime"] as? Double == 99.123457)
        #expect(json["size"] as? [Double] == [390, 844])

        let marker = try object(ProbeJSON.encode(TruncationRecord(session: "abc", firstDroppedSeq: 7, limitBytes: 4096)))
        #expect(keys(marker) == ["type", "session", "firstDroppedSeq", "limitBytes"])
        #expect(marker["type"] as? String == "truncated")
    }

    @Test func outputIsCompactAndDeterministic() {
        let readout = LastGestureReadout.none(session: "abc")
        let text = ProbeJSON.string(readout)
        #expect(text == #"{"contacts":[],"duration":0,"gesture":0,"maxActive":0,"session":"abc","v":1}"#)
        #expect(ProbeJSON.string(readout) == text)
    }

    @Test func roundingKeepsJSONValid() {
        #expect(ProbeJSON.round(.nan, 3) == 0)
        #expect(ProbeJSON.round(.infinity, 3) == 0)
        #expect(ProbeJSON.round(0.123456, 3) == 0.123)
    }
}
