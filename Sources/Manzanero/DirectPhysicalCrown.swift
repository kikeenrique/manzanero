import AppleDeviceBridge
import Foundation

/// Digital Crown rotation on a physical Apple Watch: the simulator's steps
/// (`DigitalCrown`) sent to the watch's own `hid.scroll` service, which a
/// watch lists among its capabilities (an Apple Watch on watchOS 27.2.1,
/// 2026-11-24). Any other device is refused before input.
enum DirectPhysicalCrown {
    struct Turn: Equatable {
        let uuid: String
        let version: String
        let deltas: [Double]
        let intervalNanoseconds: UInt64
    }

    static let refusal = "crown turns an Apple Watch's Digital Crown; this device is not an Apple Watch. No input sent."

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (Turn) throws -> Void = dispatch) throws -> Data {
        guard input.operation == "crown", !input.operands.isEmpty, input.operands.count <= 2 else {
            throw CommandFailure.usage(DigitalCrown.usage)
        }
        let units = try DigitalCrown.units(input.operands[0])
        let events = try DigitalCrown.events(input.operands.count == 2 ? input.operands[1] : nil, units: units)
        let details = try query(input.identityPlan())
        guard AppleTVRemote.deviceType(details) == "appleWatch" else { throw CommandFailure.unsupported(refusal) }
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        try Task.checkCancellation()
        try send(Turn(uuid: identity.uuid, version: identity.version, deltas: DigitalCrown.steps(units, events: events),
                      intervalNanoseconds: DigitalCrown.intervalMilliseconds * 1_000_000))
        var result: [String: Any] = ["backend": "coredevice-direct", "operation": "crown", "status": "dispatched", "verified": false,
                                     "device": input.device, "resolvedCoreDeviceUUID": identity.uuid]
        result["crown"] = DigitalCrown.describe(units, events: events)
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    static func dispatch(_ turn: Turn) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let status = turn.deltas.withUnsafeBufferPointer {
            ADCRotateCrown(turn.uuid, turn.version, $0.baseAddress, $0.count, turn.intervalNanoseconds, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure.inputDispatch(status: status, message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
