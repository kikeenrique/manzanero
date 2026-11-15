import Foundation
import Synchronization
import Testing
@testable import Manzanero

private actor OCRCleanupGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct ScreenTextTests {
    private func fixture(_ body: (String) async throws -> Void) async throws {
        try await ScreenCommandTests().fixture { directory in
            let image = directory.appendingPathComponent("fixture.png")
            try ScreenCommandTests().png(image)
            try await body(image.path)
        }
    }

    @Test func successfulRecognitionPreservesRegionsAndFailureType() async throws {
        try await fixture { path in
            let result = try await ScreenText.recognize(path: path, perform: { _ in ScreenCommandTests.text(path).regions })
            #expect(result.source == path && result.coordinateSpace == "normalized-top-left")
            #expect(result.regions.first?.text == "Synthetic" && result.regions.first?.confidence == 0.9)
            struct FixtureError: Error {}
            await #expect(throws: FixtureError.self) {
                try await ScreenText.recognize(path: path, perform: { _ in throw FixtureError() })
            }
        }
    }

    @Test func invalidDeadlinesNeverInvokeRecognition() async {
        for timeout: Duration in [.zero, .seconds(-1), .seconds(301)] {
            await #expect(throws: CommandFailure.self) {
                try await ScreenText.recognize(path: "missing", timeout: timeout, perform: { _ in
                    Issue.record("Invalid deadline invoked recognition"); return []
                })
            }
        }
    }

    @Test func preCancelledCallNeverInvokesRecognitionOrMasksCancellationAsAFileError() async {
        let gate = OCRCleanupGate()
        let call = Task { @concurrent in
            await gate.wait()
            return try await ScreenText.recognize(path: "missing", perform: { _ in
                Issue.record("Cancelled call invoked recognition"); return []
            })
        }
        call.cancel()
        await gate.release()
        if case .failure(let error) = await call.result { #expect(error is CancellationError) }
        else { Issue.record("Pre-cancelled OCR returned success") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func deadlineCancelsAndDrainsEvenIfRecognizerReturnsLate(callerCancelsDuringDrain: Bool) async throws {
        try await fixture { path in
            let gate = OCRCleanupGate(), started = OCRCleanupGate(), cleaningStarted = OCRCleanupGate()
            let clock = ManualTestClock()
            let cleaning = Mutex(false), completed = Mutex(false), returned = Mutex(false)
            let call = Task { @concurrent in
                defer { returned.withLock { $0 = true } }
                return try await ScreenText.recognize(path: path, timeout: .seconds(1), clock: clock, perform: { _ in
                    await started.release()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch {
                        cleaning.withLock { $0 = true }
                        await cleaningStarted.release()
                        await gate.wait()
                        completed.withLock { $0 = true }
                        // Simulate an API that returns observations after
                        // cancellation. Those observations must be discarded.
                        return ScreenCommandTests.text(path).regions
                    }
                    return []
                })
            }
            // Expire the deadline only once recognition is running, then wait
            // for the cancellation it causes to reach the recognizer.
            await started.wait()
            clock.advance(by: .seconds(1))
            await cleaningStarted.wait()
            #expect(cleaning.withLock { $0 })
            #expect(returned.withLock { $0 } == false && completed.withLock { $0 } == false)
            if callerCancelsDuringDrain { call.cancel() }
            await gate.release()
            let result = await call.result
            #expect(completed.withLock { $0 } && returned.withLock { $0 })
            if case .failure(let error) = result {
                if callerCancelsDuringDrain { #expect(error is CancellationError) }
                else { #expect(error is ScreenText.DeadlineExceeded) }
            } else { Issue.record("Late OCR observations became success") }
        }
    }

    @Test(.timeLimit(.minutes(1))) func callerCancellationReachesRecognitionAndDrainsIt() async throws {
        try await fixture { path in
            let started = Mutex(false), finished = Mutex(false), running = OCRCleanupGate()
            let call = Task { @concurrent in
                try await ScreenText.recognize(path: path, clock: ManualTestClock(), perform: { _ in
                    defer { finished.withLock { $0 = true } }
                    started.withLock { $0 = true }
                    await running.release()
                    try await Task.sleep(for: .seconds(30))
                    return []
                })
            }
            await running.wait()
            call.cancel()
            if case .failure(let error) = await call.result { #expect(error is CancellationError) }
            else { Issue.record("Cancelled OCR returned observations") }
            #expect(started.withLock { $0 } && finished.withLock { $0 })
        }
    }

    @Test(arguments: [ScreenCommand.Mode.automatic, .ocr])
    func screenTimeoutKeepsImageAndDistinguishesForcedFailure(mode: ScreenCommand.Mode) async throws {
        try await ScreenCommandTests().fixture { directory in
            let screen = ScreenCommand(platform: "physical", device: "fixture", mode: mode)
            let image = directory.appendingPathComponent("screen.png")
            do {
                let bytes = try await screen.execute(directory: directory, run: { plan in
                    #expect(plan.arguments.contains("screenshot"))
                    try ScreenCommandTests().png(image); return Data("{}".utf8)
                }, hierarchy: { throw CommandFailure(description: "Fixture hierarchy unavailable") }, recognize: { path in
                    try await ScreenText.recognize(path: path, timeout: .milliseconds(50), perform: { _ in
                        try await Task.sleep(for: .seconds(30)); return []
                    })
                })
                #expect(mode == .automatic)
                let value = try ScreenCommandTests().json(bytes)
                #expect(value["method"] as? String == "image-only" && value["status"] as? String == "partial")
                #expect((value["diagnostics"] as? [String])?.contains { $0.contains("deadline exceeded") } == true)
            } catch {
                #expect(mode == .ocr && error is CommandFailure)
                #expect(String(describing: error).contains(image.path) && String(describing: error).contains("deadline exceeded"))
            }
            #expect(FileManager.default.fileExists(atPath: image.path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_OCR_TEST_IMAGE"] != nil))
    func explicitlySelectedLocalImageUsesNativeVisionWithDeadline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MANZANERO_OCR_TEST_IMAGE"])
        let milliseconds = try #require(Int64(ProcessInfo.processInfo.environment["MANZANERO_OCR_TEST_TIMEOUT_MS"] ?? "120000"))
        let expectTimeout = ProcessInfo.processInfo.environment["MANZANERO_OCR_EXPECT_TIMEOUT"] == "1"
        let start = ContinuousClock.now
        var outcome = "recognized", count = 0
        do {
            let result = try await ScreenText.recognize(path: path, timeout: .milliseconds(milliseconds))
            count = result.regions.count
            #expect(expectTimeout == false)
            #expect(count > 0)
        } catch is ScreenText.DeadlineExceeded {
            outcome = "deadline-exceeded-after-drain"
            #expect(expectTimeout)
        }
        let elapsed = start.duration(to: .now).components
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/ocr-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["image": path, "timeoutMilliseconds": milliseconds, "outcome": outcome,
            "regionCount": count, "elapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "cooperativeCancellation": true, "recognitionTaskDrained": true, "physicalDeviceQueried": false]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
    }
}
