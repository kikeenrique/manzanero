import CoreFoundation
import Foundation

/// Sequential read-only observations, not a live UI-automation capability test.
struct DeviceUIReadiness: Encodable, Sendable {
    let displayPower: String
    let passcodeRequired: Bool?
    let unlockedSinceBoot: Bool?
    let status: String
    let actions: [String]
    let diagnostics: [String]
    let limitations = [
        "Display and passcode observations are sequential, non-atomic and may change immediately.",
        "No passcode requirement and unlockedSinceBoot do not prove the current UI is unlocked.",
        "UI Automation permission and actual input/capture are not verified. No wake or unlock is attempted."
    ]

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
        func boolean(_ value: Any?) -> Bool? {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        var power = "unknown"
        if let output = try result("displays"), let displays = output["displays"] as? [[String: Any]],
           (1...16).contains(displays.count), displays.allSatisfy({ boolean($0["primary"]) != nil }) {
            let primary = displays.filter { boolean($0["primary"]) == true }
            if primary.count == 1 {
                switch primary[0]["backlightState"] as? String {
                case "activeOn": power = "on"
                case "off": power = "off"
                default: break
                }
            }
        }
        if power == "unknown" { diagnostics.append("displayPowerUnknown: no unique primary display with a recognized power state.") }
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
