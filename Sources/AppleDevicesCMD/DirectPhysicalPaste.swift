import AppleDeviceBridge
import Foundation

enum DirectPhysicalPaste {
    typealias Dispatch = DirectPhysicalKeyboard.Sequence

    static var samples: [ADCKeyboardSample] {
        // Left Command down, V down/up, then Command up. No select-all.
        [(UInt64(0), UInt64(227), UInt64(1)), (40_000_000, 25, 1),
         (120_000_000, 25, 2), (160_000_000, 227, 2)].map {
            ADCKeyboardSample(nanoseconds: $0.0, usage: $0.1, state: $0.2)
        }
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        copy: (DeviceCommand, Data) throws -> Data,
                        send: (Dispatch) throws -> Void = DirectPhysicalKeyboard.dispatchSequence) throws -> Data {
        guard input.operation == "paste", input.operands.count == 1,
              let text = input.operands.first, (1...65536).contains(text.utf8.count), !text.contains("\0") else {
            throw CommandFailure(description: "Paste requires 1...65536 UTF-8 bytes without NUL; no clipboard write or input sent.")
        }
        let identity = try DirectPhysicalInput.identity(input, query: query)
        try Task.checkCancellation()
        do {
            let output = try copy(input.clipboardPlan(identity.uuid), Data(text.utf8))
            guard let value = try JSONSerialization.jsonObject(with: output) as? [String: Any],
                  (value["info"] as? [String: Any])?["outcome"] as? String == "success" else {
                throw CommandFailure(description: "Apple clipboard writer did not confirm success.")
            }
        } catch {
            throw CommandFailure(description: "Clipboard write failed or was not confirmed; clipboard state may have changed. No paste keys were sent. \(error)")
        }
        do {
            try Task.checkCancellation()
            try send(Dispatch(uuid: identity.uuid, version: identity.version, samples: samples))
        } catch {
            throw CommandFailure(description: "Clipboard was replaced, but paste dispatch failed or was cancelled; insertion and key release are unknown. Inspect the focused field before retrying; no automatic replay. \(error)")
        }
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "paste",
            "status": "dispatched", "verified": false, "insertionVerified": false, "releaseVerified": false,
            "clipboard": "replaced", "device": input.device, "resolvedCoreDeviceUUID": identity.uuid],
            options: [.prettyPrinted, .sortedKeys])
    }

}
