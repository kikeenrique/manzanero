import Foundation
import Testing
@testable import Manzanero

/// A physical iPhone Duo, unfolded, as `devicectl device info displays`
/// reported it on 2026-11-25: the outer `LCD` keeps the primary flag and is
/// off, while the interface is on the inner `LCD-1`, native portrait and
/// turned `rot90` (the same geometry as the Duo simulator's).
struct DuoPhysicalDisplayTests {
    static func displays(outer: String = "off", inner: String = "activeOn", innerIntegrated: Bool = true) throws -> Data {
        let outerDisplay: [String: Any] = ["active": outer == "activeOn", "backlightState": outer, "bounds": [[0, 0], [1398, 2034]],
            "currentOrientation": "rot0", "displayId": 1, "name": "LCD", "nativeOrientation": "rot0", "nativeSize": [1398, 2034],
            "pointScale": 3, "primary": true, "type": ["integrated": [String: Any]()]]
        let innerDisplay: [String: Any] = ["active": inner == "activeOn", "backlightState": inner, "bounds": [[0, 0], [2007, 2853]],
            "currentOrientation": "rot90", "displayId": 2, "name": "LCD-1", "nativeOrientation": "rot0", "nativeSize": [1878, 2670],
            "pointScale": 3, "primary": false, "uniqueId": "123-456-789", "type": innerIntegrated ? ["integrated": [String: Any]()] : ["external": [String: Any]()]]
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": [
            "backlightState": "activeOn", "displays": [outerDisplay, innerDisplay],
            "orientation": ["currentDeviceNonFlatOrientation": "landscapeRight", "currentDeviceOrientation": "landscapeRight"]]])
    }

    static func result(_ data: Data) throws -> [String: Any] {
        try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])
    }

    @Test func unfoldedTheInterfaceIsTheInnerDisplay() throws {
        let data = try Self.displays()
        #expect(DeviceUIReadiness.displayPower(try Self.result(data)) == "on")
        let ax = try AccessibilityDisplay(data)
        #expect(ax.displayId == 2 && ax.hitDisplayId == 2 && ax.orientation == "rot90")
        #expect(ax.bounds.width == 951 && ax.bounds.height == 669)
        let touch = try DirectTouchDisplay(data)
        #expect(touch.id == 2 && touch.rotation == 90)
        #expect(DeviceUIReadiness.interfaceUniqueId(data) == "123-456-789")
        #expect(DeviceUIReadiness.interfaceUniqueId(try Self.displays(outer: "activeOn", inner: "off")) == nil)
        #expect(DeviceUIReadiness.interfaceUniqueId(nil) == nil)
    }

    @Test func foldedTheInterfaceIsThePrimaryDisplay() throws {
        let data = try Self.displays(outer: "activeOn", inner: "off")
        #expect(DeviceUIReadiness.displayPower(try Self.result(data)) == "on")
        #expect(try AccessibilityDisplay(data).displayId == 1 && AccessibilityDisplay(data).hitDisplayId == 0)
        #expect(try DirectTouchDisplay(data).id == 1)
    }

    /// Both off (asleep), both awake (for a moment while folding) or a
    /// non-integrated other display: the primary display decides, as before.
    @Test func otherwiseThePrimaryDisplayDecides() throws {
        let asleep = try Self.displays(outer: "off", inner: "off")
        #expect(DeviceUIReadiness.displayPower(try Self.result(asleep)) == "off")
        #expect(throws: (any Error).self) { try AccessibilityDisplay(asleep) }
        #expect(throws: (any Error).self) { try DirectTouchDisplay(asleep) }
        #expect(try AccessibilityDisplay(Self.displays(outer: "activeOn", inner: "activeOn")).displayId == 1)
        let external = try Self.displays(innerIntegrated: false)
        #expect(DeviceUIReadiness.displayPower(try Self.result(external)) == "off")
    }

    /// A display asked for by ID is taken as asked, awake or not.
    @Test func aRequestedDisplayIsNotReplaced() throws {
        #expect(throws: (any Error).self) { try DirectTouchDisplay(Self.displays(), displayId: 1) }
        #expect(try DirectTouchDisplay(Self.displays(), displayId: 2).id == 2)
    }
}
