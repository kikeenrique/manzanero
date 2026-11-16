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

    var screenJSON: [String: Any] {
        ["widthPoints": widthPoints, "heightPoints": heightPoints, "scale": scale, "orientation": SimulatorDevice.orientation]
    }
}

/// Simulator lookup through CoreSimulator in process. Simulator commands
/// address a simulator by its UUID only: CoreSimulator's device set is keyed by
/// UUID, and names or `booted` can match several simulators.
enum SimulatorDevice {
    /// Rotation is not read yet (see docs/simulator-input.md); coordinates and
    /// frames assume the portrait interface every iPhone simulator starts in.
    static let orientation = "portrait-assumed"

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
/// devicectl JSON shape, so the physical `DirectTouchDisplay` parser applies
/// unchanged: awake state, geometry, native and current orientation. Also the
/// primary display's unique identifier, which names its Universal HID
/// touchscreen. Reading it sends no input.
struct SimulatorDisplay: Equatable {
    let touch: DirectTouchDisplay
    let primaryUUID: String

    init(_ data: Data) throws {
        touch = try DirectTouchDisplay(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]],
              let primary = displays.first(where: { ($0["primary"] as? Bool) == true }),
              let unique = primary["uniqueId"] as? String, let identifier = UUID(uuidString: unique) else {
            throw CommandFailure(.transportFailed, "The simulator's display information has no primary display identifier; no input sent.", inputSent: .none)
        }
        primaryUUID = identifier.uuidString
    }

    static func read(_ uuid: String, environment: SimulatorEnvironment) throws -> Self {
        do {
            return try Self(environment.displayInfo(uuid))
        } catch let failure as CommandFailure where failure.code == .displayOff {
            throw CommandFailure(.displayOff, "The simulator's display is off or its state is unknown (locked with button lock?). Press button home and unlock it, then try again; no input sent.", inputSent: .none)
        }
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
