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
    // owned child must be stopped and reaped, not left to finish its 10 s.
    @Test func timeoutStopsAndReapsOwnedChild() async throws {
        let clock = ManualTestClock(), start = ContinuousClock.now
        do {
            try await StreamingToolRunner().run(executable: "/bin/sh", arguments: ["-c", "echo running; exec /bin/sleep 10"],
                                                timeout: 0.05, clock: clock) { _ in
                clock.advance(by: .seconds(1))
            }
            Issue.record("Expected process deadline")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(ContinuousClock.now - start < .seconds(3))
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
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
