import Foundation
import Testing
@testable import ProbeAnalysis
@testable import ProbeCore

@Suite struct LogParserTests {
    @Test func parsesAnIntactSession() {
        var simulator = ProbeSimulator()
        simulator.deliver(.multiTap([NormalizedPoint(0.3, 0.4), NormalizedPoint(0.7, 0.4)]))
        let log = ParsedProbeLog.parse(simulator.logData())
        #expect(log.sessions.count == 1)
        #expect(log.sessions[0].header?.reason == "launch")
        #expect(log.sessions[0].events.count == 4)
        #expect(log.sessions[0].contiguousThrough == 4)
        #expect(log.malformedLines.isEmpty)
        #expect(!log.incompleteFinalLine)
        #expect(log.sequenceBreaks == 0)
    }

    @Test func countsMalformedAndIncompleteLines() {
        var simulator = ProbeSimulator()
        simulator.deliver(.tap(NormalizedPoint(0.5, 0.5)))
        var data = simulator.logData()
        data.append(Data("not json\n".utf8))
        data.append(Data(#"{"type":"mystery","session":"aaaaaaaaaaaaaaaa"}"#.utf8))
        data.append(0x0A)
        // The pull raced a write: the final line is cut off and has no newline.
        data.append(Data(#"{"active":1,"contact":1,"kind":"dir"#.utf8))
        let log = ParsedProbeLog.parse(data)
        #expect(log.sessions[0].events.count == 2)
        #expect(log.malformedLines == [4, 5])
        #expect(log.incompleteFinalLine)
    }

    @Test func recordsTruncationAndSequenceGaps() {
        var simulator = ProbeSimulator()
        for x in [0.3, 0.5, 0.7] { simulator.deliver(.tap(NormalizedPoint(x, 0.5))) }
        // Keep the header and the first four events, drop the fifth, keep the sixth, then the marker.
        var lines = simulator.lines
        lines.remove(at: 5)
        lines.append(ProbeJSON.encode(TruncationRecord(session: simulator.session, firstDroppedSeq: 7, limitBytes: 4096)))
        let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let log = ParsedProbeLog.parse(data)
        let session = log.sessions[0]
        #expect(session.events.count == 5)
        #expect(session.contiguousThrough == 4)
        #expect(session.truncation?.firstDroppedSeq == 7)
        #expect(log.sequenceBreaks == 1)
        #expect(session.events(after: 1, through: 3).map(\.seq) == [2, 3])
    }

    @Test func separatesSessionsAndHeaderlessEvents() {
        var first = ProbeSimulator(session: "1111111111111111")
        first.deliver(.tap(NormalizedPoint(0.5, 0.5)))
        var second = ProbeSimulator(session: "2222222222222222")
        second.deliver(.tap(NormalizedPoint(0.5, 0.5)))
        // A file that lost its header line still yields its events under their session.
        var data = Data(first.lines.dropFirst().reduce(into: Data()) { $0.append($1); $0.append(0x0A) })
        data.append(second.logData())
        let log = ParsedProbeLog.parse(data)
        #expect(log.sessions.map(\.session) == ["1111111111111111", "2222222222222222"])
        #expect(log.sessions[0].header == nil)
        #expect(log.sessions[1].header?.session == "2222222222222222")
        #expect(log.session("2222222222222222")?.events.count == 2)
    }

    @Test func rebuildsGesturesFromEvents() {
        var simulator = ProbeSimulator()
        simulator.deliver(.swipe(from: NormalizedPoint(0.5, 0.7), to: NormalizedPoint(0.5, 0.3), seconds: 0.5))
        simulator.deliver(.multiTap([NormalizedPoint(0.3, 0.4), NormalizedPoint(0.7, 0.4)]), .init(keepDown: [1]))
        let events = ParsedProbeLog.parse(simulator.logData()).sessions[0].events
        let gestures = ReceivedTouches.gestures(from: events)
        #expect(gestures.count == 2)
        #expect(gestures[0].complete)
        #expect(gestures[0].contacts[0].moves == 2)
        #expect(gestures[0].contacts[0].end == "ended")
        #expect(abs((gestures[0].contacts[0].duration ?? 0) - 0.501) < 1e-6)
        #expect(!gestures[1].complete)
        #expect(gestures[1].maxActive == 2)
        #expect(gestures[1].contacts[1].end == nil)

        // A window that starts mid-gesture yields a contact without its began.
        let tail = ReceivedTouches.gestures(from: Array(events.dropFirst()))
        #expect(tail[0].contacts[0].sawBegan == false)
        #expect(tail[0].contacts[0].from == nil)
    }
}
