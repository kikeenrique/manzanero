import AppleDeviceBridge
import Foundation

/// `type`: text as Indigo keyboard events at the current focus, in the
/// keyboard layout the caller names (docs/physical-typing.md,
/// docs/keyboard-layouts.md). Shared by the physical and simulator routes.
enum DirectPhysicalTyping {
    /// The text and its layout from `type`'s operands: `[text]` or `[text, layout]`.
    static func request(_ operands: [String], subject: String) throws -> (text: String, layout: KeyboardLayout) {
        guard (1...2).contains(operands.count) else {
            throw CommandFailure.usage("\(subject) typing expects one text operand and an optional layout; no input sent.")
        }
        let layout = try KeyboardLayout.named(operands.count == 2 ? operands[1] : KeyboardLayout.defaultName)
        _ = try layout.samples(operands[0])
        return (operands[0], layout)
    }

    /// The validated operands, with the layout's canonical name: `[text, layout]`.
    static func operands(_ operands: [String], subject: String) throws -> [String] {
        let (text, layout) = try request(operands, subject: subject)
        return [text, layout.source.name]
    }

    /// The fields typing plans and receipts share.
    static func fields(_ text: String, layout: KeyboardLayout, samples: [ADCKeyboardSample]) -> [String: Any] {
        layout.receiptFields.merging(["characterCount": text.count, "sampleCount": samples.count]) { _, new in new }
    }

    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        send: (DirectPhysicalKeyboard.Sequence) throws -> Void = DirectPhysicalKeyboard.dispatchSequence) throws -> Data {
        guard input.operation == "type" else {
            throw CommandFailure.usage("Physical typing expects one text operand; no input sent.")
        }
        let (text, layout) = try request(input.operands, subject: "Physical")
        let schedule = try layout.samples(text)
        let identity = try DirectPhysicalInput.identity(input, query: query)
        try Task.checkCancellation()
        try send(.init(uuid: identity.uuid, version: identity.version, samples: schedule))
        var receipt = fields(text, layout: layout, samples: schedule)
        receipt.merge(["backend": "coredevice-direct", "operation": "type", "status": "dispatched", "verified": false,
                       "insertionVerified": false, "releaseVerified": false, "deviceLayout": DeviceKeyboardLayout.physical(layout),
                       "device": input.device, "resolvedCoreDeviceUUID": identity.uuid]) { _, new in new }
        return try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    }
}
