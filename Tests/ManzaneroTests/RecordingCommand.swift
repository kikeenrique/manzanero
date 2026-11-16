import Foundation
import Testing
@testable import Manzanero

// The recorder fixtures block on child processes with real startup and
// finalization timing; each test gets its own thread instead of a pool thread.
@Suite(.dedicatedThread)
struct RecordingCommandTests {
    let simulator = "11111111-2222-3333-4444-555555555555"

    @Test func nativeDurationAndTimeoutCoverWholePhysicalRecording() throws {
        let recording = try RecordingCommand(physical: true, device: "phone", output: "tmp/My Video.mp4", seconds: "300", codec: "hevc", backend: nil)
        let plan = try recording.command(staging: URL(fileURLWithPath: "/project/tmp/capture.mp4"))
        #expect(plan.arguments == ["devicectl", "device", "capture", "screen-record", "--device", "phone", "--destination", "/project/tmp/capture.mp4", "--duration", "300.0", "--codec", "hevc", "--timeout", "360", "--json-output", "-"])
        #expect(plan.jsonOutput)
    }

    @Test func simulatorUsesExplicitTargetAndDoesNotForceOverwrite() throws {
        let recording = try RecordingCommand(physical: false, device: simulator, output: "tmp/video.mp4", seconds: "1.5", codec: nil, backend: nil)
        let plan = try recording.command(staging: URL(fileURLWithPath: "/project/tmp/video with spaces.mp4"))
        #expect(plan.arguments == ["simctl", "io", simulator, "recordVideo", "--codec=h264", "/project/tmp/video with spaces.mp4"])
    }

    /// Platform, device, output, seconds and an optional codec.
    @Test(arguments: [
        ["physical", "phone", "tmp/x.mp4", "0"],
        ["physical", "phone", "tmp/x.mp4", "301"],
        ["physical", "phone", "tmp/x.mp4", "nan"],
        ["physical", "phone", "tmp/x.mp4", "inf"],
        ["physical", "phone", "tmp/x.mov", "2"],
        ["physical", "phone", "-x.mp4", "2"],
        ["physical", "phone", "tmp/x.mp4", "2", "h265"],
        ["simulator", "booted", "tmp/x.mp4", "2"]
    ]) func invalidArguments(_ args: [String]) {
        #expect(throws: CommandFailure.self) {
            try RecordingCommand(physical: args[0] == "physical", device: args[1], output: args[2], seconds: args[3],
                                 codec: args.count > 4 ? args[4] : nil, backend: nil)
        }
    }

    @Test func refusesExistingDestinationBeforeStartingARecorder() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/record-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing content must survive".utf8)
        try sentinel.write(to: destination)
        let recording = try RecordingCommand(physical: true, device: "nonexistent-device", output: destination.path, seconds: "1", codec: nil, backend: nil)
        await #expect(throws: CommandFailure.self) {
            try await recording.execute(directory: directory.appendingPathComponent("staging"), runner: ToolRunner())
        }
        #expect(try Data(contentsOf: destination) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path))
    }

    @Test func invalidMediaIsNotAcceptedAsARecording() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/invalid-recording-\(UUID().uuidString).mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await VideoArtifact.inspect(url) }
    }

    @Test func recordingTimerStartsAfterFirstFrameAndWaitsForFinalization() throws {
        let script = """
        import signal,sys,time
        def stop(*args):
            sys.stderr.write('finalized\\n'); sys.stderr.flush(); sys.exit(0)
        signal.signal(signal.SIGINT, stop)
        time.sleep(0.10)
        sys.stderr.write('Recording sta'); sys.stderr.flush()
        time.sleep(0.03)
        sys.stderr.write('rted\\n'); sys.stderr.flush()
        while True: time.sleep(0.01)
        """
        let start = ContinuousClock.now
        // The startup and finalization deadlines keep their 30 s defaults: the
        // fixture meets both quickly, but the first `/usr/bin/python3` launch on
        // a fresh hosted image goes through a cold xcrun shim and can take
        // seconds before the child writes anything.
        try ToolRunner().recordSimulator(["-c", script], timing: .init(seconds: 0.05), executable: "/usr/bin/python3")
        #expect(ContinuousClock.now - start >= .milliseconds(170))
    }

    @Test func missingFirstFrameTimesOutAndStopsChild() {
        let script = "import signal,time,sys; signal.signal(signal.SIGINT, lambda *args: sys.exit(0)); time.sleep(10)"
        do {
            try ToolRunner().recordSimulator(["-c", script], timing: .init(seconds: 0.01, startupSeconds: 0.1, finalizationSeconds: 0.1), executable: "/usr/bin/python3")
            Issue.record("Expected startup deadline failure")
        } catch {
            #expect(String(describing: error).contains("startup deadline"))
        }
    }

    @Test func ignoredInterruptCannotHangFinalization() {
        let script = "import signal,time,sys; signal.signal(signal.SIGINT, signal.SIG_IGN); sys.stderr.write('Recording started\\n'); sys.stderr.flush(); time.sleep(10)"
        do {
            // Only the finalization deadline is under test; startup keeps its
            // default so a slow first interpreter launch cannot trip it instead.
            try ToolRunner().recordSimulator(["-c", script], timing: .init(seconds: 0.01, finalizationSeconds: 0.1), executable: "/usr/bin/python3")
            Issue.record("Expected finalization deadline failure")
        } catch {
            #expect(String(describing: error).contains("did not finalize"))
        }
    }

    @Test func earlyRecorderFailurePreservesDiagnostics() {
        do {
            try ToolRunner().recordSimulator(["-c", "import sys; sys.stderr.write('fixture recorder failure'); sys.exit(7)"], timing: .init(seconds: 1), executable: "/usr/bin/python3")
            Issue.record("Expected recorder failure")
        } catch {
            #expect(String(describing: error).contains("fixture recorder failure"))
        }
    }
}
