import Foundation

/// mainTouchscreen reports for the optional native helper. Matches the pinned
/// idevice report layout; all contacts keep their identity through release.
struct NativeTouchFrames {
    let milliseconds: Int
    let reports: [[UInt8]]

    init(device: String, operation: String, operands: [String]) throws {
        guard let plan = try PhysicalInteraction.plan(device: device, operation: operation, operands: operands),
              plan.arguments.count >= 12, plan.arguments[2] == "multi-drag",
              let duration = Int(plan.arguments[3]) else {
            throw CommandFailure(description: "Cannot plan native multitouch frames.")
        }
        milliseconds = duration
        let coordinates = try plan.arguments.dropFirst(4).map { value -> Int in
            guard let value = Int(value) else { throw CommandFailure(description: "Invalid native contact coordinate.") }
            return value
        }
        let count = coordinates.count / 4
        reports = (0...31).map { frame in
            let step = min(frame, 30)
            var bytes = [UInt8](repeating: 0, count: 58)
            bytes[0] = 9; bytes[1] = UInt8(count); bytes[2] = 5; bytes[40] = 2
            for id in 0..<count {
                let path = id * 4, offset = 3 + id * 5
                bytes[offset] = UInt8(id) | (frame == 31 ? 0 : 0xc0)
                for axis in 0..<2 {
                    let start = coordinates[path + axis], end = coordinates[path + axis + 2]
                    let position = start + (end - start) * step / 30
                    bytes[offset + 1 + axis * 2] = UInt8(position & 255)
                    bytes[offset + 2 + axis * 2] = UInt8(position >> 8)
                }
            }
            return bytes
        }
    }

    var arguments: [String] {
        [String(milliseconds)] + reports.map { $0.map { String(format: "%02x", $0) }.joined() }
    }
}
