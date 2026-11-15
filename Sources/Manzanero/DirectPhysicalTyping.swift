import AppleDeviceBridge
import Foundation

enum DirectPhysicalTyping {
    struct Stroke: Equatable {
        let usage: UInt64
        let shift: Bool
    }

    static func stroke(_ byte: UInt8) -> Stroke? {
        switch byte {
        case 97...122: return Stroke(usage: UInt64(byte - 97 + 4), shift: false)
        case 65...90: return Stroke(usage: UInt64(byte - 65 + 4), shift: true)
        case 49...57: return Stroke(usage: UInt64(byte - 49 + 30), shift: false)
        case 48: return Stroke(usage: 39, shift: false)
        case 9: return Stroke(usage: 43, shift: false)
        case 10: return Stroke(usage: 40, shift: false)
        case 32: return Stroke(usage: 44, shift: false)
        default: break
        }
        if let index = Array("!@#$%^&*()".utf8).firstIndex(of: byte) {
            return Stroke(usage: UInt64(30 + index), shift: true)
        }
        let codes: [UInt64] = [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56]
        for (characters, shift) in [("-=[]\\;'`,./", false), ("_+{}|:\"~<>?", true)] {
            if let index = Array(characters.utf8).firstIndex(of: byte) {
                return Stroke(usage: codes[index], shift: shift)
            }
        }
        return nil
    }

    static func samples(_ text: String) throws -> [ADCKeyboardSample] {
        let bytes = Array(text.utf8)
        guard (1...512).contains(bytes.count) else {
            throw CommandFailure.usage("Physical typing requires 1...512 printable US-layout ASCII characters, tab or LF newline; no input sent.")
        }
        var result: [ADCKeyboardSample] = []
        func append(_ usage: UInt64, _ state: UInt64) {
            result.append(ADCKeyboardSample(nanoseconds: UInt64(result.count) * 10_000_000, usage: usage, state: state))
        }
        for byte in bytes {
            guard let key = stroke(byte) else {
                throw CommandFailure.usage("Physical typing requires printable US-layout ASCII, tab or LF newline. For Unicode use explicit paste, which replaces the clipboard. No input sent.")
            }
            if key.shift { append(225, 1) }
            append(key.usage, 1)
            append(key.usage, 2)
            if key.shift { append(225, 2) }
        }
        return result
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (DirectPhysicalKeyboard.Sequence) throws -> Void = DirectPhysicalKeyboard.dispatchSequence) throws -> Data {
        guard input.operation == "type", input.operands.count == 1 else {
            throw CommandFailure.usage("Physical typing expects one text operand; no input sent.")
        }
        let schedule = try samples(input.operands[0])
        let identity = try DirectPhysicalInput.identity(input, query: query)
        try Task.checkCancellation()
        try send(.init(uuid: identity.uuid, version: identity.version, samples: schedule))
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "type",
            "status": "dispatched", "verified": false, "insertionVerified": false, "releaseVerified": false,
            "layout": "US", "characterCount": input.operands[0].utf8.count, "sampleCount": schedule.count,
            "device": input.device, "resolvedCoreDeviceUUID": identity.uuid], options: [.prettyPrinted, .sortedKeys])
    }
}
