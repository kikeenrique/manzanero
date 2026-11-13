import AppleDeviceBridge
import Foundation
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalTouchTests {
    func display(rotation: String = "rot0", light: String = "activeOn", duplicate: Bool = false) throws -> Data {
        let value: [String: Any] = ["primary": true, "type": ["integrated": [:]], "displayId": 1,
            "bounds": [[0, 0], [1125, 2436]], "pointScale": 3, "nativeOrientation": "rot0",
            "currentOrientation": rotation, "backlightState": light]
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["displays": duplicate ? [value, value] : [value]]])
    }

    @Test func rotatesNormalizedInterfacePointsIntoPortraitDigitizerSpace() throws {
        let expected = [("rot0", 0.2, 0.3), ("rot90", 0.3, 0.8), ("rot180", 0.8, 0.7), ("rot270", 0.7, 0.2)]
        for (rotation, x, y) in expected {
            let point = try DirectTouchDisplay(display(rotation: rotation)).portrait(0.2, 0.3)
            #expect(abs(point.0 - x) < 0.000001 && abs(point.1 - y) < 0.000001)
        }
        for metadata in [try display(rotation: "unknown"), try display(light: "inactive"), try display(duplicate: true), Data("{}".utf8)] {
            #expect(throws: CommandFailure.self) { try DirectTouchDisplay(metadata) }
        }
    }

    @Test func schedulesCompleteTapHoldAndDragBeforeSending() throws {
        let geometry = try DirectTouchDisplay(display())
        let input = CoreDeviceInputTests()
        let tap = try DirectPhysicalTouch.plan(input.input(["tap", "0.2", "0.3"]), display: geometry)
        #expect(tap.first?.phase == 0 && tap.last?.phase == 2)
        #expect(tap.dropFirst().dropLast().allSatisfy { $0.phase == 1 })
        #expect(tap.first?.nanoseconds == 0 && tap.last?.nanoseconds == 80_000_000)
        let hold = try DirectPhysicalTouch.plan(input.input(["long-press", "0.2", "0.3", "0.8"]), display: geometry)
        #expect(hold.last?.nanoseconds == 800_000_000)
        let drag = try DirectPhysicalTouch.plan(input.input(["drag", "0.1", "0.2", "0.9", "0.8", "0.5"]), display: geometry)
        #expect(drag.count == 32)
        #expect(drag.first?.phase == 0 && drag.last?.phase == 2)
        #expect(drag.dropFirst().dropLast().allSatisfy { $0.phase == 1 })
        #expect(drag.last?.x == 0.9 && drag.last?.y == 0.8)
        #expect(drag.last?.nanoseconds == 501_000_000)
        #expect(zip(drag, drag.dropFirst()).allSatisfy { $0.nanoseconds < $1.nanoseconds })
    }

    @Test func rechecksDisplayBeforeExactlyOneDispatchAndDoesNotRetryFailures() throws {
        let input = try CoreDeviceInputTests().input(["tap", "0.5", "0.5"])
        var calls = 0, sends = 0
        let output = try DirectPhysicalTouch.execute(input, query: { plan in
            calls += 1
            return try plan.arguments.contains("details") ? DirectPhysicalInputTests().details() : display()
        }, send: { uuid, version, samples in
            sends += 1
            #expect(calls == 3)
            #expect(uuid == CoreDeviceInputTests().uuid && version == "651.32")
            #expect(samples.count == 6)
        })
        #expect(sends == 1)
        #expect(String(decoding: output, as: UTF8.self).contains("coredevice-direct"))
        calls = 0; sends = 0
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTouch.execute(input, query: { plan in
                calls += 1
                if plan.arguments.contains("details") { return try DirectPhysicalInputTests().details() }
                return try display(rotation: calls == 2 ? "rot0" : "rot90")
            }, send: { _, _, _ in sends += 1 })
        }
        #expect(sends == 0)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTouch.execute(input, query: { plan in
                try plan.arguments.contains("details") ? DirectPhysicalInputTests().details() : display()
            }, send: { _, _, _ in sends += 1; throw CommandFailure(description: "fixture send failure") })
        }
        #expect(sends == 1)
    }

    @Test func bridgeRejectsInvalidSchedulesBeforeFrameworkOrDeviceAccess() {
        var error = [CChar](repeating: 0, count: 1024)
        for samples in [
            [ADCTouchSample(nanoseconds: 0, x: .nan, y: 0, phase: 0), ADCTouchSample(nanoseconds: 1, x: 0, y: 0, phase: 2)],
            [ADCTouchSample(nanoseconds: 0, x: 0, y: 0, phase: 0), ADCTouchSample(nanoseconds: 0, x: 0, y: 0, phase: 2)],
            [ADCTouchSample(nanoseconds: 0, x: 0, y: 0, phase: 0), ADCTouchSample(nanoseconds: 1, x: 0, y: 0, phase: 1)]
        ] {
            let status = samples.withUnsafeBufferPointer { ADCPerformTouch("invalid", "invalid", $0.baseAddress, $0.count, nil, &error, error.count) }
            #expect(status != 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("sequence"))
        }
    }
}
