import AppleDeviceBridge
import Foundation

enum DirectPhysicalInput {
    struct Button: Equatable {
        let uuid: String
        let version: String
        let usage: UInt64
        let holdMicroseconds: UInt32
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (Button) throws -> Void = dispatch) throws -> Data {
        guard input.operation == "button", let name = input.operands.first,
              let usage = ["home": UInt64(64), "lock": 48, "volume-up": 233, "volume-down": 234][name] else {
            throw CommandFailure.usage("Unsupported direct button input: \(input.operation) \(input.operands.joined(separator: " ")); no input sent.")
        }
        let identity = try identity(input, query: query)
        try Task.checkCancellation()
        try send(Button(uuid: identity.uuid, version: identity.version, usage: usage, holdMicroseconds: name == "lock" ? 400_000 : 80_000))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "button",
            "status": "dispatched", "verified": false, "releaseVerified": false,
            "device": input.device, "resolvedCoreDeviceUUID": identity.uuid], options: [.prettyPrinted, .sortedKeys])
    }

    static func identity(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data) throws -> (uuid: String, version: String) {
        let details = try query(input.identityPlan())
        try DeviceReadiness.decode(details, device: input.device).requireDeveloperMode(operation: input.operation)
        let uuid = try CoreDeviceInput.resolve(details, requested: input.device)
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let version = (root["info"] as? [String: Any])?["version"] as? String,
              version.range(of: "^[0-9]+(?:\\.[0-9]+){0,3}$", options: .regularExpression) != nil else {
            throw CommandFailure(.transportFailed, "CoreDevice did not report a valid service version; no input sent.", inputSent: .none)
        }
        return (uuid, version)
    }

    private static func dispatch(_ button: Button) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCPressButton(button.uuid, button.version, button.usage, button.holdMicroseconds, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure.inputDispatch(status: status, message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
