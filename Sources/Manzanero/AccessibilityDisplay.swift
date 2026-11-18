import CoreFoundation
import Foundation

/// The effective primary display from Apple's devicectl JSON. Centre selection
/// currently supports native portrait only, and never infers a display from AX.
struct AccessibilityDisplay: Equatable, Encodable {
    struct Bounds: Equatable, Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    let bounds: Bounds
    let displayId: Int64
    let pointScale: Double
    /// Always "rot0" from Apple's display JSON; a simulator reports what it assumes.
    let orientation: String
    /// An external primary display: an Apple TV's television. Not printed.
    /// There the foreground application is asked for by the frontmost
    /// request, because the centre hit test was refused (error 8) on an
    /// Apple TV 4K.
    let external: Bool
    /// An Apple TV, physical or simulated: driven by focus, with no pointer.
    /// Not printed. A hit test says nothing about whether an element can be
    /// activated there: on a tvOS simulator the system process answered it
    /// for a list row just inside the bottom edge.
    let focusDriven: Bool
    var center: (x: Double, y: Double) { (bounds.x + bounds.width / 2, bounds.y + bounds.height / 2) }

    private enum CodingKeys: String, CodingKey { case bounds, displayId, pointScale, orientation }

    /// A display described by another source, such as CoreSimulator's screen.
    init(bounds: Bounds, displayId: Int64, pointScale: Double, orientation: String, focusDriven: Bool = false) {
        external = false
        self.focusDriven = focusDriven
        self.bounds = bounds
        self.displayId = displayId
        self.pointScale = pointScale
        self.orientation = orientation
    }

    static func plan(device: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", device,
            "--timeout", "10", "--quiet", "--json-output", "-"], jsonOutput: true)
    }

    init(_ data: Data) throws {
        func invalid() -> CommandFailure { CommandFailure(.transportFailed, "Invalid, ambiguous or unsupported primary display; native AX centre selection requires portrait geometry.", inputSent: .none) }
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any], let displays = result["displays"] as? [[String: Any]],
              !displays.isEmpty, displays.count <= 16 else { throw invalid() }
        let primary = displays.filter {
            guard let value = $0["primary"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue
        }
        guard primary.count == 1 else { throw invalid() }
        // An external display (an Apple TV's television) has no backlight to read.
        external = DeviceUIReadiness.isExternal(primary[0])
        focusDriven = external
        guard primary[0]["backlightState"] as? String == "activeOn" || external else {
            throw CommandFailure(.displayOff, "Primary display is off or its awake state is unknown. Wake/unlock the selected device before foreground AX inspection; no point query sent.", inputSent: .none)
        }
        guard primary.count == 1, let display = primary.first,
              display["nativeOrientation"] as? String == "rot0", display["currentOrientation"] as? String == "rot0",
              let id = display["displayId"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: id.objCType)),
              id.doubleValue >= 0, id.doubleValue < Double(Int64.max),
              let rawBounds = display["bounds"] as? [[Any]], rawBounds.count == 2,
              rawBounds.allSatisfy({ $0.count == 2 }) else { throw invalid() }
        func number(_ value: Any?) throws -> Double {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, abs(value.doubleValue) <= 10_000_000 else { throw invalid() }
            return value.doubleValue
        }
        var scale = try number(display["pointScale"])
        guard scale > 0, scale <= 100 else { throw invalid() }
        // tvOS lays its interface out 1920 points wide whatever the
        // television's mode. An Apple TV 4K reported 3840 pixels at point
        // scale 1 while its tree's frames filled 1920 × 1080.
        if external, let pixels = try? number(rawBounds[1][0]), pixels >= 1920 { scale = pixels / 1920 }
        let x = try number(rawBounds[0][0]) / scale, y = try number(rawBounds[0][1]) / scale
        let width = try number(rawBounds[1][0]) / scale, height = try number(rawBounds[1][1]) / scale
        guard width > 0, height > 0, [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { throw invalid() }
        bounds = Bounds(x: x, y: y, width: width, height: height)
        pointScale = scale
        displayId = id.int64Value
        orientation = "rot0"
    }
}
