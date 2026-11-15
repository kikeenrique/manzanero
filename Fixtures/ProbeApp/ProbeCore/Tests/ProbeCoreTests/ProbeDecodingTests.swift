import Foundation
import Testing
@testable import ProbeCore

@Suite struct ProbeDecodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: ProbeJSON.encode(value))
    }

    @Test func everyShapeDecodesWhatTheProbeEncodes() throws {
        var recorder = TouchRecorder<Int>(session: "abcdef0123456789", interface: InterfaceSize(width: 390, height: 844))
        let began = try recorder.expectRecord(key: 1, phase: .began, point: ProbePoint(x: 195, y: 422), timestamp: 10, radius: 20)
        let ended = try recorder.expectRecord(key: 1, phase: .ended, point: ProbePoint(x: 196, y: 423), timestamp: 10.08)
        #expect(try roundTrip(began) == began)
        #expect(try roundTrip(ended) == ended)
        #expect(try roundTrip(recorder.lastGesture) == recorder.lastGesture)
        let summary = recorder.summary(log: LogStatus(lines: 3, bytes: 500, dropped: 0, error: "disk full"))
        #expect(try roundTrip(summary) == summary)

        let header = SessionHeaderRecord(session: "abcdef0123456789", reason: "reset", started: "2026-11-15T09:00:00Z",
                                         uptime: 9.5, size: InterfaceSize(width: 390, height: 844), scale: 3)
        #expect(try roundTrip(header) == header)
        let marker = TruncationRecord(session: "abcdef0123456789", firstDroppedSeq: 9, limitBytes: 4096)
        #expect(try roundTrip(marker) == marker)
    }

    @Test func decodersRejectOtherShapes() {
        let decoder = JSONDecoder()
        // A truncation line is not an event, and a future format version is not v1.
        #expect(throws: DecodingError.self) {
            try decoder.decode(TouchEventRecord.self, from: Data(#"{"type":"truncated","session":"a","firstDroppedSeq":1,"limitBytes":2}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(LastGestureReadout.self, from: Data(#"{"v":2,"session":"a","gesture":0,"maxActive":0,"duration":0,"contacts":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(TouchEventRecord.self, from: Data(#"{"type":"event","session":"a","seq":1}"#.utf8))
        }
    }
}
