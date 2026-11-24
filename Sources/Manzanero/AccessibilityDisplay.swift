import CoreFoundation
import Foundation

/// The effective primary display from Apple's devicectl JSON, never inferred
/// from AX. `bounds` are the current interface's points, as the tree's frames
/// are: a phone turned a quarter has them the other way round.
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
    /// "rot0", "rot90", "rot180" or "rot270": the interface's turn from the
    /// display's native portrait.
    let orientation: String
    /// The same turn in degrees. Not printed.
    var rotation = 0
    /// The display's native portrait size in points. Not printed.
    private var nativeSize: (width: Double, height: Double)? = nil
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

    /// An interface point in the display's native portrait points, which a
    /// hit test takes (measured on a simulator in landscape; on a phone in
    /// landscape a wrong mapping would make the hit answer another element,
    /// which the press guard refuses). Unchanged in portrait.
    func native(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        guard rotation != 0, let nativeSize else { return (x, y) }
        let point = DirectTouchDisplay(rotation: rotation).portrait((x - bounds.x) / bounds.width, (y - bounds.y) / bounds.height)
        return (point.0 * nativeSize.width, point.1 * nativeSize.height)
    }

    static func == (left: Self, right: Self) -> Bool {
        left.bounds == right.bounds && left.displayId == right.displayId && left.pointScale == right.pointScale
            && left.orientation == right.orientation && left.external == right.external && left.focusDriven == right.focusDriven
    }

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
        func invalid() -> CommandFailure { CommandFailure(.transportFailed, "Invalid, ambiguous or unsupported primary display geometry for native AX selection.", inputSent: .none) }
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any], let displays = result["displays"] as? [[String: Any]],
              !displays.isEmpty, displays.count <= 16 else { throw invalid() }
        // The display the interface is on: the primary one, or an unfolded
        // iPhone Duo's inner display (`DeviceUIReadiness.interfaceDisplay`).
        guard let chosen = DeviceUIReadiness.interfaceDisplay(displays) else { throw invalid() }
        let primary = [chosen]
        // An external display (an Apple TV's television) has no backlight to read.
        external = DeviceUIReadiness.isExternal(primary[0])
        focusDriven = external
        guard primary[0]["backlightState"] as? String == "activeOn" || external else {
            throw CommandFailure(.displayOff, "Primary display is off or its awake state is unknown. Wake/unlock the selected device before foreground AX inspection; no point query sent.", inputSent: .none)
        }
        // A phone's display is native portrait; its interface may be turned.
        // An Apple TV's television is taken as it is.
        // An iPad mini (6th generation) has a panel mounted natively
        // landscape (`nativeOrientation: rot270`, bounds 2266 × 1488 while
        // held in portrait, 2026-11-24): the interface's turn from the
        // device's portrait is the sum, as touch takes it
        // (`DirectTouchDisplay`), and the panel's bounds are read the other
        // way round.
        let rotations = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
        guard primary.count == 1, let display = primary.first,
              let nativeTurn = rotations[display["nativeOrientation"] as? String ?? ""], nativeTurn == 0 || !external,
              let current = rotations[display["currentOrientation"] as? String ?? ""],
              case let turn = (nativeTurn + current) % 360, turn == 0 || !external,
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
        let panelWidth = try number(rawBounds[1][0]) / scale, panelHeight = try number(rawBounds[1][1]) / scale
        let sideways = nativeTurn == 90 || nativeTurn == 270
        let width = sideways ? panelHeight : panelWidth, height = sideways ? panelWidth : panelHeight
        guard width > 0, height > 0, [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { throw invalid() }
        if turn == 0 {
            bounds = Bounds(x: x, y: y, width: width, height: height)
            nativeSize = (width, height)
        } else {
            // A native-portrait display is the taller way whichever way
            // devicectl writes a turned display's bounds, which has not been
            // seen on a phone: take the short side as the native width.
            let short = min(width, height), long = max(width, height), quarter = turn == 90 || turn == 270
            guard x == 0, y == 0 else { throw invalid() }
            bounds = Bounds(x: 0, y: 0, width: quarter ? long : short, height: quarter ? short : long)
            nativeSize = (short, long)
        }
        pointScale = scale
        displayId = id.int64Value
        orientation = "rot\(turn)"
        rotation = turn
    }
}
