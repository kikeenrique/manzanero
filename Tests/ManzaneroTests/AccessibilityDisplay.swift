import Foundation
import Testing
@testable import Manzanero

struct AccessibilityDisplayTests {
    static func data(scale: Any = 3, orientation: String = "rot0", primary: Any = true,
                     bounds: Any = [[0, 0], [1125, 2436]], id: Any = 1, duplicates: Bool = false,
                     outcome: String = "success", backlight: String = "activeOn") throws -> Data {
        let display: [String: Any] = ["primary": primary, "displayId": id, "pointScale": scale,
            "bounds": bounds, "currentOrientation": orientation, "nativeOrientation": "rot0", "backlightState": backlight]
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": outcome],
            "result": ["displays": duplicates ? [display, display] : [display]]])
    }

    @Test func effectiveBoundsScaleAndIdentityAreValidated() throws {
        let display = try AccessibilityDisplay(Self.data())
        #expect(display.center.x == 187.5 && display.center.y == 406)
        #expect(display.bounds.width == 375 && display.bounds.height == 812)
        #expect(display.displayId == 1 && display.pointScale == 3)
        let plan = AccessibilityDisplay.plan(device: "selected-UUID")
        #expect(plan.arguments == ["devicectl", "device", "info", "displays", "--device", "selected-UUID",
            "--timeout", "10", "--quiet", "--json-output", "-"])
        for data in [try Self.data(scale: 0), try Self.data(scale: true), try Self.data(scale: 0.00000001),
                     try Self.data(orientation: "rot45"), try Self.data(primary: 1),
                     try Self.data(bounds: [[0, 0], [0, 2436]]), try Self.data(bounds: [[0, true], [1125, 2436]]),
                     try Self.data(bounds: [[0], [1125, 2436]]), try Self.data(id: true), try Self.data(id: 1.5),
                     try Self.data(duplicates: true), try Self.data(outcome: "failure"), try Self.data(backlight: "off"),
                     try Self.data(backlight: "unknown"), Data(count: 1_048_577)] {
            #expect(throws: (any Error).self) { try AccessibilityDisplay(data) }
        }
    }

    /// A turned phone: interface bounds the other way round, and hit points
    /// mapped into native portrait points as touch maps them
    /// (`DirectTouchDisplay.portrait`). The same whichever way devicectl
    /// writes the bounds of a turned display.
    @Test(arguments: [[[0, 0], [1125, 2436]], [[0, 0], [2436, 1125]]])
    func aTurnedPhoneMapsInterfacePointsToNativePortrait(_ bounds: [[Int]]) throws {
        let right = try AccessibilityDisplay(Self.data(orientation: "rot90", bounds: bounds))
        #expect(right.orientation == "rot90" && right.bounds.width == 812 && right.bounds.height == 375)
        #expect(right.center.x == 406 && right.center.y == 187.5)
        let centre = right.native(406, 187.5)
        #expect(centre.x == 187.5 && centre.y == 406)
        // rot90: interface (x, y) normalized → native (y, 1 - x).
        let corner = right.native(0, 0)
        #expect(corner.x == 0 && corner.y == 812)
        let left = try AccessibilityDisplay(Self.data(orientation: "rot270", bounds: bounds))
        let other = left.native(0, 0)
        #expect(other.x == 375 && other.y == 0)
        let upside = try AccessibilityDisplay(Self.data(orientation: "rot180", bounds: bounds))
        #expect(upside.bounds.width == 375 && upside.native(0, 0).x == 375 && upside.native(0, 0).y == 812)
        // A turn changes the display, so a recheck after it refuses to go on.
        #expect(right != (try AccessibilityDisplay(Self.data())))
    }

    @Test func portraitHitPointsAreUnchanged() throws {
        let display = try AccessibilityDisplay(Self.data())
        #expect(display.native(10, 20).x == 10 && display.native(10, 20).y == 20)
    }
}
