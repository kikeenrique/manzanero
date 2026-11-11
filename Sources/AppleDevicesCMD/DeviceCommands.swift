import Foundation

/// Pure command planning keeps backend selection independent of process execution.
struct DeviceCommand {
    var executable: String = "/usr/bin/xcrun"
    var actionReceipt: Bool = false
    let arguments: [String]
    let jsonOutput: Bool

    static func parse(_ args: [String]) throws -> Self? {
        guard args.first == "physical" || args.first == "simulator" else { return nil }
        guard args.count >= 3 else {
            throw CommandFailure(description: "Expected <physical|simulator> <device> <operation>. See --help.")
        }
        let physical = args[0] == "physical"
        let device = args[1]
        let operation = args[2]
        let operands = Array(args.dropFirst(3))
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure(description: "Device identifier must be nonempty and cannot begin with '-'.")
        }
        func require(_ count: Int) throws {
            guard operands.count == count, operands.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                throw CommandFailure(description: "\(operation) expects \(count) nonempty operand(s), without a leading '-'.")
            }
        }
        if !physical, let command = try SimulatorInteraction.plan(device: device, operation: operation, operands: operands) {
            return command
        }
        if physical, let command = try PhysicalInteraction.plan(device: device, operation: operation, operands: operands) {
            return command
        }
        let command: [String]
        if physical {
            switch operation {
            case "apps":
                try require(0)
                command = ["info", "apps", "--include-default-apps"]
            case "launch":
                try require(1)
                command = ["process", "launch"] + operands
            case "install", "uninstall":
                try require(1)
                command = [operation, "app"] + operands
            case "screenshot":
                try require(1)
                guard operands[0].lowercased().hasSuffix(".png") else {
                    throw CommandFailure(description: "Screenshot destination must end in .png.")
                }
                command = ["capture", "screenshot", "--destination", operands[0]]
            default:
                throw CommandFailure(description: "Unsupported physical-device operation: \(operation).")
            }
            return Self(arguments: ["devicectl", "device"] + command + ["--device", device, "--timeout", "60", "--json-output", "-"], jsonOutput: true)
        }
        switch operation {
        case "apps":
            try require(0)
            command = ["listapps", device]
        case "boot", "shutdown":
            try require(0)
            command = [operation, device]
        case "launch", "terminate", "install", "uninstall", "open-url":
            try require(1)
            command = [operation == "open-url" ? "openurl" : operation, device] + operands
        case "screenshot":
            try require(1)
            guard operands[0].lowercased().hasSuffix(".png") else {
                throw CommandFailure(description: "Screenshot destination must end in .png.")
            }
            command = ["io", device, "screenshot", "--type=png", operands[0]]
        default:
            throw CommandFailure(description: "Unsupported simulator operation: \(operation).")
        }
        return Self(arguments: ["simctl"] + command, jsonOutput: false)
    }
}
