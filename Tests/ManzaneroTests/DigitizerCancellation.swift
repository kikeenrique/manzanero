import AppleDeviceBridge
import Foundation
import Synchronization
import Testing
@testable import Manzanero

// The C schedules sleep between reports on the calling thread.
@Suite(.dedicatedThread)
struct DigitizerCancellationTests {
    private func sequence() throws -> NativeGestureSequence {
        try NativeGestureSequence(json: """
        {"frames":[
          {"ms":0,"touches":[{"id":0,"x":0.2,"y":0.3},{"id":1,"x":0.8,"y":0.3}]},
          {"ms":1,"touches":[{"id":0,"x":0.3,"y":0.4},{"id":1,"x":0.7,"y":0.4}]},
          {"ms":10000,"touches":[]}
        ]}
        """)
    }

    @Test func preCancelledScheduleNeverInvokesSinkOrOpensFramework() throws {
        let sequence = try sequence(), bytes = sequence.reports.flatMap { $0 }
        let times = sequence.times.map { UInt64($0) * 1_000_000 }
        let result = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCRunDigitizerSchedule(times.baseAddress, reports.baseAddress, times.count, { 1 }, { _ in
                    Issue.record("Pre-cancelled schedule sent input")
                })
            }
        }
        #expect(result == 1)
        var error = [CChar](repeating: 0, count: 512), surface: UInt64 = 999
        let status = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCPerformCancellableDigitizerReports("invalid", "invalid", nil, times.baseAddress, reports.baseAddress,
                    times.count, { 1 }, &surface, &error, error.count)
            }
        }
        #expect(status != 0 && surface == 0)
        #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("cancelled before transport"))
    }

    @Test func interruptionReleasesOnlyLastAttemptedPositionsWithoutFutureMovement() throws {
        let sequence = try sequence(), bytes = sequence.reports.flatMap { $0 }
        let times = sequence.times.map { UInt64($0) * 1_000_000 }
        var sent: [[UInt8]] = []
        let result = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCRunDigitizerSchedule(times.baseAddress, reports.baseAddress, times.count,
                    { sent.count >= 2 ? 1 : 0 }, { report in
                        if let report { sent.append(Array(UnsafeBufferPointer(start: report, count: 58))) }
                    })
            }
        }
        #expect(result == 1 && sent.count == 3)
        #expect(Array(sent.prefix(2)) == Array(sequence.reports.prefix(2)))
        var release = sequence.reports[1]
        release[3] = 0; release[8] = 1
        #expect(sent.last == release)
    }

    @Test(.timeLimit(.minutes(1))) func swiftTaskCancellationInterruptsLongGapAndAttemptsRelease() async throws {
        let sequence = try sequence(), bytes = sequence.reports.flatMap { $0 }
        let times = sequence.times.map { UInt64($0) * 1_000_000 }
        let sent = Mutex<[[UInt8]]>([]), firstReport = TestSignal()
        // The C schedule blocks its thread through the 10 s gap. Running it on
        // a cooperative pool thread could leave the test itself without a
        // thread to cancel it on a small runner, so the task prefers a thread
        // of its own; it is still a Swift task, so Task.isCancelled reaches C.
        let executor = DedicatedThreadExecutor()
        defer { executor.stop() }
        let task = Task(executorPreference: executor) {
            times.withUnsafeBufferPointer { times in
                bytes.withUnsafeBufferPointer { reports in
                    ADCRunDigitizerSchedule(times.baseAddress, reports.baseAddress, times.count,
                        { Task.isCancelled ? 1 : 0 }, { report in
                            if let report {
                                let bytes = Array(UnsafeBufferPointer(start: report, count: 58))
                                sent.withLock { $0.append(bytes) }
                                firstReport.signal()
                            }
                        })
                }
            }
        }
        defer { task.cancel() }
        let started = await firstReport.wait()
        task.cancel()
        let result = await task.value
        #expect(started && result == 1)
        let reports = sent.withLock { $0 }
        try #require(reports.count >= 2 && reports.count <= 3)
        var expectedRelease = reports[reports.count - 2]
        expectedRelease[3] = 0; expectedRelease[8] = 1
        #expect(reports.last == expectedRelease)
    }

    @Test func completedSequenceDoesNotDuplicateReleaseAndInvalidSequenceInvokesNothing() throws {
        let sequence = try NativeGestureSequence(json: NativeGestureSequenceTests().doubleTap)
        let bytes = sequence.reports.flatMap { $0 }
        // Shorten the local fixture; the byte layout is unchanged.
        let times: [UInt64] = [0, 1, 2, 3]
        var sent: [[UInt8]] = []
        let result = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCRunDigitizerSchedule(times.baseAddress, reports.baseAddress, times.count, { 0 }, { report in
                    if let report { sent.append(Array(UnsafeBufferPointer(start: report, count: 58))) }
                })
            }
        }
        #expect(result == 0 && sent == sequence.reports)
        let invalid = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCRunDigitizerSchedule(times.baseAddress, reports.baseAddress, 1,
                    { Issue.record("Invalid schedule checked cancellation"); return 0 },
                    { _ in Issue.record("Invalid schedule sent input") })
            }
        }
        #expect(invalid == 2)
    }
}
