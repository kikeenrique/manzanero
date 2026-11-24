import Foundation
import Testing
@testable import Manzanero

/// `crown` and `type` on a physical Apple Watch: the crown's steps go to the
/// watch's own scroll service only for a watch, and typing taps the keys a
/// fresh tree shows, never an app's look-alike buttons.
struct PhysicalWatchTests {
    static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    static func details(type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": "enabled"], "hardware": ["deviceType": type]]]])
    }

    @Test func theCrownTurnsAWatchAndNothingElse() throws {
        var turns: [DirectPhysicalCrown.Turn] = []
        let input = try CoreDeviceInput.validated(device: Self.uuid, operation: "crown", operands: ["300", "3"])
        let data = try DirectPhysicalCrown.execute(input, query: { _ in try Self.details(type: "appleWatch") }, send: { turns.append($0) })
        #expect(turns.count == 1 && turns[0].deltas == [100, 100, 100] && turns[0].intervalNanoseconds == 1_000_000_000)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["status"] as? String == "dispatched" && (result["crown"] as? [String: Any])?["events"] as? Int == 3)
        let phone = #expect(throws: CommandFailure.self) {
            _ = try DirectPhysicalCrown.execute(input, query: { _ in try Self.details(type: "iPhone") }, send: { turns.append($0) })
        }
        #expect(phone?.code == .unsupportedOperation && turns.count == 1)
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.validated(device: Self.uuid, operation: "crown", operands: ["0"]) }
    }

    /// A tree result with the given nodes on a 211 × 257 display.
    static func tree(_ nodes: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["display": ["bounds": ["x": 0, "y": 0, "width": 211, "height": 257]], "nodes": nodes])
    }

    static func key(_ label: String, x: Double, identifier: String? = nil, className: String = WatchKeyboard.keyClass) -> [String: Any] {
        var node: [String: Any] = ["label": label, "visible": true, "frame": ["x": x, "y": 200, "width": 10, "height": 20],
                                   "nativeAttributes": ["5003": className]]
        if let identifier { node["identifier"] = identifier }
        return node
    }

    @Test func typingTapsTheKeysAFreshTreeShowsThenDone() async throws {
        let keyboard = try Self.tree([Self.key("h", x: 10), Self.key("i", x: 30),
                                      Self.key("OK", x: 180, className: WatchKeyboard.barButtonClass)])
        var taps: [[String]] = []
        let input = CoreDeviceInput(device: Self.uuid, operation: "type", operands: ["hi", "us"])
        let data = try await PhysicalWatchTyping.execute(input, query: { _ in Data() }, readTree: { _ in keyboard },
            tap: { taps.append($0.operands); return Data() }, pause: { _ in })
        #expect(taps.count == 3)
        let xs: [Double] = taps.compactMap { Double($0[0]) }
        let expected: [Double] = [15.0 / 211, 35.0 / 211, 185.0 / 211]
        #expect(xs.count == 3)
        for (x, wanted) in zip(xs, expected) { #expect(abs(x - wanted) < 0.0001) }
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["keyTaps"] as? Int == 3 && result["doneTapped"] as? Bool == true && result["route"] as? String == "watch-on-screen-keyboard")
    }

    @Test func anAppsButtonLabelledLikeAKeyIsNotAKeyboard() async throws {
        // The probe's own button A: one letter, but not of the keyboard's class.
        let probe = try Self.tree([Self.key("A", x: 40, className: "SwiftUI.Button")])
        var taps = 0, reads = 0
        let input = CoreDeviceInput(device: Self.uuid, operation: "type", operands: ["A", "us"])
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await PhysicalWatchTyping.execute(input, query: { _ in Data() }, readTree: { _ in reads += 1; return probe },
                tap: { _ in taps += 1; return Data() }, pause: { _ in })
        }
        #expect(failure?.code == .targetUnresolved && failure?.inputSent == CommandFailure.InputSent.none)
        #expect(taps == 0 && reads == WatchKeyboard.openingReads + 1)
    }
}
