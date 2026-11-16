import AppleDeviceBridge
import Foundation

/// One simulator as CoreSimulator reports it: state and portrait main-screen
/// geometry. Reading it sends nothing to the simulator.
struct SimulatorDeviceInfo: Sendable, Equatable {
    let uuid: String
    var name = ""
    let state: String
    let widthPoints: Double
    let heightPoints: Double
    let scale: Double
    /// CoreSimulator's product family ("iPhone", "iPad", "Apple TV", "Apple Watch"); empty when unknown.
    var family = ""

    var booted: Bool { state == "Booted" }
    var isAppleTV: Bool { family == "Apple TV" }
    var isAppleWatch: Bool { family == "Apple Watch" }

    /// The native (portrait) screen. Commands that read the display
    /// information replace it with `SimulatorDisplay.screenJSON`.
    var screenJSON: [String: Any] {
        ["widthPoints": widthPoints, "heightPoints": heightPoints, "scale": scale, "orientation": SimulatorDevice.orientation]
    }
}

/// Simulator lookup through CoreSimulator in process. Simulator commands
/// address a simulator by its UUID only: CoreSimulator's device set is keyed by
/// UUID, and names or `booted` can match several simulators.
enum SimulatorDevice {
    /// Buttons, keys and typing do not depend on orientation and do not read it.
    static let orientation = "not-read"

    static func requireUUID(_ device: String, operation: String) throws -> String {
        guard let uuid = UUID(uuidString: device) else {
            throw CommandFailure.usage("Simulator \(operation) requires the simulator's UUID (see devices --simulators); names and 'booted' are not accepted.")
        }
        return uuid.uuidString
    }

    /// `DEVELOPER_DIR` when set, else the active developer directory.
    static func developerDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   run: ([String], String) throws -> Data = { try ToolRunner().run($0, executable: $1, timeout: 10) }) throws -> String {
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty { return value }
        let output = try run(["-p"], "/usr/bin/xcode-select")
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw CommandFailure(.hostRequirement, "Cannot determine the active Xcode developer directory; nothing was sent to the simulator.", inputSent: .none)
        }
        return path
    }

    /// Reads one simulator's state and geometry; any state is returned.
    static func lookup(_ uuid: String) throws -> SimulatorDeviceInfo {
        let developer = try developerDirectory()
        var info = ADCSimulatorInfo()
        var owner: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCOpenSimulatorDevice(developer, uuid, &info, &owner, &error, error.count)
        defer { ADCCloseSimulatorDevice(owner) }
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if status == ADCSimulatorNotFound {
            throw CommandFailure(.targetUnresolved, "\(message) Use the UUID from devices --simulators; nothing was sent.", inputSent: .none)
        }
        guard status == 0 else { throw CommandFailure(.hostRequirement, message, inputSent: .none) }
        return info.swift(uuid: uuid)
    }

    /// The lookup every simulator operation runs first: an unbooted simulator
    /// is refused before any connection, and is never booted implicitly.
    static func requireBooted(_ uuid: String, operation: String,
                              lookup: (String) throws -> SimulatorDeviceInfo = lookup) throws -> SimulatorDeviceInfo {
        let info = try lookup(uuid)
        guard info.booted else {
            throw CommandFailure(.deviceNotReady, "Simulator \(uuid) is \(info.state.isEmpty ? "not booted" : info.state), not Booted; \(operation) needs a booted simulator. Boot it first (manzanero boot --simulator \(uuid)); nothing was sent.", inputSent: .none)
        }
        return info
    }
}

/// The simulator's primary display as its dtdeviceinfod reports it, in the
/// devicectl JSON shape: orientation, awake state and the unique identifier
/// that names its Universal HID touchscreen. Reading it sends no input.
///
/// Measured on iPhone and iPad simulators (docs/simulator-input.md): the
/// digitizer and Universal HID take portrait-native coordinates, as on a
/// phone, while accessibility frames and the app's touches are in the current
/// interface. So touch maps current-interface coordinates with the physical
/// `DirectTouchDisplay.portrait`, and accessibility uses the interface size.
struct SimulatorDisplay: Equatable {
    /// Clockwise rotation of the interface from the native orientation, as
    /// the physical parser computes it: (native + current) mod 360.
    let rotation: Int
    /// The unique identifier of the display the interface is on; it names
    /// that display's Universal HID touchscreen.
    let displayUUID: String
    let backlight: String
    /// The interface display, when it is not the primary one: an unfolded
    /// iPhone Duo keeps the primary flag on its outer display (LCD) while the
    /// interface is on the inner one (LCD-1). Nil means the primary display,
    /// whose geometry comes from CoreSimulator as before.
    let secondary: Secondary?
    private let data: Data

    struct Secondary: Equatable {
        let id: Int
        let name: String
        let deviceName: String
        /// Native (unrotated) size in points.
        let widthPoints: Double
        let heightPoints: Double
        let scale: Double
    }

    /// Whether the interface is on the display marked primary.
    var isPrimary: Bool { secondary == nil }

    init(_ data: Data) throws {
        let rotations = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
        guard data.count <= 1_048_576, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]] else {
            throw CommandFailure(.transportFailed, "Cannot read the simulator's display information; nothing was sent.", inputSent: .none)
        }
        let primaries = displays.filter { ($0["primary"] as? Bool) == true }
        guard primaries.count == 1, let primary = primaries.first else {
            throw CommandFailure(.transportFailed, "The simulator's display information has no single primary display with a known orientation and identifier; nothing was sent.", inputSent: .none)
        }
        // Another display only when the primary one is not awake and exactly
        // one other integrated display with a framebuffer is: an unfolded
        // Duo's LCD-1. A display without a framebuffer (Resizable) never is.
        func framebuffer(_ display: [String: Any]) -> Bool {
            let size = (display["nativeSize"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            return size.count == 2 && size.allSatisfy { $0.isFinite && $0 > 0 }
        }
        let others = primary["backlightState"] as? String == "activeOn" ? [] : displays.filter {
            ($0["primary"] as? Bool) != true && ($0["type"] as? [String: Any])?["integrated"] != nil
                && $0["backlightState"] as? String == "activeOn" && framebuffer($0)
        }
        let active = others.count == 1 ? others[0] : nil
        let chosen = active ?? primary
        guard let native = rotations[chosen["nativeOrientation"] as? String ?? ""],
              let current = rotations[chosen["currentOrientation"] as? String ?? ""],
              let unique = chosen["uniqueId"] as? String, let identifier = UUID(uuidString: unique) else {
            throw CommandFailure(.transportFailed, "The simulator's display information has no single \(active == nil ? "primary" : "active") display with a known orientation and identifier; nothing was sent.", inputSent: .none)
        }
        if let active {
            func number(_ value: Any?) -> Double? { (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
            let size = (active["nativeSize"] as? [Any])?.compactMap(number) ?? []
            guard let id = (active["displayId"] as? NSNumber)?.intValue, size.count == 2,
                  let scale = number(active["pointScale"]), (0.1...10).contains(scale) else {
                throw CommandFailure(.transportFailed, "The simulator's active display has no valid ID or size; nothing was sent.", inputSent: .none)
            }
            secondary = Secondary(id: id, name: active["name"] as? String ?? "", deviceName: active["deviceName"] as? String ?? "",
                                  widthPoints: size[0] / scale, heightPoints: size[1] / scale, scale: scale)
        } else {
            secondary = nil
        }
        rotation = (native + current) % 360
        displayUUID = identifier.uuidString
        backlight = chosen["backlightState"] as? String ?? "unknown"
        self.data = data
    }

    /// The physical touch display: requires an awake display and agreeing
    /// orientation metadata, exactly as for a phone.
    func touch() throws -> DirectTouchDisplay {
        do {
            return try DirectTouchDisplay(data, displayId: secondary?.id)
        } catch let failure as CommandFailure where failure.code == .displayOff {
            throw CommandFailure(.displayOff, "The simulator's display is off or its state is unknown (locked with button lock?). Press button home and unlock it, then try again; no input sent.", inputSent: .none)
        }
    }

    /// Whether the interface is turned a quarter, so its width is the
    /// native height.
    var quarterTurned: Bool { rotation == 90 || rotation == 270 }

    /// The interface display's native (portrait) size in points and scale.
    func native(_ info: SimulatorDeviceInfo) -> (width: Double, height: Double, scale: Double) {
        secondary.map { ($0.widthPoints, $0.heightPoints, $0.scale) } ?? (info.widthPoints, info.heightPoints, info.scale)
    }

    /// The current interface for accessibility: logical points with origin at
    /// the interface's top left, as the tree's frames are.
    func accessibility(_ info: SimulatorDeviceInfo) -> AccessibilityDisplay {
        let native = native(info)
        return AccessibilityDisplay(bounds: .init(x: 0, y: 0, width: quarterTurned ? native.height : native.width,
                                                  height: quarterTurned ? native.width : native.height),
                                    displayId: 0, pointScale: native.scale, orientation: "rot\(rotation)")
    }

    /// The `screen` object of simulator results. A non-primary interface
    /// display adds its screen ID and name; the primary one keeps the shape.
    func screenJSON(_ info: SimulatorDeviceInfo) -> [String: Any] {
        let interface = accessibility(info).bounds, native = native(info)
        var screen: [String: Any] = ["widthPoints": native.width, "heightPoints": native.height, "scale": native.scale,
                                     "orientation": "rot\(rotation)", "interfaceWidthPoints": interface.width, "interfaceHeightPoints": interface.height]
        if let secondary { screen["display"] = ["id": secondary.id, "name": secondary.name, "deviceName": secondary.deviceName, "primary": false] }
        return screen
    }

    static func read(_ uuid: String, environment: SimulatorEnvironment) throws -> Self {
        try Self(environment.displayInfo(uuid))
    }

    static func == (a: Self, b: Self) -> Bool {
        a.rotation == b.rotation && a.displayUUID == b.displayUUID && a.backlight == b.backlight && a.secondary == b.secondary
    }
}

extension DirectTouchDisplay {
    /// Only a rotation, for mapping points with `portrait` (simulator hit
    /// tests); the geometry fields are placeholders.
    init(rotation: Int) {
        id = 0; width = 1; height = 1; scale = 1; native = 0; self.rotation = rotation
    }
}

extension ADCSimulatorInfo {
    func swift(uuid: String) -> SimulatorDeviceInfo {
        var copy = self
        func text<T>(_ value: inout T) -> String {
            withUnsafeBytes(of: &value) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return SimulatorDeviceInfo(uuid: uuid, name: text(&copy.name), state: text(&copy.state),
                                   widthPoints: widthPoints, heightPoints: heightPoints, scale: scale, family: text(&copy.family))
    }
}
