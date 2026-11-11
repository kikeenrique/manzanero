import Foundation

/// Optional idevice bridge; private protocols stay outside the Swift command surface.
enum PhysicalInteraction {
    static func plan(device: String, operation: String, operands: [String]) throws -> DeviceCommand? {
        guard ["hid-info", "ax-snapshot", "logs", "tap", "multi-tap", "drag", "swipe", "button", "key", "type"].contains(operation) else { return nil }
        func require(_ count: Int) throws {
            guard operands.count == count else {
                throw CommandFailure(description: "\(operation) expects \(count) operands. See --help.")
            }
        }
        func coordinate(_ value: String) throws -> String {
            guard let number = Double(value), number.isFinite, (0...1).contains(number) else {
                throw CommandFailure(description: "Physical input coordinates must be normalized numbers from 0 to 1.")
            }
            return String(Int((number * 65535).rounded()))
        }
        let arguments: [String]
        switch operation {
        case "type":
            try require(1)
            let bytes = operands[0].utf8
            guard (1...512).contains(bytes.count), bytes.allSatisfy({ (32...126).contains($0) || $0 == 9 || $0 == 10 }) else {
                throw CommandFailure(description: "Physical typing requires 1...512 printable US-layout ASCII characters, tab, or LF newline.")
            }
            arguments = [operation, operands[0]]
        case "hid-info", "ax-snapshot":
            try require(0)
            arguments = [operation]
        case "logs":
            guard (1...2).contains(operands.count), let seconds = UInt32(operands[0]), (1...30).contains(seconds) else {
                throw CommandFailure(description: "Usage: logs <seconds: 1...30> [positive-pid]")
            }
            var values = [operation, String(seconds)]
            if operands.count == 2 {
                guard let pid = UInt32(operands[1]), pid > 0, pid <= Int32.max else {
                    throw CommandFailure(description: "Log filter requires a positive PID.")
                }
                values.append(String(pid))
            }
            arguments = values
        case "tap":
            try require(2)
            arguments = [operation] + (try operands.map(coordinate))
        case "multi-tap":
            guard (4...10).contains(operands.count), operands.count.isMultiple(of: 2) else {
                throw CommandFailure(description: "multi-tap expects two to five pairs of normalized coordinates.")
            }
            arguments = [operation] + (try operands.map(coordinate))
        case "drag", "swipe":
            try require(5)
            guard let duration = Double(operands[4]), duration.isFinite, (0.03...10).contains(duration) else {
                throw CommandFailure(description: "Physical drag/swipe duration must be 0.03...10 seconds.")
            }
            arguments = ["drag"] + (try operands.prefix(4).map(coordinate)) + [String(Int((duration * 1000).rounded()))]
        case "button":
            try require(1)
            guard ["home", "lock", "volume-up", "volume-down"].contains(operands[0]) else {
                throw CommandFailure(description: "Supported physical buttons: home, lock, volume-up, volume-down.")
            }
            arguments = [operation, operands[0]]
        case "key":
            try require(1)
            guard ["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"].contains(operands[0]) else {
                throw CommandFailure(description: "Unknown physical keyboard key. See --help.")
            }
            arguments = [operation, operands[0]]
        default:
            return nil
        }
        return DeviceCommand(executable: "/usr/bin/env", arguments: ["appledevices-idevice", device] + arguments, jsonOutput: true)
    }
}
