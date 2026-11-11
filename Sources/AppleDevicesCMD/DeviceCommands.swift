import Foundation

/// Pure command planning keeps backend selection independent of process execution.
struct DeviceCommand {
    var executable: String = "/usr/bin/xcrun"
    var actionReceipt: Bool = false
    var interactive: Bool = false
    var arguments: [String]
    let jsonOutput: Bool

    static func parse(_ arguments: [String]) throws -> Self? {
        var args = arguments
        var pairingFile: String?
        if args.first == "--pairing-file" {
            guard args.count >= 5, !args[1].isEmpty, args[2] == "physical" else {
                throw CommandFailure(description: "--pairing-file <path> requires a physical bridge operation.")
            }
            pairingFile = args[1]
            args.removeFirst(2)
        }
        if let pairing = try PairingCommand.plan(args) { return pairing }
        if args.first == "decode-ax-archive" {
            guard pairingFile == nil, args.count == 2, !args[1].isEmpty else {
                throw CommandFailure(description: "Usage: decode-ax-archive <local-plist>")
            }
            return Self(executable: "/usr/bin/env", arguments: ["appledevices-idevice", "decode-ax-archive", args[1]], jsonOutput: true)
        }
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
        if physical, var command = try PhysicalInteraction.plan(device: device, operation: operation, operands: operands) {
            if let pairingFile {
                command.arguments.insert(contentsOf: ["--pairing-file", pairingFile], at: 1)
            }
            return command
        }
        guard pairingFile == nil else {
            throw CommandFailure(description: "--pairing-file applies only to physical bridge operations.")
        }
        let command: [String]
        if physical {
            if let dataCommand = try (AppDataCommand.plan(operation: operation, operands: operands) ?? ReportCommand.plan(operation: operation, operands: operands)) {
                return Self(arguments: ["devicectl", "device"] + dataCommand + ["--device", device, "--timeout", "60", "--json-output", "-"], jsonOutput: true)
            }
            switch operation {
            case "apps":
                try require(0)
                command = ["info", "apps", "--include-default-apps"]
            case "launch":
                try require(1)
                command = ["process", "launch"] + operands
            case "processes", "details":
                try require(0)
                command = ["info", operation]
            case "terminate":
                try require(1)
                guard let pid = UInt32(operands[0]), pid > 0, pid <= Int32.max else {
                    throw CommandFailure(description: "Physical terminate requires a positive process ID. Use processes to find it.")
                }
                command = ["process", "terminate", "--pid", String(pid)]
            case "open-url":
                try require(1)
                guard URL(string: operands[0])?.scheme != nil else {
                    throw CommandFailure(description: "open-url requires an absolute URL with a scheme.")
                }
                command = ["process", "openURL", operands[0]]
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
