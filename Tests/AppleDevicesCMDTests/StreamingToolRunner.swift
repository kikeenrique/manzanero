import Foundation
import Testing
@testable import AppleDevicesCMD

private actor StreamCollector {
    var data = Data()
    func append(_ bytes: Data) { data.append(bytes) }
}

struct StreamingToolRunnerTests {
    @Test func streamsLiteralArgumentsWithoutShellEvaluation() async throws {
        let collector = StreamCollector()
        let text = "ñ 🙂 $(touch sentinel); `literal`\n"
        try await StreamingToolRunner().run(executable: "/usr/bin/printf", arguments: ["%s", text], timeout: 2) {
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
        try await StreamingToolRunner().run(executable: "/bin/cat", arguments: [file.path], timeout: 2) { await collector.append($0) }
        #expect(await collector.data == bytes)
    }

    @Test func failingChildPreservesStatusAndDiagnostics() async throws {
        do {
            try await StreamingToolRunner().run(executable: "/bin/sh", arguments: ["-c", "printf fixture-error >&2; exit 7"], timeout: 2) { _ in }
            Issue.record("Expected failed child")
        } catch {
            #expect(String(describing: error).contains("exited(7)"))
            #expect(String(describing: error).contains("fixture-error"))
        }
    }

    @Test func timeoutStopsAndReapsOwnedChild() async throws {
        let start = ContinuousClock.now
        do {
            try await StreamingToolRunner().run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05) { _ in }
            Issue.record("Expected process deadline")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test(arguments: [false, true]) func consumerAndByteLimitFailuresStopStreaming(consumerFailure: Bool) async throws {
        let start = ContinuousClock.now
        do {
            try await StreamingToolRunner().run(executable: "/usr/bin/yes", arguments: [], timeout: 2,
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
