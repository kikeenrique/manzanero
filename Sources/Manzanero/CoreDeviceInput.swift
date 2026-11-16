import Foundation

/// Native physical input and AX: argument validation, CoreDevice identity
/// resolution and the Apple clipboard plan. Execution lives in `DirectPhysical*`.
struct CoreDeviceInput: Sendable, Equatable {
    let device: String
    let operation: String
    let operands: [String]

    /// The operations that run in process on a physical device.
    static let operations = ["button", "key", "type", "paste", "gesture", "multi-tap", "tree", "press-id", "press-label",
                             "scroll-id", "scroll-label", DirectPhysicalWake.operation] + DirectAccessibilitySetValue.operations
                             + AccessibilityWait.operations + DirectPhysicalTouch.operations

    /// One native physical operation with its operands checked, before any
    /// device query. Long-press operands are normalized to their numbers.
    static func validated(device: String, operation: String, operands: [String]) throws -> Self {
        guard operations.contains(operation) else {
            throw CommandFailure.unsupported("Unsupported native physical operation: \(operation).")
        }
        var operands = operands
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure.usage("Invalid native physical input target or operands.")
        }
        if ["press-id", "press-label", "scroll-id", "scroll-label"].contains(operation) {
            _ = try DirectAccessibilityAction(Self(device: device, operation: operation, operands: operands))
        } else if DirectAccessibilitySetValue.operations.contains(operation) {
            _ = try DirectAccessibilitySetValue(Self(device: device, operation: operation, operands: operands))
        } else if AccessibilityWait.operations.contains(operation) {
            _ = try AccessibilityWait(Self(device: device, operation: operation, operands: operands))
        } else if operation == DirectPhysicalWake.operation {
            try DirectPhysicalWake.validate(operands)
        } else if operation == "tree" {
            if !operands.isEmpty {
                guard operands.count == 1, let pid = Int32(operands[0]), pid > 0 else {
                    throw CommandFailure.usage("Direct physical tree accepts one PID in 1...2147483647, or no PID for primary display-centre selection.")
                }
                operands = [String(pid)]
            }
        } else if operation == "type" {
            guard operands.count == 1 else { throw CommandFailure.usage("Physical typing expects one text operand.") }
            _ = try DirectPhysicalTyping.samples(operands[0])
        } else if operation == "paste" {
            guard operands.count == 1, (1...65536).contains(operands[0].utf8.count), !operands[0].contains("\0") else {
                throw CommandFailure.usage("Native paste requires 1...65536 UTF-8 bytes without NUL. It replaces the device clipboard and pastes at the focused caret/selection.")
            }
        } else if operation == "gesture" {
            guard operands.count == 1 else { throw CommandFailure.usage("Native gesture requires one JSON sequence argument.") }
            _ = try NativeGestureSequence(json: operands[0])
        } else if operation == "long-press" {
            guard operands.count == 3, let x = Double(operands[0]), let y = Double(operands[1]),
                  let seconds = Double(operands[2]), x.isFinite, y.isFinite, seconds.isFinite,
                  (0...1).contains(x), (0...1).contains(y), (0.1...10).contains(seconds) else {
                throw CommandFailure.usage("Native long-press requires normalized x/y in 0...1 and duration 0.1...10 seconds.")
            }
            operands = [x, y, seconds].map { String($0) }
        } else {
            try PhysicalInputOperands.validate(operation, operands)
        }
        return Self(device: device, operation: operation, operands: operands)
    }

    func identityPlan() throws -> DeviceCommand {
        var plan = try DeviceCommand.plan(physical: true, device: device, operation: "details")
        plan.arguments.append("--quiet")
        return plan
    }

    static func resolve(_ data: Data, requested: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = value["result"] as? [String: Any], let identifier = result["identifier"] as? String,
              let uuid = UUID(uuidString: identifier) else {
            throw CommandFailure(.deviceNotReady, "CoreDevice details did not identify one successful device UUID.", inputSent: .none)
        }
        if let requestedUUID = UUID(uuidString: requested), requestedUUID != uuid {
            throw CommandFailure(.targetUnresolved, "CoreDevice resolved a different UUID; refusing input.", inputSent: .none)
        }
        if requested.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil {
            let hardware = ((result["properties"] as? [String: Any])?["hardware"] as? [String: Any])
            guard let udid = hardware?["udid"] as? String, udid.caseInsensitiveCompare(requested) == .orderedSame else {
                throw CommandFailure(.targetUnresolved, "CoreDevice resolved a different hardware UDID; refusing input.", inputSent: .none)
            }
        }
        return uuid.uuidString
    }

    func clipboardPlan(_ resolved: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "pasteboard", "copy", "--device", resolved, "--timeout", "30", "--quiet", "--json-output", "-"], jsonOutput: true)
    }
}
