import Foundation

/// Operand validation shared by native physical touch, multitouch, button and
/// key input. Coordinates are normalized 0...1 with the origin at the top left.
enum PhysicalInputOperands {
    static func validate(_ operation: String, _ operands: [String]) throws {
        func require(_ count: Int) throws {
            guard operands.count == count else {
                throw CommandFailure(description: "\(operation) expects \(count) operands. See --help.")
            }
        }
        // The 16-bit quantization keeps the pinch distinctness check below
        // identical to the digitizer's coordinate resolution.
        func coordinate(_ value: String) throws -> Int {
            guard let number = Double(value), number.isFinite, (0...1).contains(number) else {
                throw CommandFailure(description: "Physical input coordinates must be normalized numbers from 0 to 1.")
            }
            return Int((number * 65535).rounded())
        }
        switch operation {
        case "tap":
            try require(2)
            _ = try operands.map(coordinate)
        case "multi-tap":
            guard (4...10).contains(operands.count), operands.count.isMultiple(of: 2) else {
                throw CommandFailure(description: "multi-tap expects two to five pairs of normalized coordinates.")
            }
            _ = try operands.map(coordinate)
        case "drag", "swipe":
            try require(5)
            guard let duration = Double(operands[4]), duration.isFinite, (0.03...10).contains(duration) else {
                throw CommandFailure(description: "Physical drag/swipe duration must be 0.03...10 seconds.")
            }
            _ = try operands.prefix(4).map(coordinate)
        case "multi-drag":
            guard (9...21).contains(operands.count), (operands.count - 1).isMultiple(of: 4),
                  let duration = Double(operands[0]), duration.isFinite, (0.03...10).contains(duration) else {
                throw CommandFailure(description: "Usage: multi-drag <seconds: 0.03...10> <start-x> <start-y> <end-x> <end-y> ... (two to five contact paths)")
            }
            _ = try operands.dropFirst().map(coordinate)
        case "pinch":
            try require(5)
            let values = try operands.map { value -> Double in
                guard let number = Double(value), number.isFinite else { throw CommandFailure(description: "Pinch operands must be finite numbers.") }
                return number
            }
            let (cx, cy, start, end, duration) = (values[0], values[1], values[2], values[3], values[4])
            guard start > 0, end > 0, start != end, (0.03...10).contains(duration) else {
                throw CommandFailure(description: "Pinch requires different positive start/end spans and 0.03...10 seconds. Spans are fractions of screen width.")
            }
            let points = [cx - start / 2, cy, cx - end / 2, cy, cx + start / 2, cy, cx + end / 2, cy]
            let converted = try points.map { try coordinate(String($0)) }
            guard converted[0] != converted[4], converted[2] != converted[6], converted[0] != converted[2], converted[4] != converted[6] else {
                throw CommandFailure(description: "Pinch spans must remain distinct after 16-bit coordinate conversion.")
            }
        case "button":
            try require(1)
            guard ["home", "lock", "volume-up", "volume-down"].contains(operands[0]) else {
                throw CommandFailure(description: "Supported physical buttons: home, lock, volume-up, volume-down.")
            }
        case "key":
            try require(1)
            guard ["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"].contains(operands[0]) else {
                throw CommandFailure(description: "Unknown physical keyboard key. See --help.")
            }
        default:
            throw CommandFailure(description: "Unsupported native input operation.")
        }
    }
}
