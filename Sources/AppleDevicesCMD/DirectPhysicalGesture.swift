import AppleDeviceBridge
import Foundation

enum DirectPhysicalGesture {
    struct Request {
        let uuid: String
        let version: String
        let sequence: NativeGestureSequence
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (Request) throws -> UInt64 = dispatch) throws -> Data {
        guard input.operation == "gesture", input.operands.count == 1 else {
            throw CommandFailure(description: "Direct gesture expects one complete JSON schedule; no input sent.")
        }
        _ = try NativeGestureSequence(json: input.operands[0])
        let identity = try DirectPhysicalInput.identity(input, query: query)
        let plan = DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", identity.uuid,
            "--timeout", "15", "--json-output", "-", "--quiet"], jsonOutput: true)
        let display = try DirectTouchDisplay(query(plan))
        let sequence = try NativeGestureSequence(json: input.operands[0], transform: display.portrait)
        guard try DirectTouchDisplay(query(plan)) == display else {
            throw CommandFailure(description: "Display changed before gesture dispatch; no input sent.")
        }
        try Task.checkCancellation()
        let surface = try send(Request(uuid: identity.uuid, version: identity.version, sequence: sequence))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "gesture",
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
                ADCPerformDigitizerReports(request.uuid, request.version, times.baseAddress, reports.baseAddress,
                    times.count, &surface, &error, error.count)
            }
        }
        guard status == 0 else {
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return surface
    }
}
