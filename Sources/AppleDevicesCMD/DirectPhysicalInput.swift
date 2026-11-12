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
            throw CommandFailure(description: "This physical operation is awaiting its direct Apple API implementation. Non-Apple helper executables are disabled.")
        }
        let details = try query(input.identityPlan())
        try DeviceReadiness.decode(details, device: input.device).requireDeveloperMode(operation: "button")
        let uuid = try CoreDeviceInput.resolve(details, requested: input.device)
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let version = (root["info"] as? [String: Any])?["version"] as? String,
              version.range(of: "^[0-9]+(?:\\.[0-9]+){0,3}$", options: .regularExpression) != nil else {
            throw CommandFailure(description: "CoreDevice did not report a valid service version; no input sent.")
        }
        try Task.checkCancellation()
        try send(Button(uuid: uuid, version: version, usage: usage, holdMicroseconds: name == "lock" ? 400_000 : 80_000))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "button",
            "status": "dispatched", "verified": false, "releaseVerified": false,
            "device": input.device, "resolvedCoreDeviceUUID": uuid], options: [.prettyPrinted, .sortedKeys])
    }

    private static func dispatch(_ button: Button) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCPressButton(button.uuid, button.version, button.usage, button.holdMicroseconds, &error, error.count)
        guard status == 0 else {
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
