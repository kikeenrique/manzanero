import Foundation

/// Project-owned mainTouchscreen report encoder for direct digitizer schedules.
/// Contact slots retain identity through release.
enum NativeTouchFrames {
    static func report(positions: [[Int]], active: Set<Int>) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 9; bytes[1] = UInt8(positions.count); bytes[2] = 5; bytes[40] = 2
        for (id, point) in positions.enumerated() {
            let offset = 3 + id * 5
            bytes[offset] = UInt8(id) | (active.contains(id) ? 0xc0 : 0)
            for axis in 0..<2 {
                bytes[offset + 1 + axis * 2] = UInt8(point[axis] & 255)
                bytes[offset + 2 + axis * 2] = UInt8(point[axis] >> 8)
            }
        }
        return bytes
    }
}
