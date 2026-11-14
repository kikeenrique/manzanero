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
                     try Self.data(orientation: "rot90"), try Self.data(primary: 1),
                     try Self.data(bounds: [[0, 0], [0, 2436]]), try Self.data(bounds: [[0, true], [1125, 2436]]),
                     try Self.data(bounds: [[0], [1125, 2436]]), try Self.data(id: true), try Self.data(id: 1.5),
                     try Self.data(duplicates: true), try Self.data(outcome: "failure"), try Self.data(backlight: "off"),
                     try Self.data(backlight: "unknown"), Data(count: 1_048_577)] {
            #expect(throws: (any Error).self) { try AccessibilityDisplay(data) }
        }
    }
}
