import Foundation
import ProbeCore
import Testing

struct LogProbeTests {
    @Test func launchTokenComesFromItsArgumentOnlyWhenValid() {
        #expect(LogProbe.token(arguments: ["ProbeApp"]) == "launch")
        #expect(LogProbe.token(arguments: ["ProbeApp", "-probeLogToken", "T-1.a_b"]) == "T-1.a_b")
        #expect(LogProbe.token(arguments: ["ProbeApp", "-probeLogToken"]) == "launch")
        #expect(LogProbe.token(arguments: ["ProbeApp", "-probeLogToken", "has space"]) == "launch")
        #expect(LogProbe.token(arguments: ["ProbeApp", "-probeLogToken", "\"quote"]) == "launch")
        #expect(LogProbe.token(arguments: ["ProbeApp", "-probeLogToken", String(repeating: "a", count: 65)]) == "launch")
    }

    @Test func crashNeedsTheExplicitArgumentAndAKnownMode() {
        #expect(LogProbe.crashMode(arguments: ["ProbeApp"]) == nil)
        #expect(LogProbe.crashMode(arguments: ["ProbeApp", "-probeCrash"]) == nil)
        #expect(LogProbe.crashMode(arguments: ["ProbeApp", "-probeCrash", "yes"]) == nil)
        #expect(LogProbe.crashMode(arguments: ["ProbeApp", "-probeLogToken", "abort"]) == nil)
        #expect(LogProbe.crashMode(arguments: ["ProbeApp", "-probeCrash", "abort"]) == .abort)
        #expect(LogProbe.crashMode(arguments: ["ProbeApp", "-probeCrash", "trap"]) == .trap)
    }

    @Test func emitTriggerHasItsOwnNamespace() {
        #expect(LogProbe.emitIdentifier == "probe.log.emit")
        #expect(!LogProbe.emitIdentifier.hasPrefix("probe.touch."))
        #expect(LogProbe.isValidToken(LogProbe.emitToken))
        #expect(LogProbe.emitValue(sets: 2) == #"{"sets":2}"#)
    }

    @Test func oneSetCoversEveryLevelAndStream() {
        let set = LogProbe.emissions(token: "T", sequence: 3)
        #expect(set.map(\.channel) == [.log(.debug), .log(.info), .log(.notice), .log(.error), .log(.fault),
                                       .logPrivate, .stdoutFlushed, .stdoutUnflushed, .stderr])
        #expect(set[2].text == "probe.log T #3 level=default")
        #expect(set[0].text == "probe.log T #3 level=debug")
        #expect(set[5].text == "probe.log T #3 private=")
        #expect(set[5].privateValue == "secret-T")
        #expect(set[6].text == "stdout T #3 flushed")
        #expect(set[7].text == "stdout T #3 unflushed")
        #expect(set[8].text == "stderr T #3")
        #expect(set.allSatisfy { $0.text.contains("T #3") })
        #expect(LogProbe.Level.notice.logName == "default")
        #expect(LogProbe.crashLine(token: "T", mode: .abort) == "probe.log T about to crash mode=abort")
    }
}
