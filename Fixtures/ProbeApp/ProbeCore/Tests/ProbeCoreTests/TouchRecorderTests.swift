import Foundation
import Testing
@testable import ProbeCore

private let size = InterfaceSize(width: 400, height: 800)

private func point(_ x: Double, _ y: Double) -> ProbePoint { ProbePoint(x: x, y: y) }

@Suite struct TouchRecorderTests {
    @Test func normalizesToTopLeftUnitSquare() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        let record = try recorder.expectRecord(key: 1, phase: .began, point: point(100, 600), timestamp: 10)
        #expect(record.nx == 0.25)
        #expect(record.ny == 0.75)
        #expect(record.x == 100 && record.y == 600)
        #expect(size.normalize(point(0, 0)) == point(0, 0))
        #expect(size.normalize(point(400, 800)) == point(1, 1))
        // Out-of-range readings are reported, not clamped.
        #expect(size.normalize(point(-4, 880)) == point(-0.01, 1.1))
        #expect(InterfaceSize(width: 0, height: 0).normalize(point(5, 5)) == point(0, 0))
    }

    @Test func normalizationFollowsInterfaceChanges() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        recorder.setInterface(InterfaceSize(width: 800, height: 400))
        let record = try recorder.expectRecord(key: 1, phase: .began, point: point(200, 100), timestamp: 1)
        #expect(record.nx == 0.25 && record.ny == 0.25)
        #expect(recorder.summary(log: LogStatus()).size == [800, 400])
    }

    @Test func contactIndexesStayStableAcrossInterleavedContacts() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        // Keys are deliberately unrelated to the indexes the recorder assigns.
        let events: [(Int, TouchPhase)] = [
            (70, .began), (30, .began), (70, .moved), (30, .moved), (50, .began),
            (30, .ended), (70, .moved), (50, .moved), (90, .began), (70, .ended), (50, .ended), (90, .ended),
        ]
        var seen: [Int: Set<Int>] = [:]
        for (offset, (key, phase)) in events.enumerated() {
            let record = try recorder.expectRecord(key: key, phase: phase, point: point(10, 10), timestamp: Double(offset))
            seen[key, default: []].insert(record.contact)
            #expect(record.seq == offset + 1)
        }
        #expect(seen[70] == [0])
        #expect(seen[30] == [1])
        #expect(seen[50] == [2])
        // 90 began after 30 ended; indexes are not reused within a session.
        #expect(seen[90] == [3])
    }

    @Test func repeatedBeganKeepsTheContactIndex() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        _ = recorder.record(key: 1, phase: .began, point: point(1, 1), timestamp: 0)
        let again = try recorder.expectRecord(key: 1, phase: .began, point: point(2, 2), timestamp: 1)
        #expect(again.contact == 0)
        #expect(again.active == 1)
    }

    @Test func activeCountsAndMaxSimultaneous() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        var actives: [Int] = []
        for (key, phase) in [(1, TouchPhase.began), (2, .began), (3, .began), (2, .ended), (4, .began), (5, .began),
                             (1, .moved), (1, .ended), (3, .ended), (4, .ended), (5, .cancelled)] {
            actives.append(try recorder.expectRecord(key: key, phase: phase, point: point(1, 1), timestamp: 0).active)
        }
        #expect(actives == [1, 2, 3, 3, 3, 4, 4, 4, 3, 2, 1])
        let summary = recorder.summary(log: LogStatus())
        #expect(summary.maxActive == 4)
        #expect(summary.active == 0)
        #expect(summary.gestures == 1)
        #expect(recorder.lastGesture.maxActive == 4)
    }

    @Test func gestureDurationAndPositions() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        _ = recorder.record(key: 8, phase: .began, point: point(200, 400), timestamp: 100.25)
        _ = recorder.record(key: 9, phase: .began, point: point(40, 80), timestamp: 100.5)
        _ = recorder.record(key: 8, phase: .moved, point: point(220, 400), timestamp: 100.6)
        _ = recorder.record(key: 8, phase: .moved, point: point(240, 400), timestamp: 100.7)
        _ = recorder.record(key: 9, phase: .ended, point: point(40, 80), timestamp: 101.0)
        #expect(recorder.lastGesture.gesture == 0, "gesture completes only when every contact is up")
        _ = recorder.record(key: 8, phase: .ended, point: point(240, 400), timestamp: 101.75)

        let gesture = recorder.lastGesture
        #expect(gesture.gesture == 1)
        #expect(gesture.duration == 1.5)
        #expect(gesture.maxActive == 2)
        #expect(gesture.contacts.map(\.c) == [0, 1])
        let first = gesture.contacts[0]
        #expect(first.from == [0.5, 0.5])
        #expect(first.to == [0.6, 0.5])
        #expect(first.duration == 1.5)
        #expect(first.began == 100.25)
        #expect(first.moves == 2)
        #expect(first.end == "ended")
        let second = gesture.contacts[1]
        #expect(second.from == [0.1, 0.1])
        #expect(second.duration == 0.5)
        #expect(second.moves == 0)
    }

    @Test func secondGestureReplacesTheFirst() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        _ = recorder.record(key: 1, phase: .began, point: point(0, 0), timestamp: 1)
        _ = recorder.record(key: 1, phase: .ended, point: point(0, 0), timestamp: 2)
        _ = recorder.record(key: 1, phase: .began, point: point(400, 800), timestamp: 3)
        _ = recorder.record(key: 1, phase: .ended, point: point(400, 800), timestamp: 3.25)
        #expect(recorder.lastGesture.gesture == 2)
        #expect(recorder.lastGesture.contacts.count == 1)
        #expect(recorder.lastGesture.contacts[0].c == 1)
        #expect(recorder.lastGesture.contacts[0].from == [1, 1])
        #expect(recorder.lastGesture.duration == 0.25)
        #expect(recorder.summary(log: LogStatus()).gestures == 2)
    }

    @Test func cancelEndsTheContactAndIsCounted() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        _ = recorder.record(key: 1, phase: .began, point: point(100, 100), timestamp: 5)
        _ = recorder.record(key: 2, phase: .began, point: point(300, 100), timestamp: 5)
        let cancelled = try recorder.expectRecord(key: 1, phase: .cancelled, point: point(110, 100), timestamp: 5.5)
        #expect(cancelled.phase == .cancelled && cancelled.active == 2)
        #expect(recorder.activeCount == 1)
        _ = recorder.record(key: 2, phase: .cancelled, point: point(300, 100), timestamp: 6)

        let summary = recorder.summary(log: LogStatus())
        #expect(summary.began == 2 && summary.cancelled == 2 && summary.ended == 0)
        #expect(recorder.lastGesture.contacts.map(\.end) == ["cancelled", "cancelled"])
        #expect(recorder.lastGesture.contacts[0].duration == 0.5)
        // A cancelled contact's key is gone: further callbacks are unmatched.
        #expect(recorder.record(key: 1, phase: .ended, point: point(0, 0), timestamp: 7) == nil)
        #expect(recorder.summary(log: LogStatus()).unmatched == 1)
    }

    @Test func unknownContactsAreUnmatchedAndTakeNoSequenceNumber() throws {
        var recorder = TouchRecorder<Int>(session: "s", interface: size)
        #expect(recorder.record(key: 4, phase: .moved, point: point(1, 1), timestamp: 0) == nil)
        #expect(recorder.record(key: 4, phase: .ended, point: point(1, 1), timestamp: 0) == nil)
        let first = try recorder.expectRecord(key: 5, phase: .began, point: point(1, 1), timestamp: 0)
        #expect(first.seq == 1)
        let summary = recorder.summary(log: LogStatus())
        #expect(summary.unmatched == 2 && summary.events == 1 && summary.moved == 0)
    }

    @Test func resetStartsAFreshSession() throws {
        var recorder = TouchRecorder<Int>(session: "old", interface: size)
        _ = recorder.record(key: 1, phase: .began, point: point(1, 1), timestamp: 0)
        _ = recorder.record(key: 1, phase: .ended, point: point(1, 1), timestamp: 1)
        _ = recorder.record(key: 2, phase: .began, point: point(1, 1), timestamp: 2)
        recorder.reset(session: "new")

        #expect(recorder.session == "new")
        #expect(recorder.interface == size)
        #expect(recorder.lastGesture == .none(session: "new"))
        let summary = recorder.summary(log: LogStatus())
        #expect(summary.session == "new")
        let counters: [Int] = [summary.events, summary.began, summary.ended, summary.active, summary.maxActive, summary.gestures]
        #expect(counters == [0, 0, 0, 0, 0, 0])
        // The contact that was down across the reset is no longer known.
        #expect(recorder.record(key: 2, phase: .ended, point: point(1, 1), timestamp: 3) == nil)
        let next = try recorder.expectRecord(key: 3, phase: .began, point: point(1, 1), timestamp: 4)
        #expect(next.seq == 1 && next.contact == 0 && next.session == "new")
    }

    @Test func sessionIdentifiersAreSixteenHexCharactersAndDiffer() {
        let ids = (0..<64).map { _ in makeProbeSessionID() }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 16 && $0.allSatisfy { "0123456789abcdef".contains($0) } })
    }
}
