import AppleDeviceBridge
import CoreFoundation
import Foundation

struct DirectTouchDisplay: Equatable {
    let id: Int
    /// An Apple TV's television: no touch, and a video stream that fits the
    /// display into its own width.
    private(set) var external = false
    let width: Double
    let height: Double
    let scale: Double
    let native: Int
    let rotation: Int

    /// An unrotated portrait screen described by another source, such as
    /// CoreSimulator; `portrait` then leaves coordinates unchanged.
    init(portraitPoints width: Double, height: Double, scale: Double) {
        id = 0; self.width = width; self.height = height; self.scale = scale; native = 0; rotation = 0
    }

    /// The display marked primary, or with `displayId` the integrated display
    /// with that ID (a simulator whose interface is on another display, such
    /// as an unfolded iPhone Duo's LCD-1); the same checks apply to either.
    ///
    /// An external primary display (an Apple TV's television) is refused
    /// for touch: such a device has no touch screen. With `capture`, for
    /// recording and `frames`, it is taken as it is: it has no backlight
    /// state to check.
    init(_ data: Data, displayId requested: Int? = nil, capture: Bool = false) throws {
        func invalid() -> CommandFailure {
            CommandFailure(.transportFailed, "Expected one integrated primary display with valid typed geometry/orientation; no touch or capture started.", inputSent: .none)
        }
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]], (1...16).contains(displays.count) else {
            throw CommandFailure(.transportFailed, "Cannot read bounded Apple display metadata; no touch or capture started.", inputSent: .none)
        }
        // Without a requested display, the one the interface is on: the
        // primary one, or an unfolded iPhone Duo's inner display
        // (`DeviceUIReadiness.interfaceDisplay`).
        let interface = requested == nil ? DeviceUIReadiness.interfaceDisplay(displays) : nil
        let primary = try displays.filter { display in
            guard let value = display["primary"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw invalid() }
            if let interface { return (display["displayId"] as? NSNumber) == (interface["displayId"] as? NSNumber) }
            return requested.map { (display["displayId"] as? NSNumber)?.intValue == $0 } ?? value.boolValue
        }
        let rotations = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
        guard primary.count == 1, let display = primary.first else { throw invalid() }
        let external = DeviceUIReadiness.isExternal(display)
        if external, !capture { throw CommandFailure.unsupported(AppleTVRemote.touchRefusal) }
        self.external = external
        guard external || (display["type"] as? [String: Any])?["integrated"] is [String: Any] else { throw invalid() }
        guard external || display["backlightState"] as? String == "activeOn" else {
            let subject = requested == nil ? "Primary display" : "Display"
            let state = display["backlightState"] as? String == "off" ? "\(subject) is off." : "\(subject) awake state is unknown or unsupported."
            throw CommandFailure(.displayOff, "\(state) Wake and unlock the selected device, then try again; no touch or capture started.", inputSent: .none)
        }
        func number(_ value: Any?) throws -> Double {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid() }
            return number.doubleValue
        }
        guard let id = display["displayId"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: id.objCType)),
              id.doubleValue > 0, id.doubleValue < Double(Int.max),
              let bounds = display["bounds"] as? [[Any]], bounds.count == 2, bounds.allSatisfy({ $0.count == 2 }),
              let native = rotations[display["nativeOrientation"] as? String ?? ""],
              let current = rotations[display["currentOrientation"] as? String ?? ""] else { throw invalid() }
        let originX = try number(bounds[0][0]), originY = try number(bounds[0][1])
        let width = try number(bounds[1][0]), height = try number(bounds[1][1]), scale = try number(display["pointScale"])
        guard originX == 0, originY == 0, width > 0, height > 0, width <= 32768, height <= 32768,
              (0.1...10).contains(scale) else { throw invalid() }
        self.id = id.intValue; self.width = width; self.height = height; self.scale = scale; self.native = native
        rotation = (native + current) % 360
        if native != 0 {
            // A device that reports its orientation must agree with the
            // display. An Apple Watch reports none (2026-11-24: native rot90,
            // current rot270, no `orientation`): with no sensor, only an
            // upright interface is taken, which a watch's always is.
            let sensor = (result["orientation"] as? [String: Any])?["currentDeviceNonFlatOrientation"] as? String
            let reported = ["portrait": 0, "landscapeRight": 90, "portraitUpsideDown": 180, "landscapeLeft": 270]
            guard sensor.map({ reported[$0] == rotation }) ?? (rotation == 0) else {
                throw CommandFailure(.preconditionChanged, "Device and display orientation disagree; no touch or capture started.", inputSent: .none)
            }
        }
    }

    func portrait(_ x: Double, _ y: Double) -> (Double, Double) {
        switch rotation {
        case 90: (y, 1 - x)
        case 180: (1 - x, 1 - y)
        case 270: (1 - y, x)
        default: (x, y)
        }
    }
}

enum DirectPhysicalTouch {
    static let operations = ["tap", "long-press", "drag", "swipe", "pinch", "multi-drag"]
    struct Point: Equatable { let x: Double; let y: Double }
    struct Sample: Equatable {
        let nanoseconds: UInt64
        let x: Double
        let y: Double
        let phase: UInt64
        var second: Point? = nil
    }

    private static func validateOperation(_ input: CoreDeviceInput) throws {
        guard operations.contains(input.operation) else {
            throw CommandFailure.unsupported("Unsupported direct touch operation: \(input.operation); no input sent.")
        }
        if input.operation == "multi-drag", input.operands.count != 9 {
            throw CommandFailure.usage("Direct multi-drag currently requires exactly two paths. Three-to-five-contact input awaits its direct implementation; no input sent.")
        }
    }

    private static func pairedPlan(_ input: CoreDeviceInput, display: DirectTouchDisplay) throws -> [Sample] {
        try PhysicalInputOperands.validate(input.operation, input.operands)
        let values = input.operands.compactMap(Double.init)
        guard values.count == input.operands.count, values.allSatisfy(\.isFinite) else { throw CommandFailure.usage("Invalid two-contact operands.") }
        let duration: Double
        let paths: [[Double]]
        if input.operation == "pinch" {
            duration = values[4]
            paths = [[values[0] - values[2] / 2, values[1], values[0] - values[3] / 2, values[1]],
                     [values[0] + values[2] / 2, values[1], values[0] + values[3] / 2, values[1]]]
        } else {
            duration = values[0]
            paths = [Array(values[1...4]), Array(values[5...8])]
        }
        // The two physical contacts must remain distinct for the entire linear
        // path, including between emitted samples, not merely at its endpoints.
        let rx = paths[0][0] - paths[1][0], ry = paths[0][1] - paths[1][1]
        let dx = paths[0][2] - paths[1][2] - rx, dy = paths[0][3] - paths[1][3] - ry
        let length = dx * dx + dy * dy
        let closest = length > 0 ? max(0, min(1, -(rx * dx + ry * dy) / length)) : 0
        guard hypot(rx + closest * dx, ry + closest * dy) > 0.000001 else {
            throw CommandFailure.usage("Two-contact paths overlap or cross; no input sent.")
        }
        func sample(_ time: Double, _ fraction: Double, _ phase: UInt64) -> Sample {
            let points = paths.map { path in display.portrait(path[0] + (path[2] - path[0]) * fraction, path[1] + (path[3] - path[1]) * fraction) }
            return Sample(nanoseconds: UInt64((time * 1_000_000_000).rounded()), x: points[0].0, y: points[0].1,
                phase: phase, second: Point(x: points[1].0, y: points[1].1))
        }
        return [sample(0, 0, 0)] + (1...30).map { sample(duration * Double($0) / 30, Double($0) / 30, 1) }
            + [sample(duration + 0.001, 1, 2)]
    }

    static func plan(_ input: CoreDeviceInput, display: DirectTouchDisplay) throws -> [Sample] {
        try validateOperation(input)
        if ["pinch", "multi-drag"].contains(input.operation) { return try pairedPlan(input, display: display) }
        let values = input.operands.compactMap(Double.init)
        let count = input.operation == "tap" ? 2 : (input.operation == "long-press" ? 3 : 5)
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw CommandFailure.usage("Invalid direct touch operands.") }
        let moving = ["drag", "swipe"].contains(input.operation)
        let coordinates = moving ? Array(values.prefix(4)) : Array(values.prefix(2))
        guard coordinates.allSatisfy({ (0...1).contains($0) }) else { throw CommandFailure.usage("Direct touch coordinates must be normalized 0...1.") }
        let duration = input.operation == "tap" ? 0.08 : values[count - 1]
        guard (input.operation == "long-press" ? 0.1...10 : 0.03...10).contains(duration) else { throw CommandFailure.usage("Invalid direct touch duration.") }
        func sample(_ time: Double, _ x: Double, _ y: Double, _ phase: UInt64) -> Sample {
            let point = display.portrait(x, y)
            return Sample(nanoseconds: UInt64((time * 1_000_000_000).rounded()), x: point.0, y: point.1, phase: phase)
        }
        if !moving {
            let frames = max(2, Int(ceil(duration * 60)))
            return [sample(0, values[0], values[1], 0)] + (1..<frames).map {
                sample(duration * Double($0) / Double(frames), values[0], values[1], 1)
            } + [sample(duration, values[0], values[1], 2)]
        }
        var samples = [sample(0, values[0], values[1], 0)]
        for frame in 1...30 {
            let fraction = Double(frame) / 30
            samples.append(sample(duration * fraction, values[0] + (values[2] - values[0]) * fraction,
                values[1] + (values[3] - values[1]) * fraction, 1))
        }
        samples.append(sample(duration + 0.001, values[2], values[3], 2))
        return samples
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (String, String, [Sample]) throws -> Void = dispatch) throws -> Data {
        try validateOperation(input)
        let identity = try DirectPhysicalInput.identity(input, query: query)
        let displayPlan = DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", identity.uuid,
            "--timeout", "15", "--json-output", "-", "--quiet"], jsonOutput: true)
        let display = try DirectTouchDisplay(query(displayPlan))
        let samples = try plan(input, display: display)
        guard try DirectTouchDisplay(query(displayPlan)) == display else {
            throw CommandFailure(.preconditionChanged, "Display changed before touch dispatch; no input sent.", inputSent: .none)
        }
        try Task.checkCancellation()
        try send(identity.uuid, identity.version, samples)
        var result: [String: Any] = ["backend": "coredevice-direct", "operation": input.operation,
            "status": "dispatched", "verified": false, "releaseVerified": false, "device": input.device,
            "resolvedCoreDeviceUUID": identity.uuid, "sampleCount": samples.count,
            "contactCount": samples.first?.second == nil ? 1 : 2,
            "coordinateSpace": "normalized-current-interface", "displayRotationDegrees": display.rotation]
        if input.operation == "long-press" { result["holdSeconds"] = Double(input.operands[2]) }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    private static func dispatch(_ uuid: String, _ version: String, _ samples: [Sample]) throws {
        let wire = samples.map { ADCTouchSample(nanoseconds: $0.nanoseconds, x: $0.x, y: $0.y, phase: $0.phase) }
        var error = [CChar](repeating: 0, count: 1024)
        let status: Int32
        if samples.first?.second != nil {
            let second = samples.compactMap(\.second).map { ADCTouchPoint(x: $0.x, y: $0.y) }
            guard second.count == wire.count else { throw CommandFailure(.internal, "Incomplete second-contact schedule; no input sent.", inputSent: .none) }
            status = wire.withUnsafeBufferPointer { first in
                second.withUnsafeBufferPointer { ADCPerformTwoContactTouch(uuid, version, first.baseAddress, $0.baseAddress, first.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
            }
        } else {
            guard samples.allSatisfy({ $0.second == nil }) else { throw CommandFailure(.internal, "Changing contact count is unsupported; no input sent.", inputSent: .none) }
            status = wire.withUnsafeBufferPointer { ADCPerformTouch(uuid, version, $0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw CommandFailure.inputDispatch(status: status, message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
    }
}
