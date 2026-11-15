import Foundation

/// Native physical input and AX: argument validation, CoreDevice identity
/// resolution and the Apple clipboard plan. Execution lives in `DirectPhysical*`.
struct CoreDeviceInput {
    let device: String
    let operation: String
    let operands: [String]

    /// `coredevice` is the only physical backend, so it is also the default.
    static func selectDefaultBackend(_ args: [String]) -> [String] {
        args.count >= 3 && args[0] == "physical" &&
            (["button", "key", "type", "paste", "gesture", "multi-tap", "tree", "press-id", "press-label", "scroll-id", "scroll-label", DirectPhysicalWake.operation]
                + AccessibilityWait.operations + DirectPhysicalTouch.operations).contains(args[2])
            ? ["--physical-backend", "coredevice"] + args : args
    }

    static func parse(_ args: [String]) throws -> Self? {
        guard args.first == "--physical-backend" else { return nil }
        guard args.count >= 2, args[1] == "coredevice" else {
            throw CommandFailure(description: "Unsupported physical backend: \(args.count >= 2 ? args[1] : "<none>"). coredevice is the only physical backend and the default; --physical-backend may be omitted.")
        }
        guard args.count >= 5, args[2] == "physical",
              (["button", "tap", "multi-tap", "long-press", "gesture", "drag", "swipe", "key", "type", "paste", "multi-drag", "pinch", "tree", "press-id", "press-label", "scroll-id", "scroll-label", DirectPhysicalWake.operation] + AccessibilityWait.operations).contains(args[4]) else {
            throw CommandFailure(description: "Native backend usage: --physical-backend coredevice physical <device> <button|tap|multi-tap|long-press|gesture|drag|swipe|key|type|paste|multi-drag|pinch|tree|press-id|press-label|scroll-id|scroll-label|wait-id|wait-label|wake> ... . Tree, selector actions and waits accept an optional PID.")
        }
        var operands = Array(args.dropFirst(5))
        guard !args[3].isEmpty, !args[3].hasPrefix("-") else {
            throw CommandFailure(description: "Invalid native physical input target or operands.")
        }
        if ["press-id", "press-label", "scroll-id", "scroll-label"].contains(args[4]) {
            _ = try DirectAccessibilityAction(Self(device: args[3], operation: args[4], operands: operands))
        } else if AccessibilityWait.operations.contains(args[4]) {
            _ = try AccessibilityWait(Self(device: args[3], operation: args[4], operands: operands))
        } else if args[4] == DirectPhysicalWake.operation {
            try DirectPhysicalWake.validate(operands)
        } else if args[4] == "tree" {
            if !operands.isEmpty {
                guard operands.count == 1, let pid = Int32(operands[0]), pid > 0 else {
                    throw CommandFailure(description: "Direct physical tree accepts one PID in 1...2147483647, or no PID for primary display-centre selection.")
                }
                operands = [String(pid)]
            }
        } else if args[4] == "type" {
            guard operands.count == 1 else { throw CommandFailure(description: "Physical typing expects one text operand.") }
            _ = try DirectPhysicalTyping.samples(operands[0])
        } else if args[4] == "paste" {
            guard operands.count == 1, (1...65536).contains(operands[0].utf8.count), !operands[0].contains("\0") else {
                throw CommandFailure(description: "Native paste requires 1...65536 UTF-8 bytes without NUL. It replaces the device clipboard and pastes at the focused caret/selection.")
            }
        } else if args[4] == "gesture" {
            guard operands.count == 1 else { throw CommandFailure(description: "Native gesture requires one JSON sequence argument.") }
            _ = try NativeGestureSequence(json: operands[0])
        } else if args[4] == "long-press" {
            guard operands.count == 3, let x = Double(operands[0]), let y = Double(operands[1]),
                  let seconds = Double(operands[2]), x.isFinite, y.isFinite, seconds.isFinite,
                  (0...1).contains(x), (0...1).contains(y), (0.1...10).contains(seconds) else {
                throw CommandFailure(description: "Native long-press requires normalized x/y in 0...1 and duration 0.1...10 seconds.")
            }
            operands = [x, y, seconds].map { String($0) }
        } else {
            try PhysicalInputOperands.validate(args[4], operands)
        }
        return Self(device: args[3], operation: args[4], operands: operands)
    }

    func identityPlan() throws -> DeviceCommand {
        guard var plan = try DeviceCommand.parse(["physical", device, "details"]) else { throw CommandFailure(description: "Cannot plan CoreDevice identity query.") }
        plan.arguments.append("--quiet")
        return plan
    }

    static func resolve(_ data: Data, requested: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = value["result"] as? [String: Any], let identifier = result["identifier"] as? String,
              let uuid = UUID(uuidString: identifier) else {
            throw CommandFailure(description: "CoreDevice details did not identify one successful device UUID.")
        }
        if let requestedUUID = UUID(uuidString: requested), requestedUUID != uuid {
            throw CommandFailure(description: "CoreDevice resolved a different UUID; refusing input.")
        }
        if requested.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil {
            let hardware = ((result["properties"] as? [String: Any])?["hardware"] as? [String: Any])
            guard let udid = hardware?["udid"] as? String, udid.caseInsensitiveCompare(requested) == .orderedSame else {
                throw CommandFailure(description: "CoreDevice resolved a different hardware UDID; refusing input.")
            }
        }
        return uuid.uuidString
    }

    func clipboardPlan(_ resolved: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "pasteboard", "copy", "--device", resolved, "--timeout", "30", "--quiet", "--json-output", "-"], jsonOutput: true)
    }
}
