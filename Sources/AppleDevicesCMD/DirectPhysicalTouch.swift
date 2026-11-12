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
    struct Sample: Equatable {
        let nanoseconds: UInt64
        let x: Double
        let y: Double
        let phase: UInt64
    }

    static func plan(_ input: CoreDeviceInput, display: DirectTouchDisplay) throws -> [Sample] {
        guard ["tap", "long-press", "drag", "swipe"].contains(input.operation) else {
            throw CommandFailure(description: "This physical operation is awaiting its direct Apple API implementation. Non-Apple helper executables are disabled.")
        }
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
        guard ["tap", "long-press", "drag", "swipe"].contains(input.operation) else {
            throw CommandFailure(description: "This physical operation is awaiting its direct Apple API implementation. Non-Apple helper executables are disabled.")
        }
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
            "coordinateSpace": "normalized-current-interface", "displayRotationDegrees": display.rotation]
        if input.operation == "long-press" { result["holdSeconds"] = Double(input.operands[2]) }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    private static func dispatch(_ uuid: String, _ version: String, _ samples: [Sample]) throws {
        let wire = samples.map { ADCTouchSample(nanoseconds: $0.nanoseconds, x: $0.x, y: $0.y, phase: $0.phase) }
        var error = [CChar](repeating: 0, count: 1024)
        let status = wire.withUnsafeBufferPointer { ADCPerformTouch(uuid, version, $0.baseAddress, $0.count, &error, error.count) }
        guard status == 0 else { throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
    }
}
