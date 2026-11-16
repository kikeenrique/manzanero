import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

/// Simulator touch, buttons, keys and typing against injected bridge calls.
struct SimulatorInputTests {
    static let uuid = SimulatorDeviceTests.uuid

    final class Sent: @unchecked Sendable {
        var touches: [[ADCTouchSample]] = []
        var twoContacts: [(first: [ADCTouchSample], second: [ADCTouchPoint])] = []
        var reports: [(display: String, times: [UInt64], bytes: [UInt8])] = []
        /// Display information answers, in order; the last one repeats.
        var displays: [Data] = [SimulatorInputTests.displayJSON()]
        var displayReads = 0
        var keyboards: [[ADCKeyboardSample]] = []
        var keys: [UInt64] = []
        var buttons: [(usage: UInt64, hold: UInt32)] = []
        var lookups = 0
        var failure: CommandFailure?
        var onSend: (() -> Void)?
    }

    static func environment(_ sent: Sent, state: String = "Booted") -> SimulatorEnvironment {
        var environment = SimulatorEnvironment(
            lookup: { _ in sent.lookups += 1; return SimulatorDeviceTests.info(state) },
            accessibility: { _, _ in Issue.record("Input opened accessibility"); return SimulatorAXFixture().session() })
        environment.touch = { device, samples in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.touches.append(samples)
        }
        environment.twoContactTouch = { device, samples, second in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.twoContacts.append((samples, second))
        }
        environment.displayInfo = { device in
            #expect(device == uuid)
            defer { sent.displayReads += 1 }
            return sent.displays[min(sent.displayReads, sent.displays.count - 1)]
        }
        environment.digitizerReports = { device, display, times, bytes in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.reports.append((display, times, bytes))
            return 257
        }
        environment.keyboard = { device, samples in
            #expect(device == uuid)
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.keyboards.append(samples)
        }
        environment.key = { _, usage in
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.keys.append(usage)
        }
        environment.button = { _, usage, hold in
            sent.onSend?()
            if let failure = sent.failure { throw failure }
            sent.buttons.append((usage, hold))
        }
        return environment
    }

    static func service(_ sent: Sent, state: String = "Booted", leases: DeviceLeaseRegistry = SimulatorAccessibilityTests.usableLeases()) -> CommandService {
        CommandService(leases: leases, simulator: environment(sent, state: state),
                       readinessQuery: { _ in Issue.record("Simulator input queried CoreDevice"); return Data() })
    }

    static func json(_ output: CommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    static let primaryDisplay = "5FCAD30D-AEFC-49D9-B285-7936739F1B63"

    /// The bridge's display information in devicectl's shape, as captured from
    /// an iPhone 17e simulator (trimmed): the primary display plus a second,
    /// non-primary one, as the simulator reports.
    static func displayJSON(current: String = "rot0", native: String = "rot0", backlight: String = "activeOn",
                            sensor: String = "portrait", uniqueId: String? = primaryDisplay,
                            width: Double = 1170, height: Double = 2532) -> Data {
        var primary: [String: Any] = ["primary": true, "type": ["integrated": [String: Any]()], "backlightState": backlight,
            "displayId": 1, "bounds": [[0, 0], [width, height]], "nativeOrientation": native, "currentOrientation": current,
            "pointScale": 3, "name": "LCD"]
        if let uniqueId { primary["uniqueId"] = uniqueId }
        let resizable: [String: Any] = ["primary": false, "type": ["integrated": [String: Any]()], "backlightState": "activeOn",
            "displayId": 4, "bounds": [[0, 0], [1170, 2532]], "nativeOrientation": "rot0", "currentOrientation": "rot0",
            "pointScale": 3, "name": "Resizable", "uniqueId": "C0027839-ABAD-41AE-9F76-43C1CE5A085C"]
        let root: [String: Any] = ["info": ["outcome": "success"], "result": ["displays": [primary, resizable],
            "orientation": ["currentDeviceNonFlatOrientation": sensor, "currentDeviceOrientationLocked": false]]]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Positions of the active contacts of one 58-byte report, normalized.
    static func contacts(_ report: ArraySlice<UInt8>) -> [Int: (Double, Double)] {
        let bytes = Array(report)
        var result: [Int: (Double, Double)] = [:]
        for id in 0..<Int(bytes[1]) where bytes[3 + id * 5] & 0xc0 != 0 {
            let x = Int(bytes[4 + id * 5]) | Int(bytes[5 + id * 5]) << 8, y = Int(bytes[6 + id * 5]) | Int(bytes[7 + id * 5]) << 8
            result[id] = (Double(x) / 65535, Double(y) / 65535)
        }
        return result
    }

    // MARK: - Parsing

    @Test func touchOperandsAreValidatedLikePhysical() throws {
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.25"])?.operands == ["0.5", "0.25"])
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "long-press", "0.5", "0.5", "1"])?.operands == ["0.5", "0.5", "1.0"])
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "swipe", "0.5", "0.8", "0.5", "0.2", "0.6"]) != nil)
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "drag", "0", "0", "1", "1", "10"]) != nil)
        let invalid: [([String], String)] = [
            (["tap", "2", "0.5"], "Simulator input coordinates must be normalized numbers from 0 to 1."),
            (["tap", "0.5"], "tap expects 2 operands. See --help."),
            (["swipe", "0.5", "0.8", "0.5", "0.2", "0.01"], "Simulator drag/swipe duration must be 0.03...10 seconds."),
            (["long-press", "0.5", "0.5", "0.05"], "Simulator long-press requires normalized x/y in 0...1 and duration 0.1...10 seconds."),
            (["tap", "nan", "0"], "Simulator input coordinates must be normalized numbers from 0 to 1.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
        // The physical wording is unchanged by the shared validator.
        let physical = try #require(throws: CommandFailure.self) { try PhysicalInputOperands.validate("tap", ["2", "0.5"]) }
        #expect(physical.description == "Physical input coordinates must be normalized numbers from 0 to 1.")
    }

    @Test func simulatorInputRunsUnderTheSignalScope() {
        #expect(CLIInputSignals.applies(to: ["simulator", Self.uuid, "tap", "0.5", "0.5"], dryRun: false))
        #expect(CLIInputSignals.context(for: ["simulator", Self.uuid, "tap", "0.5", "0.5"]) == "simulator input")
        #expect(CLIInputSignals.context(for: ["physical", "00008110-000A1B2C3D4E5F60", "tap", "0.5", "0.5"]) == "physical input")
        #expect(!CLIInputSignals.applies(to: ["simulator", Self.uuid, "tap", "0.5", "0.5"], dryRun: true))
        #expect(!CLIInputSignals.applies(to: ["simulator", Self.uuid, "apps"], dryRun: false))
        #expect(!CLIInputSignals.applies(to: ["simulator", "booted", "tap", "0.5", "0.5"], dryRun: false))
    }

    // MARK: - Geometry and schedules

    static func touch(_ current: String = "rot0") throws -> DirectTouchDisplay {
        try SimulatorDisplay(displayJSON(current: current)).touch()
    }

    @Test func portraitCoordinatesReachTheDigitizerUnchanged() throws {
        let tap = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.711"])), display: Self.touch())
        #expect(tap.first?.x == 0.5 && tap.first?.y == 0.711 && tap.first?.phase == 0 && tap.last?.phase == 2)
        #expect(tap.last?.nanoseconds == 80_000_000 && tap.allSatisfy { $0.second == nil })
        // Another screen size changes nothing: the space is the interface's 0...1.
        let large = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.5", "0.711"])),
                                                          display: SimulatorDisplay(Self.displayJSON(width: 1488, height: 2266)).touch())
        #expect(large == tap)
        let swipe = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "swipe", "0.2", "0.8", "0.8", "0.2", "0.5"])), display: Self.touch())
        #expect(swipe.count == 32 && swipe.first?.x == 0.2 && swipe.last?.x == 0.8 && swipe.last?.y == 0.2)
        #expect(swipe.last?.nanoseconds == 501_000_000)
        let hold = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "long-press", "0.4", "0.55", "0.8"])), display: Self.touch())
        #expect(hold.last?.nanoseconds == 800_000_000 && Set(hold.map(\.x)) == [0.4])
    }

    /// The measured mapping: an interface point (0.2, 0.3) lands where the
    /// digitizer's portrait-native coordinates are DirectTouchDisplay.portrait's.
    @Test(arguments: [("rot0", 0.2, 0.3), ("rot90", 0.3, 0.8), ("rot180", 0.8, 0.7), ("rot270", 0.7, 0.2)])
    func interfaceCoordinatesAreRotatedIntoTheNativeDigitizer(_ current: String, _ x: Double, _ y: Double) throws {
        let tap = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "tap", "0.2", "0.3"])), display: Self.touch(current))
        #expect(abs(tap[0].x - x) < 1e-9 && abs(tap[0].y - y) < 1e-9)
        let pinch = try DirectSimulatorInput.touchSamples(#require(try SimulatorInput.parse(["simulator", Self.uuid, "pinch", "0.5", "0.4", "0.2", "0.5", "0.4"])), display: Self.touch(current))
        let expected = DirectTouchDisplay(rotation: Int(current.dropFirst(3))!).portrait(0.4, 0.4)
        #expect(abs(pinch[0].x - expected.0) < 1e-9 && abs(pinch[0].y - expected.1) < 1e-9)
    }

    @Test(arguments: ["rot90", "rot270"])
    func landscapeTouchReportsTheRotationAndInterface(_ current: String) async throws {
        let sent = Sent()
        sent.displays = [Self.displayJSON(current: current, sensor: current == "rot90" ? "landscapeRight" : "landscapeLeft")]
        let receipt = try Self.json(await Self.service(sent).execute(["simulator", Self.uuid, "tap", "0.2", "0.3"]))
        #expect(receipt["displayRotationDegrees"] as? Int == Int(current.dropFirst(3)) && sent.displayReads == 2)
        let screen = try #require(receipt["screen"] as? [String: Any])
        #expect(screen["orientation"] as? String == current && screen["interfaceWidthPoints"] as? Double == 844)
        #expect(screen["interfaceHeightPoints"] as? Double == 390 && screen["widthPoints"] as? Double == 390)
        let first = try #require(sent.touches.first?.first)
        #expect(abs(first.x - (current == "rot90" ? 0.3 : 0.7)) < 1e-9)
    }

    @Test func aRotationBetweenTheReadsRefusesTouch() async throws {
        let sent = Sent()
        sent.displays = [Self.displayJSON(), Self.displayJSON(current: "rot90", sensor: "landscapeRight")]
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent).execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
        })
        #expect(failure.code == .preconditionChanged && failure.inputSent == .none && sent.touches.isEmpty)
        let dark = Sent()
        dark.displays = [Self.displayJSON(backlight: "off")]
        let off = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(dark).execute(["simulator", Self.uuid, "swipe", "0.5", "0.9", "0.5", "0.4", "0.3"])
        })
        #expect(off.code == .displayOff && off.inputSent == .none && dark.touches.isEmpty)
    }

    // MARK: - Execution

    @Test(arguments: [["tap", "0.5", "0.45"], ["long-press", "0.4", "0.55", "0.8"], ["swipe", "0.5", "0.65", "0.5", "0.35", "0.5"], ["drag", "0.3", "0.55", "0.7", "0.55", "0.8"]])
    func touchDispatchesOneScheduleUnderTheLease(_ operands: [String]) async throws {
        let sent = Sent()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var holder = ""
        sent.onSend = { holder = SimulatorAccessibilityTests.leaseHolder(directory) }
        let receipt = try Self.json(await Self.service(sent, leases: SimulatorAccessibilityTests.usableLeases(directory))
            .execute(["simulator", Self.uuid] + operands))
        #expect(sent.touches.count == 1 && sent.lookups == 1)
        #expect(holder.contains(operands[0]))
        #expect(receipt["backend"] as? String == "coresimulator-dtuhid" && receipt["operation"] as? String == operands[0])
        #expect(receipt["status"] as? String == "dispatched" && receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
        #expect(receipt["platform"] as? String == "simulator" && receipt["contactCount"] as? Int == 1)
        #expect(receipt["sampleCount"] as? Int == sent.touches[0].count)
        #expect(receipt["coordinateSpace"] as? String == "normalized-current-interface")
        #expect((receipt["screen"] as? [String: Any])?["orientation"] as? String == "rot0")
        #expect(receipt["displayRotationDegrees"] as? Int == 0 && sent.displayReads == 2)
        #expect((receipt["holdSeconds"] as? Double) == (operands[0] == "long-press" ? 0.8 : nil))
        #expect(sent.touches[0].first?.phase == 0 && sent.touches[0].last?.phase == 2)
    }

    // MARK: - Two contacts

    @Test func pinchAndTwoPathMultiDragAreValidatedLikePhysical() throws {
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "pinch", "0.5", "0.5", "0.2", "0.5", "0.6"])?.operation == "pinch")
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]) != nil)
        let invalid: [([String], CommandFailure.Code, String)] = [
            (["pinch", "0.5", "0.5", "0.2", "0.2", "0.6"], .usage, "Pinch requires different positive start/end spans and 0.03...10 seconds. Spans are fractions of screen width."),
            (["pinch", "0.5", "0.5", "0.2", "1.5", "0.6"], .usage, "Simulator input coordinates must be normalized numbers from 0 to 1."),
            // Crossing paths are refused at parse time, before any lookup.
            (["multi-drag", "0.6", "0.3", "0.6", "0.7", "0.6", "0.7", "0.6", "0.3", "0.6"], .usage, "Two-contact paths overlap or cross; no input sent."),
            (["multi-drag", "20", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4"], .usage, "Usage: multi-drag <seconds: 0.03...10> <start-x> <start-y> <end-x> <end-y> ... (two to five contact paths)")
        ]
        for (operands, code, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == code && failure.inputSent == .none)
        }
    }

    @Test(arguments: [["pinch", "0.5", "0.5", "0.2", "0.5", "0.6"], ["multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"]])
    func twoContactsTravelInOneDigitizerSchedule(_ operands: [String]) async throws {
        let sent = Sent()
        let receipt = try Self.json(await Self.service(sent).execute(["simulator", Self.uuid] + operands))
        #expect(sent.touches.isEmpty && sent.twoContacts.count == 1)
        let (first, second) = try #require(sent.twoContacts.first)
        // The physical paired plan: down, 30 moves, release 1 ms after the duration.
        #expect(first.count == 32 && second.count == 32 && first.first?.phase == 0 && first.last?.phase == 2)
        #expect(first.last?.nanoseconds == (operands[0] == "pinch" ? 601_000_000 : 501_000_000))
        if operands[0] == "pinch" {
            #expect(abs(first[0].x - 0.4) < 1e-9 && abs(second[0].x - 0.6) < 1e-9 && first[0].y == 0.5 && second[0].y == 0.5)
            #expect(abs(first[31].x - 0.25) < 1e-9 && abs(second[31].x - 0.75) < 1e-9)
        } else {
            #expect(first[0].y == 0.25 && second[0].y == 0.75 && first[31].y == 0.1 && second[31].y == 0.9)
        }
        #expect(receipt["contactCount"] as? Int == 2 && receipt["sampleCount"] as? Int == 32)
        #expect(receipt["backend"] as? String == "coresimulator-dtuhid" && receipt["operation"] as? String == operands[0])
        #expect(receipt["status"] as? String == "dispatched" && receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
    }

    @Test func twoContactDryRunNamesBothContacts() async throws {
        let sent = Sent()
        let plan = try Self.json(await Self.service(sent, state: "Shutdown").execute(["simulator", Self.uuid, "pinch", "0.5", "0.5", "0.5", "0.2", "0.4"], dryRun: true))
        #expect(plan["contactCount"] as? Int == 2 && plan["sampleCount"] as? Int == 32)
        #expect((plan["execution"] as? String)?.contains("pointTwo") == true)
        #expect(sent.lookups == 0 && sent.twoContacts.isEmpty)
    }

    // MARK: - Three to five contacts (Universal HID)

    @Test func universalHIDOperationsAreValidatedLikePhysical() throws {
        for args in [["multi-tap", "0.3", "0.45", "0.5", "0.45", "0.7", "0.45"], ["multi-tap", "0.25", "0.5", "0.75", "0.5"],
                     ["multi-drag", "0.6", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4", "0.7", "0.6", "0.7", "0.4"],
                     ["gesture", #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]}]}"#]] {
            let parsed = try #require(try SimulatorInput.parse(["simulator", Self.uuid] + args))
            #expect(parsed.usesUniversalHID && SimulatorInput.inputOperations.contains(parsed.operation))
        }
        // A two-path multi-drag stays on the Indigo digitizer, as on a phone.
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "multi-drag", "0.5", "0.5", "0.25", "0.5", "0.1", "0.5", "0.75", "0.5", "0.9"])?.usesUniversalHID == false)
        let invalid: [([String], String)] = [
            (["multi-tap", "0.25", "0.5"], "multi-tap expects two to five pairs of normalized coordinates."),
            (["multi-tap", "2", "0.5", "0.5", "0.5"], "Simulator input coordinates must be normalized numbers from 0 to 1."),
            (["gesture"], "Simulator gesture requires one JSON sequence argument."),
            (["gesture", #"{"frames":[{"ms":0,"touches":[{"id":1,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]}]}"#], "Gesture contact IDs must form a contiguous set starting at zero across the sequence.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
    }

    @Test func multiTapSendsThePhysicalReportsToThePrimaryTouchscreen() async throws {
        let sent = Sent()
        let receipt = try Self.json(await Self.service(sent).execute(["simulator", Self.uuid, "multi-tap", "0.3", "0.45", "0.5", "0.45", "0.7", "0.45"]))
        let report = try #require(sent.reports.first)
        #expect(sent.reports.count == 1 && report.display == Self.primaryDisplay && sent.displayReads == 2)
        // The physical multi-tap: all down at 0, all up at 80 ms; the same bytes.
        let expected = try DirectPhysicalGesture.sequence(for: CoreDeviceInput(device: Self.uuid, operation: "multi-tap",
                                                                                operands: ["0.3", "0.45", "0.5", "0.45", "0.7", "0.45"]))
        #expect(report.times == [0, 80_000_000] && report.bytes == expected.reports.flatMap { $0 })
        let down = Self.contacts(report.bytes[0..<58])
        #expect(down.count == 3 && abs(down[2]!.0 - 0.7) < 0.0001 && abs(down[0]!.1 - 0.45) < 0.0001)
        #expect(Self.contacts(report.bytes[58..<116]).isEmpty)
        #expect(receipt["surfaceID"] as? Int == 257 && receipt["contactSlots"] as? Int == 3 && receipt["frameCount"] as? Int == 2)
        #expect(receipt["durationMilliseconds"] as? Int == 80 && receipt["displayRotationDegrees"] as? Int == 0)
        #expect(receipt["backend"] as? String == "coresimulator-dtuhid" && receipt["status"] as? String == "dispatched")
        #expect(receipt["verified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
        #expect(receipt["coordinateSpace"] as? String == "normalized-current-interface")
    }

    @Test func gestureAndThreePathDragUseTheSameFrames() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let json = #"{"frames":[{"ms":0,"touches":[{"id":0,"x":0.35,"y":0.5}]},{"ms":150,"touches":[{"id":0,"x":0.35,"y":0.5},{"id":1,"x":0.65,"y":0.5}]},{"ms":450,"touches":[{"id":1,"x":0.65,"y":0.5}]},{"ms":600,"touches":[]}]}"#
        _ = try await service.execute(["simulator", Self.uuid, "gesture", json])
        #expect(sent.reports.first?.times == [0, 150, 450, 600].map { UInt64($0) * 1_000_000 })
        #expect(sent.reports.first?.bytes == (try NativeGestureSequence(json: json).reports.flatMap { $0 }))
        let drag = try Self.json(await service.execute(["simulator", Self.uuid, "multi-drag", "0.6", "0.3", "0.6", "0.3", "0.4", "0.5", "0.6", "0.5", "0.4", "0.7", "0.6", "0.7", "0.4"]))
        #expect(sent.reports.count == 2 && sent.reports[1].times.count == 32 && sent.reports[1].times.last == 601_000_000)
        #expect(drag["contactSlots"] as? Int == 3 && drag["frameCount"] as? Int == 32)
    }

    @Test func aChangedOffOrUnidentifiedDisplaySendsNothing() async throws {
        let changed = Sent()
        changed.displays = [Self.displayJSON(), Self.displayJSON(current: "rot90", sensor: "landscapeRight")]
        let moved = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(changed).execute(["simulator", Self.uuid, "multi-tap", "0.3", "0.45", "0.7", "0.45"])
        })
        #expect(moved.code == .preconditionChanged && moved.inputSent == .none && changed.reports.isEmpty)
        let off = Sent()
        off.displays = [Self.displayJSON(backlight: "off")]
        let dark = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(off).execute(["simulator", Self.uuid, "multi-tap", "0.3", "0.45", "0.7", "0.45"])
        })
        #expect(dark.code == .displayOff && dark.inputSent == .none && dark.description.contains("button home") && off.reports.isEmpty)
        let anonymous = Sent()
        anonymous.displays = [Self.displayJSON(uniqueId: nil)]
        let unnamed = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(anonymous).execute(["simulator", Self.uuid, "multi-tap", "0.3", "0.45", "0.7", "0.45"])
        })
        #expect(unnamed.code == .transportFailed && unnamed.inputSent == .none && anonymous.reports.isEmpty)
    }

    @Test func universalHIDDryRunReadsNothing() async throws {
        let sent = Sent()
        let plan = try Self.json(await Self.service(sent, state: "Shutdown").execute(["simulator", Self.uuid, "multi-tap", "0.3", "0.45", "0.5", "0.45", "0.7", "0.45", "0.4", "0.6", "0.6", "0.6"], dryRun: true))
        #expect(plan["contactSlots"] as? Int == 5 && plan["frameCount"] as? Int == 2 && plan["durationMilliseconds"] as? Int == 80)
        #expect((plan["execution"] as? String)?.contains("universalhidservice") == true)
        #expect(sent.lookups == 0 && sent.displayReads == 0 && sent.reports.isEmpty)
    }

    @Test func unbootedSimulatorSendsNothingAndTakesNoLease() async throws {
        let sent = Sent()
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent, state: "Shutdown", leases: try SimulatorAccessibilityTests.unusableLeases())
                .execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
        })
        // The lookup refusal comes before the (unusable) lease.
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none && sent.touches.isEmpty)
    }

    @Test func busySimulatorIsRefusedBeforeInput() async throws {
        let sent = Sent()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = open(directory.appendingPathComponent("\(Self.uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
        defer { _ = close(owner) }
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent, leases: DeviceLeaseRegistry(directory: directory)).execute(["simulator", Self.uuid, "drag", "0.3", "0.5", "0.7", "0.5", "0.4"])
        })
        #expect(failure.code == .deviceBusy && failure.inputSent == .none && failure.action == .wait && sent.touches.isEmpty)
    }

    @Test func bridgeStatusesKeepThePhysicalClassification() async throws {
        for (status, code, inputSent) in [(ADCInputOutcomeUnknown, CommandFailure.Code.inputOutcomeUnknown, CommandFailure.InputSent.possible),
                                          (1, .transportFailed, .none)] {
            let sent = Sent()
            sent.failure = CommandFailure.inputDispatch(status: status, message: "fixture")
            let failure = try #require(await #expect(throws: CommandFailure.self) {
                _ = try await Self.service(sent).execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
            })
            #expect(failure.code == code && failure.inputSent == inputSent)
        }
    }

    @Test func touchDryRunPlansWithoutLookingTheSimulatorUp() async throws {
        let sent = Sent()
        let plan = try Self.json(await Self.service(sent, state: "Shutdown").execute(["simulator", Self.uuid, "swipe", "0.5", "0.8", "0.5", "0.2", "0.6"], dryRun: true))
        #expect(plan["backend"] as? String == "coresimulator-dtuhid" && plan["operation"] as? String == "swipe")
        #expect(plan["operands"] as? [String] == ["0.5", "0.8", "0.5", "0.2", "0.6"] && plan["sampleCount"] as? Int == 32)
        #expect(plan["deviceLease"] as? String == "simulator UUID" && plan["liveVerified"] as? Bool == false)
        #expect((plan["execution"] as? String)?.contains("dtuhidd") == true)
        #expect(sent.lookups == 0 && sent.touches.isEmpty)
    }

    // MARK: - Buttons, keys and typing

    @Test func buttonsKeysAndTypingAreValidatedForTheSimulator() throws {
        for args in [["button", "home"], ["button", "lock"], ["key", "backspace"], ["key", "return"], ["type", "Wi-Fi 5\tok\n"]] {
            #expect(try SimulatorInput.parse(["simulator", Self.uuid] + args)?.operation == args[0])
        }
        let invalid: [([String], String)] = [
            (["button", "volume-up"], "Supported simulator buttons: home, lock. Volume buttons are untested on the simulator and refused; no input sent."),
            (["button"], "Supported simulator buttons: home, lock. Volume buttons are untested on the simulator and refused; no input sent."),
            (["key", "f1"], "Unknown simulator keyboard key. See --help."),
            (["type", "mañana"], "Simulator typing requires 1...512 printable US-layout ASCII characters, tab or LF newline; it types at the focused caret. For other Unicode text use set-value-id or set-value-label, which replace a named element's whole value. No input sent."),
            (["type", String(repeating: "a", count: 513)], "Simulator typing requires 1...512 printable US-layout ASCII characters, tab or LF newline; it types at the focused caret. For other Unicode text use set-value-id or set-value-label, which replace a named element's whole value. No input sent."),
            (["type", "a", "b"], "Simulator typing expects one text operand.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
    }

    @Test func buttonsUseThePhysicalUsagesAndHolds() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let home = try Self.json(await service.execute(["simulator", Self.uuid, "button", "home"]))
        _ = try await service.execute(["simulator", Self.uuid, "button", "lock"])
        #expect(sent.buttons.map(\.usage) == [64, 48] && sent.buttons.map(\.hold) == [80_000, 400_000])
        #expect(home["backend"] as? String == "coresimulator-dtuhid" && home["button"] as? String == "home")
        #expect(home["status"] as? String == "dispatched" && home["verified"] as? Bool == false && home["releaseVerified"] as? Bool == false)
    }

    @Test func keysAndTypingUseThePhysicalTable() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let key = try Self.json(await service.execute(["simulator", Self.uuid, "key", "backspace"]))
        #expect(sent.keys == [42] && key["key"] as? String == "backspace" && key["usage"] as? Int == 42)
        let typed = try Self.json(await service.execute(["simulator", Self.uuid, "type", "Wi"]))
        let schedule = try #require(sent.keyboards.first)
        // Shift down, W down/up, shift up, i down/up: the physical US-layout table.
        #expect(schedule.map(\.usage) == [225, 26, 26, 225, 12, 12] && schedule.map(\.state) == [1, 1, 2, 2, 1, 2])
        #expect(schedule.map(\.nanoseconds) == (0..<6).map { UInt64($0) * 10_000_000 })
        #expect(typed["insertionVerified"] as? Bool == false && typed["layout"] as? String == "US")
        #expect(typed["characterCount"] as? Int == 2 && typed["sampleCount"] as? Int == 6)
    }

    @Test func buttonKeyAndTypeDryRunsNameTheirService() async throws {
        let sent = Sent()
        let service = Self.service(sent, state: "Shutdown")
        let button = try Self.json(await service.execute(["simulator", Self.uuid, "button", "lock"], dryRun: true))
        #expect(button["usage"] as? Int == 48 && button["holdMilliseconds"] as? Int == 400)
        #expect((button["execution"] as? String)?.contains("remote.hid.button") == true)
        let type = try Self.json(await service.execute(["simulator", Self.uuid, "type", "hello"], dryRun: true))
        #expect(type["sampleCount"] as? Int == 10 && type["layout"] as? String == "US")
        #expect((type["execution"] as? String)?.contains("remote.hid.keyboard") == true)
        let key = try Self.json(await service.execute(["simulator", Self.uuid, "key", "return"], dryRun: true))
        #expect(key["usage"] as? Int == 40 && key["backend"] as? String == "coresimulator-dtuhid")
        #expect(sent.lookups == 0 && sent.keys.isEmpty && sent.buttons.isEmpty && sent.keyboards.isEmpty)
    }

    @Test func interruptedTypingIsAnUnknownOutcome() async throws {
        let sent = Sent()
        sent.failure = CommandFailure.inputDispatch(status: ADCInputOutcomeUnknown, message: "Input stopped after cancellation or transport failure")
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(sent).execute(["simulator", Self.uuid, "type", "hello"])
        })
        #expect(failure.code == .inputOutcomeUnknown && failure.inputSent == .possible && failure.retry == .afterInspection)
    }

    @Test func handoffPausesSimulatorInputButNotObservations() async throws {
        let sent = Sent()
        let service = Self.service(sent)
        let gate = HandoffCommandTests.Gate()
        let pending = Task { try await service.execute(["simulator", Self.uuid, "handoff", "fixture"], handoffConfirmation: { _ in await gate.wait() }) }
        try #require(await gate.entered.wait())
        let paused = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await service.execute(["simulator", Self.uuid, "tap", "0.5", "0.5"])
        })
        #expect(paused.code == .handoffPending && sent.touches.isEmpty && sent.lookups == 0)
        await gate.finish()
        _ = try await pending.value
    }
}
