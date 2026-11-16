import Foundation

/// One display of a simulator as its dtdeviceinfod lists it. The `id` is the
/// screen ID `simctl io … --display=<id>` takes (measured on the iPhone Duo:
/// LCD is 1, LCD-1 is 3, as `simctl io screenshot` names them).
struct SimulatorDisplayEntry: Sendable, Equatable {
    let id: Int
    let name: String
    /// CoreDevice's device name, such as `primary` or `primary-1`.
    let deviceName: String
    let primary: Bool
    /// integrated, external, wireless or virtual.
    let kind: String
    let widthPixels: Double
    let heightPixels: Double
    let pointScale: Double
    let backlight: String
    let active: Bool
    let orientation: String

    /// A display whose current mode has a size; simctl can capture only these.
    /// A phone's TVOut, CarPlay and resizable displays report 0 × 0.
    var capturable: Bool { widthPixels > 0 && heightPixels > 0 }

    var json: [String: Any] {
        ["id": id, "name": name, "deviceName": deviceName, "primary": primary, "type": kind,
         "widthPixels": widthPixels, "heightPixels": heightPixels, "pointScale": pointScale,
         "widthPoints": pointScale > 0 ? widthPixels / pointScale : 0, "heightPoints": pointScale > 0 ? heightPixels / pointScale : 0,
         "backlightState": backlight, "active": active, "currentOrientation": orientation, "capturable": capturable]
    }
}

/// The display a simulator capture uses: the requested one, else the primary
/// one when the simulator has more than one capturable display.
struct SimulatorDisplaySelection: Sendable, Equatable {
    let display: SimulatorDisplayEntry
    /// The `--display=<id>` argument for simctl, or nil when the simulator has
    /// one capturable display and none was requested: the invocation is then
    /// exactly the one used before display selection existed.
    let argument: String?
}

/// Simulator displays: listing, and the display choice of `screenshot`,
/// `screen` and simulator `record`. Reading them sends no input.
enum SimulatorDisplays {
    static let usage = "--display takes a display name (such as LCD-1), a device name (such as primary-1) or a screen ID (such as 3); list them with displays --simulator <UUID>."

    /// The requested display operand, checked before any device contact.
    static func validated(_ display: String?, physical: Bool, operation: String) throws -> String? {
        guard let display else { return nil }
        guard !physical else {
            throw CommandFailure.unsupported("\(operation) --display applies to simulators only; a physical device has one capturable display. No device was contacted.")
        }
        guard (1...64).contains(display.utf8.count), !display.hasPrefix("-"), !display.contains("\0"),
              display.allSatisfy({ !$0.isNewline }) else {
            throw CommandFailure.usage("Invalid --display value. \(usage)")
        }
        return display
    }

    /// Parses the devicectl-shaped display information.
    static func parse(_ data: Data) throws -> [SimulatorDisplayEntry] {
        guard data.count <= 1_048_576, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]], displays.count <= 64 else {
            throw CommandFailure(.transportFailed, "Cannot read the simulator's display information; nothing was sent.", inputSent: .none)
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        return try displays.map { display in
            guard let id = (display["displayId"] as? NSNumber)?.intValue, let name = display["name"] as? String else {
                throw CommandFailure(.transportFailed, "The simulator's display information lists a display without an ID or name; nothing was sent.", inputSent: .none)
            }
            // The current mode's size: an Apple TV's TVOut reports a 0 × 0
            // nativeSize with a 1920 × 1080 current mode, and is captured.
            let size = (display["currentMode"] as? [String: Any])?["size"] as? [Any] ?? display["nativeSize"] as? [Any] ?? []
            let kind = (display["type"] as? [String: Any])?.keys.sorted().first ?? "unknown"
            return SimulatorDisplayEntry(id: id, name: name, deviceName: display["deviceName"] as? String ?? "",
                                         primary: display["primary"] as? Bool == true, kind: kind,
                                         widthPixels: size.count == 2 ? number(size[0]) ?? 0 : 0,
                                         heightPixels: size.count == 2 ? number(size[1]) ?? 0 : 0,
                                         pointScale: number(display["pointScale"]) ?? 0,
                                         backlight: display["backlightState"] as? String ?? "unknown",
                                         active: display["active"] as? Bool == true,
                                         orientation: display["currentOrientation"] as? String ?? "unknown")
        }
    }

    /// The capture display. A request matches one display by screen ID, name
    /// or device name (names ignore case); an unknown or uncapturable display
    /// is refused. Without a request the primary display is used, and the
    /// simctl argument is omitted when only one display can be captured.
    static func select(_ requested: String?, in displays: [SimulatorDisplayEntry]) throws -> SimulatorDisplaySelection {
        let capturable = displays.filter(\.capturable)
        let available = capturable.map { "\($0.name) (id \($0.id)\($0.primary ? ", primary" : ""))" }.joined(separator: ", ")
        guard let requested else {
            if capturable.count == 1 { return SimulatorDisplaySelection(display: capturable[0], argument: nil) }
            let primaries = capturable.filter(\.primary)
            guard primaries.count == 1 else {
                throw CommandFailure(.targetUnresolved, "The simulator has no single capturable primary display; choose one with --display: \(available.isEmpty ? "none" : available). Nothing was captured.", inputSent: .none)
            }
            return SimulatorDisplaySelection(display: primaries[0], argument: "--display=\(primaries[0].id)")
        }
        let matches = displays.filter {
            String($0.id) == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame
                || (!$0.deviceName.isEmpty && $0.deviceName.caseInsensitiveCompare(requested) == .orderedSame)
        }
        guard matches.count == 1, let match = matches.first else {
            throw CommandFailure(.targetUnresolved, "\(matches.isEmpty ? "Unknown" : "Ambiguous") display '\(requested)'. Capturable displays: \(available.isEmpty ? "none" : available). Nothing was captured.", inputSent: .none)
        }
        guard match.capturable else {
            throw CommandFailure(.targetUnresolved, "Display '\(requested)' (\(match.name), id \(match.id)) has no framebuffer to capture. Capturable displays: \(available.isEmpty ? "none" : available). Nothing was captured.", inputSent: .none)
        }
        return SimulatorDisplaySelection(display: match, argument: "--display=\(match.id)")
    }

    static func read(_ uuid: String, environment: SimulatorEnvironment) throws -> [SimulatorDisplayEntry] {
        try parse(environment.displayInfo(uuid))
    }

    /// A simctl io invocation with the display argument before its path.
    static func arguments(_ base: [String], selection: SimulatorDisplaySelection?) -> [String] {
        guard let argument = selection?.argument, !base.isEmpty else { return base }
        return base.dropLast() + [argument, base[base.count - 1]]
    }

    static let resolution = "Read the simulator's display information (dtdeviceinfod) first; with one capturable display the arguments stay as shown, with several --display=<screen ID> of the requested display (else the primary one) goes before the path. An unknown or uncapturable display is refused before capture."
}

/// `displays` and simulator `screenshot`: simctl capture with a display choice.
enum SimulatorDisplayRequest: Sendable, Equatable {
    case list(device: String)
    case screenshot(device: String, output: String, display: String?)

    var device: String {
        switch self {
        case .list(let device), .screenshot(let device, _, _): device
        }
    }

    var operation: String {
        switch self {
        case .list: "displays"
        case .screenshot: "screenshot"
        }
    }

    static func list(_ target: Target) throws -> Self {
        guard target.platform == .simulator else {
            throw CommandFailure.unsupported("displays lists a simulator's displays; for a physical device's display state use readiness. No device was contacted.")
        }
        return .list(device: try SimulatorDevice.requireUUID(target.identifier, operation: "displays"))
    }

    static func screenshot(_ target: Target, output: String, display: String?) throws -> Self {
        // The simctl plan checks the operands exactly as before.
        _ = try DeviceCommand.plan(physical: false, device: target.identifier, operation: "screenshot", operands: [output])
        return .screenshot(device: try SimulatorDevice.requireUUID(target.identifier, operation: "screenshot"), output: output,
                           display: try SimulatorDisplays.validated(display, physical: false, operation: "screenshot"))
    }

    func plan() throws -> [String: Any] {
        switch self {
        case .list(let device):
            return ["platform": "simulator", "device": device, "operation": "displays", "readOnly": true,
                    "execution": "One read-only display-information request to the simulator's dtdeviceinfod (com.apple.coredevice.feature.getdisplayinfo) over host XPC; no input, no simctl."]
        case .screenshot(let device, let output, let display):
            let command = try DeviceCommand.plan(physical: false, device: device, operation: "screenshot", operands: [output])
            return ["executable": command.executable, "arguments": command.arguments,
                    "display": ["requested": display.map { $0 as Any } ?? NSNull(), "resolution": SimulatorDisplays.resolution]]
        }
    }

    func execute(environment: SimulatorEnvironment, run: (DeviceCommand) throws -> Data) throws -> Data {
        let displays = try SimulatorDisplays.read(device, environment: environment)
        switch self {
        case .list(let device):
            let selection = try? SimulatorDisplays.select(nil, in: displays)
            return try JSONSerialization.data(withJSONObject: [
                "platform": "simulator", "device": device, "displays": displays.map(\.json),
                "defaultCaptureDisplay": selection.map { $0.display.id as Any } ?? NSNull(),
                "note": "id is the screen ID that --display accepts. Trees, waits, actions and touch follow the display marked primary."],
                options: [.prettyPrinted, .sortedKeys])
        case .screenshot(let device, let output, let display):
            let selection = try SimulatorDisplays.select(display, in: displays)
            var command = try DeviceCommand.plan(physical: false, device: device, operation: "screenshot", operands: [output])
            command.arguments = SimulatorDisplays.arguments(command.arguments, selection: selection)
            return try run(command)
        }
    }
}
