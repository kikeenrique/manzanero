import Foundation

/// Named touch sequences over `gesture`: the same input route, receipts and
/// guards, with the frames written here instead of by the caller.
/// Coordinates are normalized in the current interface.
///
/// System gestures (a swipe up from the bottom edge for Home, down from the
/// top for the Centres) are not here: on an iPhone simulator on 2026-11-21
/// such sequences reached the app in front, which scrolled, and never the
/// system (docs/gesture-sequences.md).
enum GesturePresets {
    /// Two taps 160 ms apart, each held 60 ms.
    static func doubleTap(x: Double, y: Double) throws -> String {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw CommandFailure.usage("double-tap takes normalized x and y in 0...1.")
        }
        let frames: [(Int, [(Double, Double)])] = [(0, [(x, y)]), (60, []), (160, [(x, y)]), (220, [])]
        let value: [String: Any] = ["frames": frames.map { frame in
            ["ms": frame.0, "touches": frame.1.map { ["id": 0, "x": $0.0, "y": $0.1] }] as [String: Any]
        }]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
