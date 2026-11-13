import AppleDeviceBridge
import Foundation

struct DirectTouchDisplay: Equatable {
    let id: Int
    let width: Double
    let height: Double
    let scale: Double
    let native: Int
    let rotation: Int

    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else {
            throw CommandFailure(description: "Cannot read Apple display metadata; no touch sent.")
        }
        let primary = displays.filter { $0["primary"] as? Bool == true }
        let rotations = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
        guard primary.count == 1, let display = primary.first,
              (display["type"] as? [String: Any])?["integrated"] != nil,
              display["backlightState"] as? String == "activeOn",
              let id = display["displayId"] as? Int, id > 0,
              let bounds = display["bounds"] as? [[Double]], bounds.count == 2,
              bounds[0] == [0, 0], bounds[1].count == 2,
              bounds[1].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 32768 }),
              let scale = display["pointScale"] as? Double, scale.isFinite, (0.1...10).contains(scale),
              let native = rotations[display["nativeOrientation"] as? String ?? ""],
              let current = rotations[display["currentOrientation"] as? String ?? ""] else {
            throw CommandFailure(description: "Expected one awake integrated primary display with valid geometry/orientation; no touch sent.")
        }
        self.id = id; width = bounds[1][0]; height = bounds[1][1]; self.scale = scale; self.native = native
        rotation = (native + current) % 360
        if native != 0 {
            let sensor = (result["orientation"] as? [String: Any])?["currentDeviceNonFlatOrientation"] as? String
            let reported = ["portrait": 0, "landscapeRight": 90, "portraitUpsideDown": 180, "landscapeLeft": 270]
            guard let sensor, reported[sensor] == rotation else {
                throw CommandFailure(description: "Device and display orientation disagree; no touch sent.")
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
            throw CommandFailure(description: "This physical operation is awaiting its direct Apple API implementation. Non-Apple helper executables are disabled.")
        }
        if input.operation == "multi-drag", input.operands.count != 9 {
            throw CommandFailure(description: "Direct multi-drag currently requires exactly two paths. Three-to-five-contact input awaits its direct implementation; no input sent.")
        }
    }

    private static func pairedPlan(_ input: CoreDeviceInput, display: DirectTouchDisplay) throws -> [Sample] {
        _ = try PhysicalInteraction.plan(device: input.device, operation: input.operation, operands: input.operands)
        let values = input.operands.compactMap(Double.init)
        guard values.count == input.operands.count, values.allSatisfy(\.isFinite) else { throw CommandFailure(description: "Invalid two-contact operands.") }
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
            throw CommandFailure(description: "Two-contact paths overlap or cross; no input sent.")
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
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw CommandFailure(description: "Invalid direct touch operands.") }
        let moving = ["drag", "swipe"].contains(input.operation)
        let coordinates = moving ? Array(values.prefix(4)) : Array(values.prefix(2))
        guard coordinates.allSatisfy({ (0...1).contains($0) }) else { throw CommandFailure(description: "Direct touch coordinates must be normalized 0...1.") }
        let duration = input.operation == "tap" ? 0.08 : values[count - 1]
        guard (input.operation == "long-press" ? 0.1...10 : 0.03...10).contains(duration) else { throw CommandFailure(description: "Invalid direct touch duration.") }
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
            throw CommandFailure(description: "Display changed before touch dispatch; no input sent.")
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
            guard second.count == wire.count else { throw CommandFailure(description: "Incomplete second-contact schedule; no input sent.") }
            status = wire.withUnsafeBufferPointer { first in
                second.withUnsafeBufferPointer { ADCPerformTwoContactTouch(uuid, version, first.baseAddress, $0.baseAddress, first.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
            }
        } else {
            guard samples.allSatisfy({ $0.second == nil }) else { throw CommandFailure(description: "Changing contact count is unsupported; no input sent.") }
            status = wire.withUnsafeBufferPointer { ADCPerformTouch(uuid, version, $0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
    }
}
