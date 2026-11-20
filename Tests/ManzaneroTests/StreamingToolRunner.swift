import Foundation
import Testing
@testable import Manzanero

private actor StreamCollector {
    var data = Data()
    func append(_ bytes: Data) { data.append(bytes) }
}

// The runner's deadline is measured by an injected clock. Tests that are not
// about the deadline pass a manual clock that never moves, so a loaded runner
// cannot turn a slow spawn into a spurious "timed out"; the time limit turns a
// stuck child into a failure instead of a hang.
@Suite(.timeLimit(.minutes(1)))
struct StreamingToolRunnerTests {
    @Test func streamsLiteralArgumentsWithoutShellEvaluation() async throws {
        let collector = StreamCollector()
        let text = "ñ 🙂 $(touch sentinel); `literal`\n"
        try await StreamingToolRunner().run(executable: "/usr/bin/printf", arguments: ["%s", text], timeout: 2, clock: ManualTestClock()) {
            await collector.append($0)
        }
        #expect(await collector.data == Data(text.utf8))
    }

    @Test func preservesBinaryOutputAcrossPipeBoundaries() async throws {
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/stream-fixture-\(UUID().uuidString)")
        let bytes = Data((0..<200000).map { UInt8($0 % 256) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let collector = StreamCollector()
        try await StreamingToolRunner().run(executable: "/bin/cat", arguments: [file.path], timeout: 2, clock: ManualTestClock()) {
            await collector.append($0)
        }
        #expect(await collector.data == bytes)
    }

    @Test func failingChildPreservesStatusAndDiagnostics() async throws {
        do {
            try await StreamingToolRunner().run(executable: "/bin/sh", arguments: ["-c", "printf fixture-error >&2; exit 7"], timeout: 2,
                                                clock: ManualTestClock()) { _ in }
            Issue.record("Expected failed child")
        } catch {
            #expect(String(describing: error).contains("exited(7)"))
            #expect(String(describing: error).contains("fixture-error"))
        }
    }

    // The deadline expires only once the child is running (it has written its
    // first output), so the test always exercises stopping a live child. The
    // elapsed bound stays on the wall clock because it is the subject: the
    // owned child must be stopped and reaped, not left to finish its 120 s.
    // The bound is wide on purpose: 3 s failed once under load on 2026-11-20.
    @Test func timeoutStopsAndReapsOwnedChild() async throws {
        let clock = ManualTestClock(), start = ContinuousClock.now
        do {
            try await StreamingToolRunner().run(executable: "/bin/sh", arguments: ["-c", "echo running; exec /bin/sleep 120"],
                                                timeout: 0.05, clock: clock) { _ in
                clock.advance(by: .seconds(1))
            }
            Issue.record("Expected process deadline")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    // With the deadline clock stopped, the only ways out of `yes` are the
    // consumer failure or the byte limit under test.
    @Test(arguments: [false, true]) func consumerAndByteLimitFailuresStopStreaming(consumerFailure: Bool) async throws {
        let start = ContinuousClock.now
        do {
            try await StreamingToolRunner().run(executable: "/usr/bin/yes", arguments: [], timeout: 2, clock: ManualTestClock(),
                maximumOutputBytes: consumerFailure ? 1024 * 1024 : 32) { _ in
                if consumerFailure { throw CommandFailure(description: "fixture consumer stopped") }
            }
            Issue.record("Expected streaming failure")
        } catch {
            #expect(String(describing: error).contains(consumerFailure ? "fixture consumer stopped" : "output byte limit"))
        }
        #expect(ContinuousClock.now - start < .seconds(30))
    }
}

private actor CaptureCollector {
    var output = Data(), errors = Data()
    func append(_ stream: StreamingToolRunner.CaptureStream, _ bytes: Data) {
        if stream == .output { output.append(bytes) } else { errors.append(bytes) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StreamingCaptureTests {
    @Test func capturesBothStreamsAndEnvironmentOverlay() async throws {
        let collector = CaptureCollector()
        let end = try await StreamingToolRunner().capture(executable: "/bin/sh",
            arguments: ["-c", "printf \"out-$CAPTURE_FIXTURE\"; printf err >&2"],
            environment: ["CAPTURE_FIXTURE": "x y"], hardDeadline: 5, clock: ManualTestClock()) {
            await collector.append($0, $1); return true
        }
        #expect(end == .exited(.exited(0)))
        #expect(await collector.output == Data("out-x y".utf8))
        #expect(await collector.errors == Data("err".utf8))
    }

    @Test func nonzeroExitIsReturnedForTheCallerToJudge() async throws {
        let end = try await StreamingToolRunner().capture(executable: "/bin/sh", arguments: ["-c", "exit 64"],
                                                          hardDeadline: 5, clock: ManualTestClock()) { _, _ in true }
        #expect(end == .exited(.exited(64)))
    }

    // The consumer stops `yes` after its first chunk; the child must be torn
    // down rather than run until the (stopped) clock's deadline.
    @Test func consumerStopEndsAndReapsTheChild() async throws {
        let start = ContinuousClock.now
        let end = try await StreamingToolRunner().capture(executable: "/usr/bin/yes", arguments: [],
                                                          hardDeadline: 5, clock: ManualTestClock()) { _, _ in false }
        #expect(end == .consumerStopped)
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    // The soft deadline fires once the child is running (its first output
    // advances the manual clock); the child traps SIGINT, reports it and exits.
    @Test func softDeadlineSendsTheStopSignalAndKeepsReading() async throws {
        let clock = ManualTestClock(), collector = CaptureCollector()
        let end = try await StreamingToolRunner().capture(executable: "/bin/sh",
            arguments: ["-c", "trap 'echo stopped; exit 3' INT; echo running; while :; do /bin/sleep 0.05; done"],
            softDeadline: 1, hardDeadline: 30, clock: clock) { stream, data in
            await collector.append(stream, data)
            clock.advance(by: .seconds(2))
            return true
        }
        #expect(end == .softDeadline(.exited(3)))
        #expect(String(decoding: await collector.output, as: UTF8.self).contains("stopped"))
    }

    @Test func hardDeadlineStopsAndReapsTheChild() async throws {
        let clock = ManualTestClock(), start = ContinuousClock.now
        do {
            _ = try await StreamingToolRunner().capture(executable: "/bin/sh", arguments: ["-c", "echo running; exec /bin/sleep 120"],
                                                        hardDeadline: 0.05, clock: clock) { _, _ in
                clock.advance(by: .seconds(1)); return true
            }
            Issue.record("Expected hard deadline")
        } catch let failure as CommandFailure {
            #expect(failure.code == .timeout)
        }
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    @Test func refusesNonAppleExecutables() async {
        await #expect(throws: CommandFailure.self) {
            _ = try await StreamingToolRunner().capture(executable: "/opt/homebrew/bin/idevicesyslog", arguments: [],
                                                        hardDeadline: 1) { _, _ in true }
        }
    }
}

@Suite(.dedicatedThread)
struct ToolRunnerEnvironmentTests {
    @Test func overlaysEnvironmentWithoutShellEvaluation() throws {
        let output = try ToolRunner().run(["-c", "printf %s \"$RUNNER_FIXTURE\""], executable: "/bin/sh",
                                          environment: ["RUNNER_FIXTURE": "$(touch sentinel)"])
        #expect(String(decoding: output, as: UTF8.self) == "$(touch sentinel)")
    }
}
