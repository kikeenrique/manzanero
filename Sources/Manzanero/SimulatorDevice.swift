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

    var booted: Bool { state == "Booted" }

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
            throw CommandFailure.usage("Simulator \(operation) requires the simulator's UUID (see devices simulators); names and 'booted' are not accepted.")
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
            throw CommandFailure(.targetUnresolved, "\(message) Use the UUID from devices simulators; nothing was sent.", inputSent: .none)
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
            throw CommandFailure(.deviceNotReady, "Simulator \(uuid) is \(info.state.isEmpty ? "not booted" : info.state), not Booted; \(operation) needs a booted simulator. Boot it first (manzanero simulator \(uuid) boot); nothing was sent.", inputSent: .none)
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
    let primaryUUID: String
    let backlight: String
    private let data: Data

    init(_ data: Data) throws {
        let rotations = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
        guard data.count <= 1_048_576, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]] else {
            throw CommandFailure(.transportFailed, "Cannot read the simulator's display information; nothing was sent.", inputSent: .none)
        }
        let primaries = displays.filter { ($0["primary"] as? Bool) == true }
        guard primaries.count == 1, let primary = primaries.first,
              let native = rotations[primary["nativeOrientation"] as? String ?? ""],
              let current = rotations[primary["currentOrientation"] as? String ?? ""],
              let unique = primary["uniqueId"] as? String, let identifier = UUID(uuidString: unique) else {
            throw CommandFailure(.transportFailed, "The simulator's display information has no single primary display with a known orientation and identifier; nothing was sent.", inputSent: .none)
        }
        rotation = (native + current) % 360
        primaryUUID = identifier.uuidString
        backlight = primary["backlightState"] as? String ?? "unknown"
        self.data = data
    }

    /// The physical touch display: requires an awake display and agreeing
    /// orientation metadata, exactly as for a phone.
    func touch() throws -> DirectTouchDisplay {
        do {
            return try DirectTouchDisplay(data)
        } catch let failure as CommandFailure where failure.code == .displayOff {
            throw CommandFailure(.displayOff, "The simulator's display is off or its state is unknown (locked with button lock?). Press button home and unlock it, then try again; no input sent.", inputSent: .none)
        }
    }

    /// Whether the interface is turned a quarter, so its width is the
    /// native height.
    var quarterTurned: Bool { rotation == 90 || rotation == 270 }

    /// The current interface for accessibility: logical points with origin at
    /// the interface's top left, as the tree's frames are.
    func accessibility(_ info: SimulatorDeviceInfo) -> AccessibilityDisplay {
        AccessibilityDisplay(bounds: .init(x: 0, y: 0, width: quarterTurned ? info.heightPoints : info.widthPoints,
                                           height: quarterTurned ? info.widthPoints : info.heightPoints),
                             displayId: 0, pointScale: info.scale, orientation: "rot\(rotation)")
    }

    /// The `screen` object of simulator results.
    func screenJSON(_ info: SimulatorDeviceInfo) -> [String: Any] {
        let interface = accessibility(info).bounds
        return ["widthPoints": info.widthPoints, "heightPoints": info.heightPoints, "scale": info.scale,
                "orientation": "rot\(rotation)", "interfaceWidthPoints": interface.width, "interfaceHeightPoints": interface.height]
    }

    static func read(_ uuid: String, environment: SimulatorEnvironment) throws -> Self {
        try Self(environment.displayInfo(uuid))
    }

    static func == (a: Self, b: Self) -> Bool {
        a.rotation == b.rotation && a.primaryUUID == b.primaryUUID && a.backlight == b.backlight
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
                                   widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
    }
}
