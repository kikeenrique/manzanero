import AppleDeviceBridge
import Foundation

enum DirectPhysicalKeyboard {
    static let usages: [String: UInt64] = ["return": 40, "escape": 41, "backspace": 42, "tab": 43, "space": 44,
        "right": 79, "left": 80, "down": 81, "up": 82]

    struct Key: Equatable {
        let uuid: String
        let version: String
        let name: String
        let usage: UInt64
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (Key) throws -> Void = dispatch) throws -> Data {
        guard input.operation == "key", input.operands.count == 1,
              let name = input.operands.first, let usage = usages[name] else {
            throw CommandFailure(description: "Unsupported direct keyboard key; no input sent.")
        }
        let identity = try DirectPhysicalInput.identity(input, query: query)
        try Task.checkCancellation()
        try send(Key(uuid: identity.uuid, version: identity.version, name: name, usage: usage))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "key",
            "key": name, "usage": usage, "status": "dispatched", "verified": false, "releaseVerified": false,
            "device": input.device, "resolvedCoreDeviceUUID": identity.uuid], options: [.prettyPrinted, .sortedKeys])
    }

    private static func dispatch(_ key: Key) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCPressKeyboardKey(key.uuid, key.version, key.usage, &error, error.count)
        guard status == 0 else {
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
