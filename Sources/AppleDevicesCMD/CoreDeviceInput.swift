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
              ["button", "tap", "drag", "swipe"].contains(args[4]) else {
            throw CommandFailure(description: "Native backend usage: --physical-backend coredevice physical <device> <button|tap|drag|swipe> ... . Pairing files are not supported by this backend.")
        }
        let operands = Array(args.dropFirst(5))
        guard !args[3].isEmpty, !args[3].hasPrefix("-"), try PhysicalInteraction.plan(device: args[3], operation: args[4], operands: operands) != nil else {
            throw CommandFailure(description: "Invalid native physical input target or operands.")
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

    static func touchscreen(_ data: Data) throws -> String {
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw CommandFailure(description: "Invalid native HID descriptor output.")
        }
        let matches = text.split(whereSeparator: \.isNewline).filter {
            $0.hasPrefix("connectedDescriptor[") && $0.contains("string:\"CoreDevice touchscreen(")
        }
        guard matches.count == 1, let marker = matches[0].range(of: "serviceID:0x") else {
            throw CommandFailure(description: "Native HID discovery did not identify exactly one touchscreen.")
        }
        let hex = matches[0][marker.upperBound...].prefix { !$0.isWhitespace }
        guard !hex.isEmpty, let id = UInt64(hex, radix: 16), id > 0 else {
            throw CommandFailure(description: "Native touchscreen descriptor has an invalid service ID.")
        }
        return String(id)
    }

    func helper(_ resolved: String, feature: String, arguments: [String]) -> DeviceCommand {
        DeviceCommand(executable: "/usr/bin/env", arguments: [
            "DYLD_FRAMEWORK_PATH=/Library/Apple/System/Library/PrivateFrameworks", "HIDCTL_QUIET=1", "HIDCTL_WAIT_MS=700",
            "appledevices-coredevice", resolved, Self.action, feature, "0"
        ] + arguments, jsonOutput: false)
    }

    func actionPlan(_ resolved: String, touchscreen: String?) throws -> DeviceCommand {
        if operation == "button" {
            guard let name = operands.first, let usage = ["home": "64", "lock": "48", "volume-up": "233", "volume-down": "234"][name] else { throw CommandFailure(description: "Unsupported native button.") }
            return helper(resolved, feature: "com.apple.coredevice.feature.remote.hid.button",
                arguments: ["cd_button_click", "12", usage, operands[0] == "lock" ? "0.4" : "0.08"])
        }
        guard let touchscreen else { throw CommandFailure(description: "Native touch requires discovered touchscreen identity.") }
        if operation == "tap" {
            return helper(resolved, feature: Self.universal, arguments: ["cd_uhid_tap", touchscreen] + operands)
        }
        return helper(resolved, feature: Self.universal, arguments: ["cd_uhid_swipe", touchscreen] + operands)
    }

    func execute(run: (DeviceCommand) throws -> Data) throws -> Data {
        let details = try run(identityPlan())
        try DeviceReadiness.decode(details, device: device).requireDeveloperMode(operation: operation)
        let resolved = try Self.resolve(details, requested: device)
        let surface = operation == "button" ? nil : try Self.touchscreen(run(helper(resolved, feature: Self.universal, arguments: ["cd_connected_descriptors_async_raw"])))
        let output = try run(actionPlan(resolved, touchscreen: surface))
        FileHandle.standardError.write(output)
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-ipb", "operation": operation,
            "status": "dispatched", "verified": false, "device": device, "resolvedCoreDeviceUUID": resolved], options: [.prettyPrinted, .sortedKeys])
    }
}
