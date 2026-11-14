import Foundation
import Testing
@testable import AppleDevicesCMD

struct RecordingCommandTests {
    let simulator = "11111111-2222-3333-4444-555555555555"

    @Test func nativeDurationAndTimeoutCoverWholePhysicalRecording() throws {
        let recording = try #require(try RecordingCommand.parse(["physical", "phone", "record", "tmp/My Video.mp4", "300", "hevc"]))
        let plan = try recording.command(staging: URL(fileURLWithPath: "/project/tmp/capture.mp4"))
        #expect(plan.arguments == ["devicectl", "device", "capture", "screen-record", "--device", "phone", "--destination", "/project/tmp/capture.mp4", "--duration", "300.0", "--codec", "hevc", "--timeout", "360", "--json-output", "-"])
        #expect(plan.jsonOutput)
    }

    @Test func simulatorUsesExplicitTargetAndDoesNotForceOverwrite() throws {
        let recording = try #require(try RecordingCommand.parse(["simulator", simulator, "record", "tmp/video.mp4", "1.5"]))
        let plan = try recording.command(staging: URL(fileURLWithPath: "/project/tmp/video with spaces.mp4"))
        #expect(plan.arguments == ["simctl", "io", simulator, "recordVideo", "--codec=h264", "/project/tmp/video with spaces.mp4"])
    }

    @Test(arguments: [
        ["physical", "phone", "record", "tmp/x.mp4", "0"],
        ["physical", "phone", "record", "tmp/x.mp4", "301"],
        ["physical", "phone", "record", "tmp/x.mp4", "nan"],
        ["physical", "phone", "record", "tmp/x.mp4", "inf"],
        ["physical", "phone", "record", "tmp/x.mov", "2"],
        ["physical", "phone", "record", "-x.mp4", "2"],
        ["physical", "phone", "record", "tmp/x.mp4", "2", "h265"],
        ["simulator", "booted", "record", "tmp/x.mp4", "2"]
    ]) func invalidArguments(_ args: [String]) {
        #expect(throws: CommandFailure.self) { try RecordingCommand.parse(args) }
    }

    @Test func refusesExistingDestinationBeforeStartingARecorder() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/record-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing content must survive".utf8)
        try sentinel.write(to: destination)
        let recording = try #require(try RecordingCommand.parse(["physical", "nonexistent-device", "record", destination.path, "1"]))
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
        try ToolRunner().recordSimulator(["-c", script], timing: .init(seconds: 0.05, startupSeconds: 2, finalizationSeconds: 1), executable: "/usr/bin/python3")
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
            try ToolRunner().recordSimulator(["-c", script], timing: .init(seconds: 0.01, startupSeconds: 2, finalizationSeconds: 0.1), executable: "/usr/bin/python3")
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
