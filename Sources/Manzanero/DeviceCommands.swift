import Foundation

/// Pure planning of Apple `devicectl`/`simctl` invocations, independent of process execution.
struct DeviceCommand: Sendable, Equatable {
    var executable: String = "/usr/bin/xcrun"
    var arguments: [String]
    let jsonOutput: Bool

    /// The `devicectl` or `simctl` invocation for one wrapped operation, after
    /// checking its operands. An operation the platform lacks is unsupported.
    static func plan(physical: Bool, device: String, operation: String, operands: [String] = []) throws -> Self {
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure.usage("Device identifier must be nonempty and cannot begin with '-'.")
        }
        func require(_ count: Int) throws {
            guard operands.count == count, operands.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                throw CommandFailure.usage("\(operation) expects \(count) nonempty operand(s), without a leading '-'.")
            }
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
                // Launch consumes everything after the app operand as app argv.
                // Keep device/output options before it, including in Build & Run.
                return Self(arguments: ["devicectl", "device", "process", "launch", "--device", device,
                    "--timeout", "60", "--json-output", "-"] + operands, jsonOutput: true)
            case "processes", "details":
                try require(0)
                command = ["info", operation]
            case "terminate":
                try require(1)
                guard let pid = UInt32(operands[0]), pid > 0, pid <= Int32.max else {
                    throw CommandFailure.usage("Physical terminate requires a positive process ID. Use processes to find it.")
                }
                command = ["process", "terminate", "--pid", String(pid)]
            case "open-url":
                try require(1)
                guard URL(string: operands[0])?.scheme != nil else {
                    throw CommandFailure.usage("open-url requires an absolute URL with a scheme.")
                }
                command = ["process", "openURL", operands[0]]
            case "install", "uninstall":
                try require(1)
                command = [operation, "app"] + operands
            case "screenshot":
                try require(1)
                guard operands[0].lowercased().hasSuffix(".png") else {
                    throw CommandFailure.usage("Screenshot destination must end in .png.")
                }
                command = ["capture", "screenshot", "--destination", operands[0]]
            default:
                throw CommandFailure.unsupported("Unsupported physical-device operation: \(operation).")
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
                throw CommandFailure.usage("Screenshot destination must end in .png.")
            }
            command = ["io", device, "screenshot", "--type=png", operands[0]]
        default:
            // Simulator input and accessibility (SimulatorInput) are routed
            // before these simctl wrappers.
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        return Self(arguments: ["simctl"] + command, jsonOutput: false)
    }
}
