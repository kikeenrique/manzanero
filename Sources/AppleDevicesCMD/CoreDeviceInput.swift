import Foundation

/// Optional MIT-licensed ipb helper; Apple private ABI stays outside the Swift CLI.
struct CoreDeviceInput {
    let device: String
    let operation: String
    let operands: [String]
    static let action = "com.apple.coredevice.action.createservicesocket"
    static let universal = "com.apple.coredevice.feature.remote.universalhidservice"

    static func parse(_ args: [String]) throws -> Self? {
        guard args.first == "--physical-backend" else { return nil }
        guard args.count >= 5, args[1] == "coredevice", args[2] == "physical",
              ["button", "tap", "drag", "swipe", "key", "paste", "multi-drag", "pinch"].contains(args[4]) else {
            throw CommandFailure(description: "Native backend usage: --physical-backend coredevice physical <device> <button|tap|drag|swipe|key|paste|multi-drag|pinch> ... . Pairing files are not supported by this backend.")
        }
        let operands = Array(args.dropFirst(5))
        guard !args[3].isEmpty, !args[3].hasPrefix("-") else {
            throw CommandFailure(description: "Invalid native physical input target or operands.")
        }
        if args[4] == "paste" {
            guard operands.count == 1, (1...65536).contains(operands[0].utf8.count), !operands[0].contains("\0") else {
                throw CommandFailure(description: "Native paste requires 1...65536 UTF-8 bytes without NUL. It replaces the device clipboard and pastes at the focused caret/selection.")
            }
        } else {
            guard try PhysicalInteraction.plan(device: args[3], operation: args[4], operands: operands) != nil else { throw CommandFailure(description: "Unsupported native input operation.") }
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

    enum Surface { case touchscreen, keyboard }

    static func touchscreen(_ data: Data) throws -> String { try surface(data, role: .touchscreen) }

    static func surface(_ data: Data, role: Surface) throws -> String {
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw CommandFailure(description: "Invalid native HID descriptor output.")
        }
        let matches = text.split(whereSeparator: \.isNewline).filter {
            $0.hasPrefix("connectedDescriptor[") && $0.contains(role == .touchscreen ? "string:\"CoreDevice touchscreen(" : "string:\"CoreDevice keyboard\"")
        }
        guard matches.count == 1, let marker = matches[0].range(of: "serviceID:0x") else {
            throw CommandFailure(description: "Native HID discovery did not identify exactly one \(role == .touchscreen ? "touchscreen" : "keyboard").")
        }
        let hex = matches[0][marker.upperBound...].prefix { !$0.isWhitespace }
        guard !hex.isEmpty, let id = UInt64(hex, radix: 16), id > 0 else {
            throw CommandFailure(description: "Native HID descriptor has an invalid service ID.")
        }
        return String(id)
    }

    func helper(_ resolved: String, feature: String, arguments: [String]) -> DeviceCommand {
        DeviceCommand(executable: "/usr/bin/env", arguments: [
            "DYLD_FRAMEWORK_PATH=/Library/Apple/System/Library/PrivateFrameworks", "HIDCTL_QUIET=1", "HIDCTL_WAIT_MS=700",
            "appledevices-coredevice", resolved, Self.action, feature, "0"
        ] + arguments, jsonOutput: false)
    }

    func actionPlan(_ resolved: String, surface: String?) throws -> DeviceCommand {
        if operation == "button" {
            guard let name = operands.first, let usage = ["home": "64", "lock": "48", "volume-up": "233", "volume-down": "234"][name] else { throw CommandFailure(description: "Unsupported native button.") }
            return helper(resolved, feature: "com.apple.coredevice.feature.remote.hid.button",
                arguments: ["cd_button_click", "12", usage, operands[0] == "lock" ? "0.4" : "0.08"])
        }
        if operation == "key" {
            guard let surface, let name = operands.first,
                  let usage = ["return": "40", "escape": "41", "backspace": "42", "tab": "43", "space": "44", "right": "79", "left": "80", "down": "81", "up": "82"][name] else {
                throw CommandFailure(description: "Native key requires a discovered keyboard and a supported key.")
            }
            return helper(resolved, feature: Self.universal, arguments: ["cd_key", surface, usage, "0.08"])
        }
        if operation == "paste" {
            guard let surface else { throw CommandFailure(description: "Native paste requires a discovered keyboard.") }
            return helper(resolved, feature: Self.universal, arguments: ["cd_paste", surface])
        }
        guard let surface else { throw CommandFailure(description: "Native touch requires discovered touchscreen identity.") }
        if ["multi-drag", "pinch"].contains(operation) {
            let frames = try NativeTouchFrames(device: device, operation: operation, operands: operands)
            return helper(resolved, feature: Self.universal, arguments: ["cd_multitouch", surface] + frames.arguments)
        }
        if operation == "tap" {
            return helper(resolved, feature: Self.universal, arguments: ["cd_uhid_tap", surface] + operands)
        }
        return helper(resolved, feature: Self.universal, arguments: ["cd_uhid_swipe", surface] + operands)
    }

    func clipboardPlan(_ resolved: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "pasteboard", "copy", "--device", resolved, "--timeout", "30", "--quiet", "--json-output", "-"], jsonOutput: true)
    }

    func execute(copy: ((DeviceCommand, Data) throws -> Data)? = nil, run: (DeviceCommand) throws -> Data) throws -> Data {
        let details = try run(identityPlan())
        try DeviceReadiness.decode(details, device: device).requireDeveloperMode(operation: operation)
        let resolved = try Self.resolve(details, requested: device)
        let role: Surface = ["key", "paste"].contains(operation) ? .keyboard : .touchscreen
        let surface = operation == "button" ? nil : try Self.surface(run(helper(resolved, feature: Self.universal, arguments: ["cd_connected_descriptors_async_raw"])), role: role)
        if operation == "paste" {
            guard let copy else { throw CommandFailure(description: "Native paste requires subprocess stdin support.") }
            do {
                let data = try copy(clipboardPlan(resolved), Data(operands[0].utf8))
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], (value["info"] as? [String: Any])?["outcome"] as? String == "success" else {
                    throw CommandFailure(description: "Clipboard writer did not confirm success.")
                }
            } catch {
                throw CommandFailure(description: "Clipboard write did not complete successfully; clipboard state may have changed. Paste was not sent. \(error)")
            }
        }
        let output: Data
        do { output = try run(actionPlan(resolved, surface: surface)) }
        catch {
            if operation == "paste" { throw CommandFailure(description: "Clipboard was replaced, but paste dispatch failed or timed out; insertion is unknown. Inspect the focused field before retrying. \(error)") }
            throw error
        }
        FileHandle.standardError.write(output)
        var result: [String: Any] = ["backend": "coredevice-ipb", "operation": operation,
            "status": "dispatched", "verified": false, "device": device, "resolvedCoreDeviceUUID": resolved]
        if operation == "paste" { result["clipboard"] = "replaced"; result["insertionVerified"] = false }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}
