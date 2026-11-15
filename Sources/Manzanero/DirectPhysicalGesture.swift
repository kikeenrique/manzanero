import AppleDeviceBridge
import Foundation

enum DirectPhysicalGesture {
    static func handles(_ input: CoreDeviceInput) -> Bool {
        input.operation == "gesture" || input.operation == "multi-tap" ||
            (input.operation == "multi-drag" && input.operands.count != 9)
    }

    static func sequence(for input: CoreDeviceInput,
                         transform: (Double, Double) -> (Double, Double) = { ($0, $1) }) throws -> NativeGestureSequence {
        if input.operation == "gesture", input.operands.count == 1 {
            return try NativeGestureSequence(json: input.operands[0], transform: transform)
        }
        guard ["multi-tap", "multi-drag"].contains(input.operation) else {
            throw CommandFailure.usage("Direct gesture expects a JSON schedule, multi-tap points, or multi-drag paths; no input sent.")
        }
        try PhysicalInputOperands.validate(input.operation, input.operands)
        // The validation above guarantees finite coordinates and duration.
        let values = input.operands.compactMap(Double.init)
        typealias Touch = NativeGestureSequence.Touch
        typealias Frame = NativeGestureSequence.Frame
        if input.operation == "multi-tap" {
            let touches = stride(from: 0, to: values.count, by: 2).map {
                Touch(id: $0 / 2, x: values[$0], y: values[$0 + 1])
            }
            return try NativeGestureSequence(frames: [Frame(ms: 0, touches: touches), Frame(ms: 80, touches: [])], transform: transform)
        }
        let duration = Int((values[0] * 1000).rounded())
        let frames = (0...30).map { step in
            let fraction = Double(step) / 30
            let touches = stride(from: 1, to: values.count, by: 4).map { offset in
                Touch(id: (offset - 1) / 4,
                      x: values[offset] + (values[offset + 2] - values[offset]) * fraction,
                      y: values[offset + 1] + (values[offset + 3] - values[offset + 1]) * fraction)
            }
            return Frame(ms: Int((Double(duration) * fraction).rounded()), touches: touches)
        }
        return try NativeGestureSequence(frames: frames + [Frame(ms: duration + 1, touches: [])], transform: transform)
    }

    struct Request {
        let uuid: String
        let version: String
        let sequence: NativeGestureSequence
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (Request) throws -> UInt64 = dispatch) throws -> Data {
        _ = try sequence(for: input)
        let identity = try DirectPhysicalInput.identity(input, query: query)
        let plan = DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", identity.uuid,
            "--timeout", "15", "--json-output", "-", "--quiet"], jsonOutput: true)
        let display = try DirectTouchDisplay(query(plan))
        let sequence = try sequence(for: input, transform: display.portrait)
        guard try DirectTouchDisplay(query(plan)) == display else {
            throw CommandFailure(.preconditionChanged, "Display changed before gesture dispatch; no input sent.", inputSent: .none)
        }
        try Task.checkCancellation()
        let surface = try send(Request(uuid: identity.uuid, version: identity.version, sequence: sequence))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": input.operation,
            "status": "dispatched", "verified": false, "releaseVerified": false, "device": input.device,
            "resolvedCoreDeviceUUID": identity.uuid, "surfaceID": surface,
            "frameCount": sequence.times.count, "contactSlots": sequence.contactCount,
            "durationMilliseconds": sequence.times.last ?? 0,
            "coordinateSpace": "normalized-current-interface", "displayRotationDegrees": display.rotation],
            options: [.prettyPrinted, .sortedKeys])
    }

    private static func dispatch(_ request: Request) throws -> UInt64 {
        let times = request.sequence.times.map { UInt64($0) * 1_000_000 }
        let bytes = request.sequence.reports.flatMap { $0 }
        var error = [CChar](repeating: 0, count: 1024), surface: UInt64 = 0
        let status = times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCPerformCancellableDigitizerReports(request.uuid, request.version, times.baseAddress, reports.baseAddress,
                    times.count, { Task.isCancelled ? 1 : 0 }, &surface, &error, error.count)
            }
        }
        // The C loop has completed its release/barrier cleanup before this
        // escapes to MCP's request-cancellation handler.
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure.inputDispatch(status: status, message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return surface
    }
}
