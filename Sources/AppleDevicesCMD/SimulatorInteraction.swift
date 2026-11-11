import Foundation

/// Optional open-source AXe backend. No proprietary device-control tooling code is loaded.
enum SimulatorInteraction {
    static func plan(device: String, operation: String, operands: [String]) throws -> DeviceCommand? {
        let operations = ["tree", "tap", "tap-id", "tap-label", "swipe", "drag", "type", "button"]
        guard operations.contains(operation) else { return nil }
        guard UUID(uuidString: device) != nil else {
            throw CommandFailure(description: "AXe operations require an explicit simulator UDID; 'booted' is ambiguous.")
        }
        func count(_ expected: Int) throws {
            guard operands.count == expected else {
                throw CommandFailure(description: "\(operation) expects \(expected) operand(s). See --help.")
            }
        }
        func coordinate(_ value: String) throws {
            guard let number = Double(value), number.isFinite, number >= 0 else {
                throw CommandFailure(description: "Coordinates must be finite, nonnegative numbers.")
            }
        }
        var arguments: [String]
        switch operation {
        case "tree":
            try count(0)
            arguments = ["describe-ui"]
        case "tap":
            try count(2)
            try operands.forEach(coordinate)
            arguments = ["tap", "-x", operands[0], "-y", operands[1]]
        case "tap-id", "tap-label":
            try count(1)
            guard !operands[0].isEmpty else { throw CommandFailure(description: "Selector must not be empty.") }
            // Equals prevents a selector beginning with '-' from being parsed as an option.
            arguments = ["tap", "\(operation == "tap-id" ? "--id" : "--label")=\(operands[0])"]
        case "swipe", "drag":
            try count(5)
            try operands.prefix(4).forEach(coordinate)
            guard let duration = Double(operands[4]), duration.isFinite, duration > 0 else {
                throw CommandFailure(description: "Duration must be a finite, positive number of seconds.")
            }
            arguments = [operation, "--start-x", operands[0], "--start-y", operands[1],
                         "--end-x", operands[2], "--end-y", operands[3], "--duration", operands[4]]
        case "type":
            try count(1)
            guard !operands[0].isEmpty, operands[0].utf8.allSatisfy({ (32...126).contains($0) || $0 == 10 || $0 == 9 }) else {
                throw CommandFailure(description: "AXe typing supports US keyboard text, tab, and newline only.")
            }
            // Options precede '--' so arbitrary text is passed as one literal operand.
            arguments = ["type", "--udid", device, "--", operands[0]]
            return DeviceCommand(executable: "/usr/bin/env", actionReceipt: true,
                                 arguments: ["axe"] + arguments, jsonOutput: false)
        case "button":
            try count(1)
            guard ["apple-pay", "home", "lock", "side-button", "siri", "play-pause", "volume-up", "volume-down"].contains(operands[0]) else {
                throw CommandFailure(description: "Unknown hardware button. See AXe button --help.")
            }
            arguments = ["button", operands[0]]
        default:
            return nil
        }
        return DeviceCommand(executable: "/usr/bin/env", actionReceipt: operation != "tree",
                             arguments: ["axe"] + arguments + ["--udid", device], jsonOutput: operation == "tree")
    }
}
