import CoreFoundation
import Foundation

/// Sequential read-only observations, not a live UI-automation capability test.
struct DeviceUIReadiness: Encodable, Sendable {
    let displayPower: String
    let passcodeRequired: Bool?
    let unlockedSinceBoot: Bool?
    private(set) var status: String
    private(set) var actions: [String]
    private(set) var diagnostics: [String]
    /// Only for an external display (an Apple TV): whether the device is
    /// asleep, from its screenshot (`AppleTVPower.isAsleep`); absent when
    /// not looked at or when the screenshot failed for another reason.
    private(set) var asleep: Bool? = nil
    let limitations = [
        "Display and passcode observations are sequential, non-atomic and may change immediately.",
        "No passcode requirement and unlockedSinceBoot do not prove the current UI is unlocked.",
        "UI Automation permission and actual input/capture are not verified. No wake or unlock is attempted."
    ]

    static let lockNote = "After this input the device reported that a passcode is required: it is locked, so the input may have gone to the lock screen. Unlock it directly; the tool does not enter passcodes."

    /// Adds `passcodeRequired` (true, false or null when it could not be
    /// read) to an input receipt, and a `lockNote` when it is true. One
    /// read-only lock-state query after the input, so the input's own timing
    /// is untouched; a failed read never turns a sent input into a failure.
    static func annotateInput(_ receipt: Data, uuid: String, query: (DeviceCommand) throws -> Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: Any], root["passcodeRequired"] == nil else { return receipt }
        var required: Bool?
        if let data = try? query(.init(arguments: ["devicectl", "device", "info", "lockState", "--device", uuid,
                "--timeout", "10", "--quiet", "--json-output", "-"], jsonOutput: true)), data.count <= 1_048_576,
           let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (reply["info"] as? [String: Any])?["outcome"] as? String == "success",
           let value = reply["result"] as? [String: Any],
           let identifier = value["deviceIdentifier"] as? String, UUID(uuidString: identifier) == UUID(uuidString: uuid),
           let number = value["passcodeRequired"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            required = number.boolValue
        }
        root["passcodeRequired"] = required.map { $0 as Any } ?? NSNull()
        if required == true { root["lockNote"] = lockNote }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? receipt
    }

    static let displayOffNote = "The display was off when this was checked right after the capture, so the image is probably black. Wake the device (wake) and capture again."

    /// Adds `displayPower` (on, off, external or unknown) to a physical screenshot's
    /// receipt, and a `displayNote` when it is off: a sleeping phone answers
    /// a screenshot with a black image and no error. One read-only display
    /// query after the capture; a failed read never fails the screenshot.
    static func annotateScreenshot(_ receipt: Data, device: String, query: (DeviceCommand) throws -> Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: Any], root["displayPower"] == nil else { return receipt }
        var power = "unknown"
        if let data = try? query(.init(arguments: ["devicectl", "device", "info", "displays", "--device", device,
                "--timeout", "10", "--quiet", "--json-output", "-"], jsonOutput: true)), data.count <= 1_048_576,
           let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (reply["info"] as? [String: Any])?["outcome"] as? String == "success",
           let value = reply["result"] as? [String: Any] {
            power = displayPower(value)
        }
        root["displayPower"] = power
        if power == "off" { root["displayNote"] = displayOffNote }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? receipt
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    /// The power value for a primary display that is external, such as the
    /// television of an Apple TV.
    static let externalPower = "external"
    static let externalNote = "The primary display is external (an Apple TV's television). It has no backlight state to read, so whether it is switched on is not known; the device draws to it either way."

    /// An external display has no backlight: an Apple TV 4K reported
    /// `backlightState: off` for its television while it drew the Home Screen
    /// (docs/verification.md, first look at a physical Apple TV).
    static func isExternal(_ display: [String: Any]) -> Bool {
        (display["type"] as? [String: Any])?["external"] is [String: Any]
    }

    /// on, off, external or unknown, from a `devicectl device info displays`
    /// result: the backlight of the one primary display, or `external` when
    /// that display has none.
    static func displayPower(_ output: [String: Any]) -> String {
        guard let displays = output["displays"] as? [[String: Any]], (1...16).contains(displays.count),
              displays.allSatisfy({ boolean($0["primary"]) != nil }) else { return "unknown" }
        let primary = displays.filter { boolean($0["primary"]) == true }
        guard primary.count == 1 else { return "unknown" }
        if isExternal(primary[0]) { return externalPower }
        switch primary[0]["backlightState"] as? String {
        case "activeOn": return "on"
        case "off": return "off"
        default: return "unknown"
        }
    }

    static let asleepAction = "The Apple TV is asleep: wake it (wake or remote wake) before UI inspection, input or recording."

    /// The display of an Apple TV reads the same asleep and awake; its
    /// screenshot does not: a sleeping one refuses it with a zero-sized
    /// display. One screenshot, which did not wake the device when it was
    /// asleep (2026-11-18), only for an external display. `screenshot`
    /// returns nil for asleep and throws for any other failure.
    func observingSleep(_ screenshot: () throws -> URL?) throws -> Self {
        guard displayPower == Self.externalPower else { return self }
        var observed = self
        do {
            let asleep = try screenshot() == nil
            observed.asleep = asleep
            if asleep {
                observed.actions.append(Self.asleepAction)
                observed.status = "needsUserAction"
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            observed.diagnostics.append("sleepStateUnknown: the screenshot that tells an Apple TV's sleep failed for another reason.")
        }
        return observed
    }

    static func observe(details: Data, device: String, query: (DeviceCommand) throws -> Data) throws -> Self {
        try Task.checkCancellation()
        guard let uuid = try? CoreDeviceInput.resolve(details, requested: device) else {
            return .init(displayPower: "unknown", passcodeRequired: nil, unlockedSinceBoot: nil, status: "unknown",
                actions: [], diagnostics: ["deviceIdentityUnavailable: UI state was not queried without a resolved device UUID."])
        }
        var diagnostics: [String] = []
        func result(_ command: String) throws -> [String: Any]? {
            try Task.checkCancellation()
            do {
                let data = try query(.init(arguments: ["devicectl", "device", "info", command, "--device", uuid,
                    "--timeout", "10", "--quiet", "--json-output", "-"], jsonOutput: true))
                try Task.checkCancellation()
                guard data.count <= 1_048_576,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (root["info"] as? [String: Any])?["outcome"] as? String == "success",
                      let value = root["result"] as? [String: Any] else {
                    diagnostics.append("\(command)Unavailable: no bounded successful result."); return nil
                }
                if let identifier = value["deviceIdentifier"] {
                    guard let identifier = identifier as? String, UUID(uuidString: identifier) == UUID(uuidString: uuid) else {
                        diagnostics.append("\(command)IdentityMismatch: result ignored."); return nil
                    }
                } else if command == "lockState" {
                    diagnostics.append("lockStateIdentityMissing: result ignored."); return nil
                }
                return value
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                diagnostics.append("\(command)Unavailable: the Apple query failed."); return nil
            }
        }
        let power = try result("displays").map(displayPower) ?? "unknown"
        if power == "unknown" { diagnostics.append("displayPowerUnknown: no unique primary display with a recognized power state.") }
        if power == externalPower { diagnostics.append("displayExternal: \(externalNote)") }
        let lock = try result("lockState")
        let passcode = boolean(lock?["passcodeRequired"]), sinceBoot = boolean(lock?["unlockedSinceBoot"])
        if passcode == nil || sinceBoot == nil { diagnostics.append("passcodeStateUnknown: required Boolean fields were not reported.") }
        var actions: [String] = []
        if power == "off" { actions.append("Wake the selected device before UI inspection, touch or recording.") }
        if passcode == true || sinceBoot == false { actions.append("Unlock the selected device directly; do not send its passcode to the tool.") }
        let status = !actions.isEmpty ? "needsUserAction" : (power == "unknown" || passcode == nil || sinceBoot == nil ? "unknown" : "observed")
        return .init(displayPower: power, passcodeRequired: passcode, unlockedSinceBoot: sinceBoot,
            status: status, actions: actions, diagnostics: diagnostics)
    }
}
