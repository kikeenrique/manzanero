import AppleDeviceBridge
import Foundation
import Synchronization
import Testing
@testable import Manzanero

struct IndigoCancellationTests {
    private var touch: [ADCTouchSample] {
        [ADCTouchSample(nanoseconds: 0, x: 0.2, y: 0.3, phase: 0),
         ADCTouchSample(nanoseconds: 1, x: 0.3, y: 0.4, phase: 1),
         ADCTouchSample(nanoseconds: 10_000_000_000, x: 0.3, y: 0.4, phase: 2)]
    }
    private var keys: [ADCKeyboardSample] {
        [ADCKeyboardSample(nanoseconds: 0, usage: 225, state: 1),
         ADCKeyboardSample(nanoseconds: 1, usage: 4, state: 1),
         ADCKeyboardSample(nanoseconds: 10_000_000_000, usage: 4, state: 2),
         ADCKeyboardSample(nanoseconds: 10_001_000_000, usage: 225, state: 2)]
    }

    @Test(arguments: [false, true]) func interruptedTouchReleasesLastAttemptedPoints(paired: Bool) {
        let samples = touch
        let second = [ADCTouchPoint(x: 0.8, y: 0.3), ADCTouchPoint(x: 0.7, y: 0.4), ADCTouchPoint(x: 0.7, y: 0.4)]
        var sent: [[Double]] = []
        let result = samples.withUnsafeBufferPointer { first in
            second.withUnsafeBufferPointer { second in
                ADCRunTouchSchedule(first.baseAddress, paired ? second.baseAddress : nil, first.count,
                    { sent.count >= 2 ? 1 : 0 }, { sample, second in
                        if let sample {
                            let point = sample.pointee
                            sent.append([Double(point.phase), point.x, point.y] + (second.map { [$0.pointee.x, $0.pointee.y] } ?? []))
                        }
                    })
            }
        }
        #expect(result == 1 && sent.count == 3)
        #expect(sent[1] == [1, 0.3, 0.4] + (paired ? [0.7, 0.4] : []))
        #expect(sent[2] == [2, 0.3, 0.4] + (paired ? [0.7, 0.4] : []))
    }

    @Test func interruptedKeyboardReleasesOrdinaryKeysBeforeModifiersWithoutReplay() {
        var sent: [[UInt64]] = []
        let result = keys.withUnsafeBufferPointer {
            ADCRunKeyboardSchedule($0.baseAddress, $0.count, { sent.count >= 2 ? 1 : 0 }, { sent.append([$0, $1]) })
        }
        #expect(result == 1 && sent == [[225, 1], [4, 1], [4, 2], [225, 2]])
    }

    @Test(arguments: [UInt64(64), 48, 42]) func interruptedButtonOrNamedKeyStillAttemptsUp(usage: UInt64) {
        var sent: [[UInt64]] = []
        let result = ADCRunPress(usage, 400_000, { sent.isEmpty ? 0 : 1 }, { sent.append([$0, $1]) })
        #expect(result == 1 && sent == [[usage, 1], [usage, 2]])
    }

    @Test func preCancellationAndMalformedSchedulesNeverInvokeSinks() {
        let unexpectedTouch: ADCTouchSink = { _, _ in Issue.record("Unexpected touch dispatch") }
        let unexpectedKey: ADCKeySink = { _, _ in Issue.record("Unexpected key dispatch") }
        let touchResult = touch.withUnsafeBufferPointer { ADCRunTouchSchedule($0.baseAddress, nil, $0.count, { 1 }, unexpectedTouch) }
        let keyboardResult = keys.withUnsafeBufferPointer { ADCRunKeyboardSchedule($0.baseAddress, $0.count, { 1 }, unexpectedKey) }
        #expect(touchResult == 1 && keyboardResult == 1 && ADCRunPress(64, 80_000, { 1 }, unexpectedKey) == 1)
        #expect(ADCRunTouchSchedule(nil, nil, 0, { Issue.record("Invalid touch checked cancellation"); return 0 }, unexpectedTouch) == 2)
        #expect(ADCRunKeyboardSchedule(nil, 0, { Issue.record("Invalid keyboard checked cancellation"); return 0 }, unexpectedKey) == 2)
        #expect(ADCRunPress(9999, 80_000, { Issue.record("Invalid press checked cancellation"); return 0 }, unexpectedKey) == 2)
    }

    @Test func balancedCompletionDoesNotDuplicateRelease() {
        let samples = [ADCTouchSample(nanoseconds: 0, x: 0.5, y: 0.5, phase: 0),
                       ADCTouchSample(nanoseconds: 1, x: 0.5, y: 0.5, phase: 2)]
        var phases: [UInt64] = []
        let touchResult = samples.withUnsafeBufferPointer {
            ADCRunTouchSchedule($0.baseAddress, nil, $0.count, { 0 }, { sample, _ in
                if let sample { phases.append(sample.pointee.phase) }
            })
        }
        var events: [[UInt64]] = []
        let keys = [ADCKeyboardSample(nanoseconds: 0, usage: 4, state: 1), ADCKeyboardSample(nanoseconds: 1, usage: 4, state: 2)]
        let keyboardResult = keys.withUnsafeBufferPointer {
            ADCRunKeyboardSchedule($0.baseAddress, $0.count, { 0 }, { events.append([$0, $1]) })
        }
        #expect(touchResult == 0 && phases == [0, 2])
        #expect(keyboardResult == 0 && events == [[4, 1], [4, 2]])
    }

    @Test func preCancelledBridgeRequestsStopBeforeFrameworkIdentityResolution() {
        var error = [CChar](repeating: 0, count: 512)
        func check(_ status: Int32) {
            #expect(status != 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("cancelled before transport"))
        }
        check(ADCPressButton("invalid", "invalid", 64, 80_000, { 1 }, &error, error.count))
        check(ADCPressKeyboardKey("invalid", "invalid", 42, { 1 }, &error, error.count))
        check(keys.withUnsafeBufferPointer { ADCPerformKeyboard("invalid", "invalid", $0.baseAddress, $0.count, { 1 }, &error, error.count) })
        check(touch.withUnsafeBufferPointer { ADCPerformTouch("invalid", "invalid", $0.baseAddress, $0.count, { 1 }, &error, error.count) })
    }

    @Test func swiftTaskCancellationInterruptsIndigoKeyboardGap() async throws {
        let sent = Mutex<[[UInt64]]>([])
        let task = Task { @concurrent in
            let keys = [ADCKeyboardSample(nanoseconds: 0, usage: 4, state: 1), ADCKeyboardSample(nanoseconds: 10_000_000_000, usage: 4, state: 2)]
            return keys.withUnsafeBufferPointer {
                ADCRunKeyboardSchedule($0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, { usage, state in
                    sent.withLock { $0.append([usage, state]) }
                })
            }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while sent.withLock({ $0.isEmpty }), ContinuousClock.now < deadline { await Task.yield() }
        let started = sent.withLock { !$0.isEmpty }
        task.cancel()
        let result = await task.value
        #expect(started && result == 1)
        #expect(sent.withLock { $0 } == [[4, 1], [4, 2]])
    }

    @Test func pastePreservesCancellationAfterClipboardReplacement() throws {
        let input = CoreDeviceInput(device: CoreDeviceInputTests().udid, operation: "paste", operands: ["synthetic"])
        var copies = 0, sends = 0
        do {
            _ = try DirectPhysicalPaste.execute(input, query: { _ in try DirectPhysicalInputTests().details() }, copy: { _, _ in
                copies += 1
                return Data("{\"info\":{\"outcome\":\"success\"}}".utf8)
            }, send: { _ in sends += 1; throw CancellationError() })
            Issue.record("Paste converted cancellation into success")
        } catch is CancellationError {
            #expect(copies == 1 && sends == 1)
        }
    }
}
