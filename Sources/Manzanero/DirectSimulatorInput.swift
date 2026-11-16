import AppleDeviceBridge
import Foundation

/// Simulator touch (one contact, or two for pinch and two-path multi-drag),
/// buttons, named keys and typing in a named keyboard layout.
/// Schedules come from the physical builders (`DirectPhysicalTouch.plan`,
/// `KeyboardLayout.samples`) and run through the bridge's shared
/// schedulers; only the connection (host XPC to the simulator's dtuhidd)
/// differs. Receipts keep the physical shape with backend `coresimulator-dtuhid`.
enum DirectSimulatorInput {
    static let backend = "coresimulator-dtuhid"

    /// Touch samples in the digitizer's normalized portrait-native space: the
    /// requested current-interface coordinates rotated with the physical
    /// `DirectTouchDisplay.portrait` (measured: the simulator's digitizer is
    /// portrait-native in landscape, as a phone's is).
    static func touchSamples(_ input: SimulatorInput, display: DirectTouchDisplay) throws -> [DirectPhysicalTouch.Sample] {
        try DirectPhysicalTouch.plan(input.coreDeviceInput, display: display)
    }

    /// Reads the display twice around planning, as the physical touch and
    /// gesture paths do; a change in between refuses the input.
    static func planned<Plan>(_ input: SimulatorInput, environment: SimulatorEnvironment,
                              _ plan: (DirectTouchDisplay) throws -> Plan) throws -> (SimulatorDisplay, DirectTouchDisplay, Plan) {
        let display = try SimulatorDisplay.read(input.device, environment: environment)
        let touch = try display.touch()
        let result = try plan(touch)
        let again = try SimulatorDisplay.read(input.device, environment: environment)
        guard again == display, try again.touch() == touch else {
            throw CommandFailure(.preconditionChanged, "Simulator display changed before touch dispatch; no input sent.", inputSent: .none)
        }
        return (display, touch, result)
    }

    static func execute(_ input: SimulatorInput, info: SimulatorDeviceInfo, environment: SimulatorEnvironment) throws -> Data {
        try Task.checkCancellation()
        try AppleTVRemote.checkFamily(input, info: info)
        try DigitalCrown.checkFamily(input, info: info)
        var result: [String: Any] = ["backend": backend, "operation": input.operation, "status": "dispatched",
            "verified": false, "releaseVerified": false, "platform": "simulator", "device": input.device,
            "resolvedSimulatorUUID": info.uuid, "screen": info.screenJSON]
        switch input.operation {
        case _ where input.usesUniversalHID:
            // The physical gesture path: display read twice around planning,
            // the same complete-state frames, then the Universal HID service.
            _ = try DirectPhysicalGesture.sequence(for: input.coreDeviceInput)
            let (display, touch, sequence) = try planned(input, environment: environment) {
                try DirectPhysicalGesture.sequence(for: input.coreDeviceInput, transform: $0.portrait)
            }
            result["screen"] = display.screenJSON(info)
            try Task.checkCancellation()
            let surface = try environment.digitizerReports(input.device, display.primaryUUID,
                                                           sequence.times.map { UInt64($0) * 1_000_000 }, sequence.reports.flatMap { $0 })
            result["surfaceID"] = surface
            result["frameCount"] = sequence.times.count
            result["contactSlots"] = sequence.contactCount
            result["durationMilliseconds"] = sequence.times.last ?? 0
            result["coordinateSpace"] = "normalized-current-interface"
            result["displayRotationDegrees"] = touch.rotation
        case let operation where SimulatorInput.touchOperations.contains(operation):
            let (display, touch, samples) = try planned(input, environment: environment) { try touchSamples(input, display: $0) }
            result["screen"] = display.screenJSON(info)
            result["displayRotationDegrees"] = touch.rotation
            let wire = samples.map { ADCTouchSample(nanoseconds: $0.nanoseconds, x: $0.x, y: $0.y, phase: $0.phase) }
            let second = samples.compactMap(\.second).map { ADCTouchPoint(x: $0.x, y: $0.y) }
            try Task.checkCancellation()
            if second.isEmpty {
                try environment.touch(input.device, wire)
            } else {
                // pinch and two-path multi-drag: pointOne and pointTwo of one
                // Indigo digitizer schedule, as on a physical device.
                guard second.count == wire.count else {
                    throw CommandFailure(.internal, "Incomplete second-contact schedule; no input sent.", inputSent: .none)
                }
                try environment.twoContactTouch(input.device, wire, second)
            }
            result["sampleCount"] = samples.count
            result["contactCount"] = second.isEmpty ? 1 : 2
            result["coordinateSpace"] = "normalized-current-interface"
            if operation == "long-press" { result["holdSeconds"] = Double(input.operands[2]) }
        case "button" where DigitalCrown.watchButtons[input.operands.first ?? ""] != nil:
            let name = input.operands[0]
            try Task.checkCancellation()
            try environment.remoteButton(input.device, DigitalCrown.watchButtons[name]!, 80_000)
            result["button"] = name
        case "button":
            guard let name = input.operands.first, let usage = SimulatorInput.buttons[name] else {
                throw CommandFailure.usage("Supported simulator buttons: home, lock, volume-up, volume-down; no input sent.")
            }
            try Task.checkCancellation()
            // The physical holds: 0.4 s for the side button, 80 ms otherwise.
            try environment.button(input.device, usage, name == "lock" ? 400_000 : 80_000)
            result["button"] = name
        case "key":
            guard input.operands.count == 1, let name = input.operands.first, let usage = DirectPhysicalKeyboard.usages[name] else {
                throw CommandFailure.usage("Unsupported simulator keyboard key; no input sent.")
            }
            try Task.checkCancellation()
            try environment.key(input.device, usage)
            result["key"] = name
            result["usage"] = usage
        case "remote":
            guard input.operands.count == 1, let name = input.operands.first, let route = AppleTVRemote.routes[name] else {
                throw CommandFailure.usage(AppleTVRemote.usage)
            }
            try Task.checkCancellation()
            switch route {
            case .key(let usage): try environment.key(input.device, usage)
            case .button(let usage): try environment.remoteButton(input.device, usage, AppleTVRemote.holdMicroseconds)
            }
            result["remote"] = name
            result["route"] = AppleTVRemote.describe(route)
        case "crown":
            guard input.operands.count == 2, let units = Int(input.operands[0]), DigitalCrown.range.contains(abs(units)) else {
                throw CommandFailure.usage(DigitalCrown.usage)
            }
            let events = try DigitalCrown.events(input.operands[1], units: units)
            try Task.checkCancellation()
            try environment.crown(input.device, DigitalCrown.steps(units, events: events), DigitalCrown.intervalMilliseconds * 1_000_000)
            result["crown"] = DigitalCrown.describe(units, events: events)
        case "type":
            let (text, layout) = try DirectPhysicalTyping.request(input.operands, subject: "Simulator")
            let schedule = try layout.samples(text)
            // The simulator's own layout setting, read before anything is
            // sent; an explicit different layout refuses the input.
            let preferences = Result { try environment.keyboardPreferences(input.device) }
            let deviceLayout = try DeviceKeyboardLayout.simulator(preferences, layout: layout, sources: KeyboardLayout.available())
            try Task.checkCancellation()
            try environment.keyboard(input.device, schedule)
            result["insertionVerified"] = false
            result["deviceLayout"] = deviceLayout
            result.merge(DirectPhysicalTyping.fields(text, layout: layout, samples: schedule)) { _, new in new }
        default:
            throw CommandFailure.unsupported("Unsupported simulator input operation: \(input.operation); no input sent.")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Bridge dispatch

    static func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Opens the simulator, runs one bridge input call and classifies its
    /// status like the physical dispatchers.
    static func dispatch(_ uuid: String, _ body: (UnsafeMutableRawPointer, inout [CChar]) -> Int32) throws {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: SimulatorDevice.developerDirectory(), accessibility: false)
        var error = [CChar](repeating: 0, count: 1024)
        let status = body(owner.pointer, &error)
        try Task.checkCancellation()
        guard status == 0 else { throw CommandFailure.inputDispatch(status: status, message: message(error)) }
    }

    static func touch(_ uuid: String, _ samples: [ADCTouchSample]) throws {
        try dispatch(uuid) { owner, error in
            samples.withUnsafeBufferPointer { ADCSimulatorPerformTouch(owner, $0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
        }
    }

    static func digitizerReports(_ uuid: String, _ display: String, _ times: [UInt64], _ reports: [UInt8]) throws -> UInt64 {
        var surface: UInt64 = 0
        try dispatch(uuid) { owner, error in
            times.withUnsafeBufferPointer { times in
                reports.withUnsafeBufferPointer { reports in
                    ADCSimulatorPerformDigitizerReports(owner, display, times.baseAddress, reports.baseAddress, times.count,
                                                        { Task.isCancelled ? 1 : 0 }, &surface, &error, error.count)
                }
            }
        }
        return surface
    }

    static func displayInfo(_ uuid: String) throws -> Data {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: SimulatorDevice.developerDirectory(), accessibility: false)
        var error = [CChar](repeating: 0, count: 1024)
        var data = Data()
        let status = ADCSimulatorDisplayInfo(owner.pointer, { pointer, count in
            if let pointer { data = Data(bytes: pointer, count: count) }
        }, &error, error.count)
        guard status == 0 else { throw CommandFailure(.transportFailed, message(error), inputSent: .none) }
        return data
    }

    static func twoContactTouch(_ uuid: String, _ samples: [ADCTouchSample], _ second: [ADCTouchPoint]) throws {
        try dispatch(uuid) { owner, error in
            samples.withUnsafeBufferPointer { first in
                second.withUnsafeBufferPointer {
                    ADCSimulatorPerformTwoContactTouch(owner, first.baseAddress, $0.baseAddress, first.count, { Task.isCancelled ? 1 : 0 }, &error, error.count)
                }
            }
        }
    }

    static func keyboard(_ uuid: String, _ samples: [ADCKeyboardSample]) throws {
        try dispatch(uuid) { owner, error in
            samples.withUnsafeBufferPointer { ADCSimulatorPerformKeyboard(owner, $0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
        }
    }

    static func key(_ uuid: String, _ usage: UInt64) throws {
        try dispatch(uuid) { owner, error in ADCSimulatorPressKeyboardKey(owner, usage, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
    }

    static func button(_ uuid: String, _ usage: UInt64, _ hold: UInt32) throws {
        try dispatch(uuid) { owner, error in ADCSimulatorPressButton(owner, usage, hold, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
    }

    static func remoteButton(_ uuid: String, _ usage: UInt64, _ hold: UInt32) throws {
        try dispatch(uuid) { owner, error in ADCSimulatorPressRemoteButton(owner, usage, hold, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
    }
}
