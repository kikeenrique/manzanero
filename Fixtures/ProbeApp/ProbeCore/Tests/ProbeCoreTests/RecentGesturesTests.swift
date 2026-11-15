import Foundation
import Testing
@testable import ProbeCore

private let size = InterfaceSize(width: 400, height: 800)

private func point(_ x: Double, _ y: Double) -> ProbePoint { ProbePoint(x: x, y: y) }

extension TouchRecorder where Key == Int {
    /// One gesture of `contacts` simultaneous contacts, each with `moves` moved events.
    /// Keys are fresh per call so no contact is ever reused.
    mutating func gesture(contacts: Int, at time: Double, hold: Double = 0.08, moves: Int = 0,
                          end: TouchPhase = .ended, firstKey: Int) {
        let keys = (0..<contacts).map { firstKey + $0 }
        for (offset, key) in keys.enumerated() {
            _ = record(key: key, phase: .began, point: point(40 + Double(offset) * 70.123, 300.456), timestamp: time)
        }
        for step in 0..<moves {
            for key in keys {
                _ = record(key: key, phase: .moved, point: point(41.789, 301.987 + Double(step)),
                           timestamp: time + hold * Double(step + 1) / Double(moves + 1))
            }
        }
        for key in keys {
            _ = record(key: key, phase: end, point: point(42.345, 333.333), timestamp: time + hold)
        }
    }
}

@Suite struct RecentGesturesTests {
    @Test func emptyUntilAGestureCompletes() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        #expect(recorder.recentGestures == .none(session: "s"))
        _ = recorder.record(key: 1, phase: .began, point: point(10, 10), timestamp: 1)
        #expect(recorder.recentGestures.recent.isEmpty, "an unfinished gesture is not listed")
        _ = recorder.record(key: 1, phase: .ended, point: point(10, 10), timestamp: 1.1)
        #expect(recorder.recentGestures.recent.map(\.gesture) == [1])
    }

    @Test func listsGesturesOldestFirstAndTheNewestMatchesTheLastGesture() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        recorder.gesture(contacts: 1, at: 10, firstKey: 1)
        recorder.gesture(contacts: 2, at: 11, firstKey: 10)
        recorder.gesture(contacts: 1, at: 12, hold: 0.5, firstKey: 20)
        let readout = recorder.recentGestures
        #expect(readout.recent.map(\.gesture) == [1, 2, 3])
        #expect(readout.recent.map { $0.contacts.count } == [1, 2, 1])
        #expect(readout.gestures == 3)
        #expect(readout.dropped == 0)
        #expect(readout.limit == RecentGesturesReadout.maximumGestures)
        #expect(readout.gestures == recorder.summary(log: LogStatus()).gestures)
        let newest = try #require(readout.recent.last)
        #expect(LastGestureReadout(session: "s", completed: newest) == recorder.lastGesture)
        #expect(newest.duration == 0.5)
    }

    @Test func multiContactEntriesKeepPerContactDetail() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        // Contact 0 lifts first, contact 1 moves twice, contact 2 is cancelled; one gesture throughout.
        _ = recorder.record(key: 7, phase: .began, point: point(100, 200), timestamp: 50)
        _ = recorder.record(key: 8, phase: .began, point: point(200, 200), timestamp: 50.1)
        _ = recorder.record(key: 9, phase: .began, point: point(300, 200), timestamp: 50.2)
        _ = recorder.record(key: 7, phase: .ended, point: point(100, 200), timestamp: 50.3)
        _ = recorder.record(key: 8, phase: .moved, point: point(200, 300), timestamp: 50.4)
        _ = recorder.record(key: 8, phase: .moved, point: point(200, 400), timestamp: 50.5)
        _ = recorder.record(key: 9, phase: .cancelled, point: point(300, 220), timestamp: 50.6)
        _ = recorder.record(key: 8, phase: .ended, point: point(200, 400), timestamp: 50.7)
        let entry = try #require(recorder.recentGestures.recent.first)
        #expect(recorder.recentGestures.recent.count == 1)
        #expect(entry.maxActive == 3)
        #expect(abs(entry.duration - 0.7) < 1e-9)
        #expect(entry.contacts.map(\.c) == [0, 1, 2])
        #expect(entry.contacts.map(\.end) == ["ended", "ended", "cancelled"])
        #expect(entry.contacts.map(\.moves) == [0, 2, 0])
        #expect(entry.contacts[1].from == [0.5, 0.25])
        #expect(entry.contacts[1].to == [0.5, 0.5])
    }

    @Test func countBoundDropsTheOldestAndCountsThem() {
        var recorder = TouchRecorder<Int>(session: "s", interface: size, recentLimit: 4)
        for n in 0..<6 { recorder.gesture(contacts: 1, at: Double(n), firstKey: n * 10) }
        let readout = recorder.recentGestures
        #expect(readout.recent.map(\.gesture) == [3, 4, 5, 6])
        #expect(readout.dropped == 2)
        #expect(readout.gestures == 6)
        #expect(readout.limit == 4)
        #expect(readout.dropped + readout.recent.count == readout.gestures)

        // The default bound is 32 entries.
        var standard = TouchRecorder<Int>(session: "s", interface: size)
        for n in 0..<40 { standard.gesture(contacts: 1, at: Double(n), firstKey: n * 10) }
        #expect(standard.recentGestures.recent.count == 32)
        #expect(standard.recentGestures.recent.first?.gesture == 9)
        #expect(standard.recentGestures.dropped == 8)
    }

    @Test func byteBoundHoldsForFiveContactGestures() throws {
        // Large uptime, five-decimal positions, moves and multi-digit contact indexes: a pessimistic entry.
        var recorder = TouchRecorder<Int>(session: "s", interface: InterfaceSize(width: 390.7, height: 844.3))
        var key = 0
        for n in 0..<40 {
            recorder.gesture(contacts: 5, at: 1_234_567.123456 + Double(n) * 3.333333, hold: 12.345678,
                             moves: 3, end: n.isMultiple(of: 2) ? .ended : .cancelled, firstKey: key)
            key += 5
        }
        let readout = recorder.recentGestures
        let entryBytes = readout.recent.map { ProbeJSON.encode($0).count }
        let one = try #require(entryBytes.max())
        #expect(one > 600 && one < 800)
        let listed = entryBytes.reduce(0, +) + entryBytes.count - 1
        #expect(listed <= RecentGesturesReadout.maximumEntryBytes)
        // 706 bytes each when measured: 11 such gestures fit, about 7.7 KB in all.
        #expect(readout.recent.count >= RecentGesturesReadout.maximumEntryBytes / (one + 1))
        #expect(readout.recent.count == 11)
        #expect(readout.dropped == 40 - readout.recent.count)
        #expect(readout.recent.last?.gesture == 40)
        // The whole accessibility value stays within the entry budget plus its fixed fields.
        #expect(ProbeJSON.encode(readout).count <= RecentGesturesReadout.maximumEntryBytes + 120)
    }

    @Test func theNewestGestureIsKeptEvenAboveTheByteBound() {
        var recorder = TouchRecorder<Int>(session: "s", interface: size, recentByteLimit: 10)
        recorder.gesture(contacts: 2, at: 1, firstKey: 1)
        recorder.gesture(contacts: 3, at: 2, firstKey: 10)
        let readout = recorder.recentGestures
        #expect(readout.recent.map(\.gesture) == [2])
        #expect(readout.dropped == 1)
        #expect(readout.recent.first?.contacts.count == 3)
    }

    @Test func resetClearsTheListAndFollowsTheNewSession() {
        var recorder = TouchRecorder<Int>(session: "old", interface: size, recentLimit: 2)
        for n in 0..<3 { recorder.gesture(contacts: 1, at: Double(n), firstKey: n * 10) }
        #expect(recorder.recentGestures.dropped == 1)
        // A contact down across the reset never completes a gesture in the new session.
        _ = recorder.record(key: 99, phase: .began, point: point(5, 5), timestamp: 9)
        recorder.reset(session: "new")
        #expect(recorder.recentGestures == RecentGesturesReadout(session: "new", gestures: 0, dropped: 0, limit: 2, recent: []))
        _ = recorder.record(key: 99, phase: .ended, point: point(5, 5), timestamp: 10)
        #expect(recorder.recentGestures.recent.isEmpty)
        recorder.gesture(contacts: 1, at: 11, firstKey: 200)
        let readout = recorder.recentGestures
        #expect(readout.session == "new")
        #expect(readout.recent.map(\.gesture) == [1])
        #expect(readout.recent.first?.contacts.first?.c == 0)
        #expect(readout.limit == 2, "limits survive a reset")
    }

    @Test func jsonShapeAndDecoding() throws {
        var recorder = TouchRecorder<Int>(session: "abc", interface: size)
        #expect(ProbeJSON.string(recorder.recentGestures)
            == #"{"dropped":0,"gestures":0,"limit":32,"recent":[],"session":"abc","v":1}"#)
        recorder.gesture(contacts: 2, at: 2, firstKey: 1)
        let data = ProbeJSON.encode(recorder.recentGestures)
        #expect(!data.contains(0x0A))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["v", "session", "gestures", "dropped", "limit", "recent"])
        let entries = try #require(json["recent"] as? [[String: Any]])
        #expect(Set(entries[0].keys) == ["gesture", "maxActive", "duration", "contacts"])
        let contacts = try #require(entries[0]["contacts"] as? [[String: Any]])
        #expect(Set(contacts[0].keys) == ["c", "from", "to", "began", "duration", "end", "moves"])

        let decoded = try JSONDecoder().decode(RecentGesturesReadout.self, from: data)
        #expect(decoded == recorder.recentGestures)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecentGesturesReadout.self,
                                     from: Data(#"{"v":2,"session":"a","gestures":0,"dropped":0,"limit":32,"recent":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecentGesturesReadout.self, from: Data(#"{"v":1,"session":"a","gestures":0}"#.utf8))
        }
    }
}
