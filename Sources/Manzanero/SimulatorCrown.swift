import AppleDeviceBridge
import Foundation

/// Digital Crown rotation on a watchOS simulator (docs/other-families.md).
/// The simulator's dtuhidd takes `IndigoScrollEvent`s on its scroll service
/// with an integer delta; one unit moved a SwiftUI `digitalCrownRotation`
/// value by 0.005 at low sensitivity, so 200 units moved it by 1.
///
/// watchOS accelerates a fast-turning crown: five 20-unit events 16 ms apart
/// moved that value by 4.8 instead of 0.5, and 100 ms apart by 2.6; 200 ms
/// apart it moved exactly. Watch Settings' list moves one row per event of
/// 100 units or more, but two such events 250 or 500 ms apart moved it more
/// than four rows, and 800 or 1200 ms apart two rows. So a turn is sent as
/// few, large events 1 s apart: the result depends on the units and the
/// event count, not on how fast they were sent.
enum DigitalCrown {
    static let stepUnits = 1000
    static let intervalMilliseconds: UInt64 = 1000
    static let range = 1...10_000

    static let eventRange = 1...20

    static let usage = "crown takes a non-zero integer number of units, -10000...10000 (positive scrolls toward later content), and optionally --events 1...20 with at most 1000 and at least one unit per event; no input sent."

    /// The validated amount.
    static func units(_ operand: String) throws -> Int {
        guard let units = Int(operand), range.contains(abs(units)) else { throw CommandFailure.usage(usage) }
        return units
    }

    /// The validated event count: given, or the fewest events of at most `stepUnits`.
    static func events(_ operand: String?, units: Int) throws -> Int {
        let minimum = (abs(units) + stepUnits - 1) / stepUnits
        guard let operand else { return minimum }
        guard let events = Int(operand), eventRange.contains(events), events >= minimum, events <= abs(units) else {
            throw CommandFailure.usage(usage)
        }
        return events
    }

    /// `units` split over `events` integer deltas as evenly as possible, all with its sign.
    static func steps(_ units: Int, events: Int? = nil) -> [Double] {
        let count = events ?? (abs(units) + stepUnits - 1) / stepUnits
        let sign = units < 0 ? -1 : 1, base = abs(units) / count, extra = abs(units) % count
        return (0..<count).map { Double(sign * (base + ($0 < extra ? 1 : 0))) }
    }

    static func describe(_ units: Int, events: Int? = nil) -> [String: Any] {
        let steps = steps(units, events: events)
        return ["units": units, "events": steps.count, "unitsPerEvent": steps.map { Int($0) }, "intervalMilliseconds": intervalMilliseconds,
                "durationMilliseconds": UInt64(steps.count - 1) * intervalMilliseconds,
                "service": "com.apple.coredevice.feature.remote.hid.scroll",
                "message": "IndigoScrollEvent {point: {x: 0, y: delta, z: 0}, phase: 0, momentum: 0, target: 0}"]
    }

    static func rotate(_ uuid: String, _ deltas: [Double], _ interval: UInt64) throws {
        try DirectSimulatorInput.dispatch(uuid) { owner, error in
            deltas.withUnsafeBufferPointer {
                ADCSimulatorRotateCrown(owner, $0.baseAddress, $0.count, interval, { Task.isCancelled ? 1 : 0 }, &error, error.count)
            }
        }
    }

    /// Watch-only buttons for `button`, from DeviceKit's watch chromes
    /// (chrome.json). The side button is consumer usage 0x95; it opened
    /// Control Center. The Action button of an Apple Watch Ultra is the
    /// watch6 chrome's left-side-button, page 0xFF01 usage 0x200; it opened
    /// the Action button's setup on an Ultra simulator and did nothing on a
    /// Series 12, which has no such button.
    static let watchButtons: [String: (page: UInt64, usage: UInt64)] = ["side": (12, 0x95), "action": (0xFF01, 0x200)]

    /// `key` and `type` were dispatched on a watchOS 27.2 simulator and
    /// changed nothing, in Calculator and in the system text entry sheet of a
    /// SwiftUI text field (docs/other-families.md).
    static let keyboardRefusal = "Keyboard events do not reach watchOS: key and type were dispatched on a watchOS 27.2 simulator and changed nothing, even in the system text entry sheet. No input sent."

    static func checkFamily(_ input: SimulatorInput, info: SimulatorDeviceInfo) throws {
        if input.operation == "button", let name = input.operands.first, watchButtons[name] != nil, !info.isAppleWatch {
            throw CommandFailure.unsupported("button \(name) is an Apple Watch button; this simulator is \(info.family.isEmpty ? "of an unknown family" : "an \(info.family)"). No input sent.")
        }
        if info.isAppleWatch, ["key", "type"].contains(input.operation) { throw CommandFailure.unsupported(keyboardRefusal) }
        if input.operation == "crown", !info.isAppleWatch {
            throw CommandFailure.unsupported("crown turns an Apple Watch simulator's Digital Crown; this simulator is \(info.family.isEmpty ? "of an unknown family" : "an \(info.family)"). No input sent.")
        }
    }
}
