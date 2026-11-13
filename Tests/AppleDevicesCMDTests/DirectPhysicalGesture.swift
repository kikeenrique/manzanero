import AppleDeviceBridge
import Foundation
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalGestureTests {
    @Test func transformsIndependentFiveSlotsAndRechecksDisplayBeforeOneDispatch() throws {
        let contacts = (0..<5).map { ["id": $0, "x": Double($0) / 5, "y": 0.25] }
        let frames: [[String: Any]] = [["ms": 0, "touches": [contacts[0]]], ["ms": 20, "touches": contacts],
            ["ms": 30, "touches": [contacts[4]]], ["ms": 50, "touches": []]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["frames": frames]), as: UTF8.self)
        let input = try CoreDeviceInputTests().input(["gesture", json])
        var reads = 0, sends = 0
        let output = try DirectPhysicalGesture.execute(input, query: { plan in
            reads += 1
            return try plan.arguments.contains("details") ? DirectPhysicalInputTests().details() : DirectPhysicalTouchTests().display(rotation: "rot90")
        }, send: { request in
            sends += 1
            #expect(reads == 3 && request.uuid == CoreDeviceInputTests().uuid && request.version == "651.32")
            #expect(request.sequence.contactCount == 5 && request.sequence.times == [0, 20, 30, 50])
            #expect(request.sequence.reports.map { $0[3] } == [0xc0, 0xc0, 0, 0])
            #expect(request.sequence.reports.map { $0[23] } == [4, 0xc4, 0xc4, 4])
            // rot90: (0, .25) -> (.25, 1), preserving the lift position.
            #expect(Array(request.sequence.reports[0][4..<8]) == [0, 64, 255, 255])
            #expect(request.sequence.reports.last?[1] == 5)
            return 257
        })
        #expect(sends == 1)
        let result = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-direct" && result["surfaceID"] as? Int == 257)
        #expect(result["contactSlots"] as? Int == 5 && result["frameCount"] as? Int == 4)
        #expect(result["releaseVerified"] as? Bool == false && result["verified"] as? Bool == false)
    }

    @Test func malformedInputChangingDisplayAndReadinessPreventDispatchWithoutReplay() throws {
        let input = try CoreDeviceInputTests().input(["gesture", NativeGestureSequenceTests().doubleTap])
        let invalid = CoreDeviceInput(device: "fixture", operation: "gesture", operands: ["{}"])
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalGesture.execute(invalid, query: { _ in Issue.record("Invalid sequence queried"); return Data() }, send: { _ in Issue.record("Invalid sequence sent"); return 0 })
        }
        var reads = 0, sends = 0
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalGesture.execute(input, query: { plan in
                reads += 1
                return try plan.arguments.contains("details") ? DirectPhysicalInputTests().details() : DirectPhysicalTouchTests().display(rotation: reads == 2 ? "rot0" : "rot90")
            }, send: { _ in sends += 1; return 0 })
        }
        #expect(sends == 0)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalGesture.execute(input, query: { _ in try DirectPhysicalInputTests().details(mode: "disabled") }, send: { _ in sends += 1; return 0 })
        }
        #expect(sends == 0)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalGesture.execute(input, query: { plan in
                try plan.arguments.contains("details") ? DirectPhysicalInputTests().details() : DirectPhysicalTouchTests().display()
            }, send: { _ in sends += 1; throw CommandFailure(description: "fixture failure") })
        }
        #expect(sends == 1)
    }

    @Test func cBoundaryRejectsMalformedCompleteReportsBeforeLoadingFramework() throws {
        let sequence = try NativeGestureSequence(json: NativeGestureSequenceTests().doubleTap)
        let valid = sequence.reports.flatMap { $0 }
        let times = sequence.times.map { UInt64($0) * 1_000_000 }
        var cases: [(Data, [UInt64])] = []
        for offset in [0, 1, 2, 3, 28, 40, 45, 57] {
            var bytes = valid; bytes[offset] ^= 1
            cases.append((Data(bytes), times))
        }
        var moved = valid; moved[58 + 4] ^= 1
        cases.append((Data(moved), times))
        var activeLast = valid; activeLast[3 * 58 + 3] = 0xc0
        cases.append((Data(activeLast), times))
        var repeatedTime = times; repeatedTime[1] = 0
        cases.append((Data(valid), repeatedTime))
        for (data, schedule) in cases {
            var error = [CChar](repeating: 0, count: 512), surface: UInt64 = 999
            let status = schedule.withUnsafeBufferPointer { times in
                data.withUnsafeBytes { bytes in
                    ADCPerformDigitizerReports("invalid", "invalid", times.baseAddress,
                        bytes.bindMemory(to: UInt8.self).baseAddress, times.count, &surface, &error, error.count)
                }
            }
            #expect(status != 0 && surface == 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased().contains("digitizer"))
        }
    }

    @Test func cAcceptsOneToFiveBalancedSlotsBeforeIdentityCheck() throws {
        for count in 1...5 {
            let touches = (0..<count).map { ["id": $0, "x": Double($0) / 5, "y": 0.5] }
            let frames: [[String: Any]] = [["ms": 0, "touches": touches], ["ms": 20, "touches": []]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["frames": frames]), as: UTF8.self)
            let bytes = try NativeGestureSequence(json: json).reports.flatMap { $0 }
            var error = [CChar](repeating: 0, count: 512), surface: UInt64 = 999
            let result = [UInt64(0), 20_000_000].withUnsafeBufferPointer { times in
                bytes.withUnsafeBufferPointer {
                    ADCPerformDigitizerReports("invalid", "invalid", times.baseAddress, $0.baseAddress, 2, &surface, &error, error.count)
                }
            }
            #expect(result != 0 && surface == 0)
            #expect(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("identity"))
        }
    }

    @Test func defaultGestureDryRunNeverQueriesOrPlansHelper() async throws {
        let output = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried"); return Data() })
            .execute(["physical", CoreDeviceInputTests().udid, "gesture", NativeGestureSequenceTests().doubleTap], dryRun: true)
        let result = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-direct" && result["frameCount"] as? Int == 4)
        #expect(result["actionArguments"] == nil && result["executable"] == nil)
    }
}
