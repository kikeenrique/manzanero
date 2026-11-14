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
    let orientation = "rot0"
    var center: (x: Double, y: Double) { (bounds.x + bounds.width / 2, bounds.y + bounds.height / 2) }

    static func plan(device: String) -> DeviceCommand {
        DeviceCommand(arguments: ["devicectl", "device", "info", "displays", "--device", device,
            "--timeout", "10", "--quiet", "--json-output", "-"], jsonOutput: true)
    }

    init(_ data: Data) throws {
        func invalid() -> CommandFailure { CommandFailure(description: "Invalid, ambiguous or unsupported primary display; native AX centre selection requires portrait geometry.") }
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
        guard primary[0]["backlightState"] as? String == "activeOn" else {
            throw CommandFailure(description: "Primary display is off or its awake state is unknown. Wake/unlock the selected device before foreground AX inspection; no point query sent.")
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
        let scale = try number(display["pointScale"])
        guard scale > 0, scale <= 100 else { throw invalid() }
        let x = try number(rawBounds[0][0]) / scale, y = try number(rawBounds[0][1]) / scale
        let width = try number(rawBounds[1][0]) / scale, height = try number(rawBounds[1][1]) / scale
        guard width > 0, height > 0, [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { throw invalid() }
        bounds = Bounds(x: x, y: y, width: width, height: height)
        pointScale = scale
        displayId = id.int64Value
    }
}
