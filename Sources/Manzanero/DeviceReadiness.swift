import Foundation

struct DeviceReadiness: Encodable, Sendable {
    struct Issue: Encodable, Sendable {
        let code: String
        let message: String
        let action: String
    }

    let device: String
    let developerMode: String
    let developerDiskImageServices: String
    let connection: String
    let pairing: String
    let status: String
    let issues: [Issue]
    var ui: DeviceUIReadiness? = nil
    let limitations = ["Status and exit code reflect CoreDevice prerequisites only; any UI observations are separate. UI Automation, usbmuxd availability, and live input/capture are not verified."]

    static func decode(_ data: Data, device: String) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any] else {
            throw CommandFailure(.deviceNotReady, "CoreDevice did not return a successful device-details result.", inputSent: .none)
        }
        let properties = result["properties"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? [:]
        let legacyState = result["deviceProperties"] as? [String: Any] ?? [:]
        let legacyConnection = result["connectionProperties"] as? [String: Any] ?? [:]
        let rawMode = state["developerModeStatus"] ?? legacyState["developerModeStatus"]
        let mode: String
        if let value = rawMode as? String, ["enabled", "disabled"].contains(value.lowercased()) {
            mode = value.lowercased()
        } else if let value = rawMode as? [String: Any], value.count == 1,
                  let key = value.keys.first, ["enabled", "disabled"].contains(key) {
            mode = key
        } else { mode = "unknown" }
        let ddi = (state["ddiServicesAvailable"] ?? legacyState["ddiServicesAvailable"]) as? Bool
        let diskImage = ddi.map { $0 ? "available" : "unavailable" } ?? "unknown"
        let connectionState = (connection["state"] ?? legacyConnection["tunnelState"]) as? String ?? "unknown"
        let pairingState = (connection["pairingState"] ?? legacyConnection["pairingState"]) as? String ?? "unknown"
        var issues: [Issue] = []
        if mode == "disabled" {
            issues.append(.init(code: "developerModeDisabled", message: "Developer Mode is disabled.",
                action: "On the iPhone, open Settings → Privacy & Security → Developer Mode, enable it, restart, then unlock and confirm Turn On. Retry readiness afterward."))
        } else if mode == "unknown" {
            issues.append(.init(code: "developerModeUnknown", message: "CoreDevice did not report a recognized Developer Mode state.",
                action: "Unlock/reconnect the device and retry. Check Developer Mode on the phone; unknown does not mean enabled."))
        }
        if ddi == false {
            issues.append(.init(code: "developerImageUnavailable", message: "Developer disk image services are unavailable.",
                action: "After enabling Developer Mode, let the selected Xcode prepare developer support for this device. Some developer operations may prepare it automatically."))
        } else if ddi == nil {
            issues.append(.init(code: "developerImageUnknown", message: "CoreDevice did not report developer-image availability.",
                action: "Check device preparation in the selected Xcode and retry readiness; missing information does not establish readiness."))
        }
        if connectionState != "connected" {
            issues.append(.init(code: "connectionNotConfirmed", message: "Connected state is not confirmed (\(connectionState)).",
                action: "Connect the device, unlock it, and retry the details query."))
        }
        if pairingState != "paired" {
            issues.append(.init(code: "pairingNotConfirmed", message: "Paired state is not confirmed (\(pairingState)).",
                action: "Connect and unlock the device, approve Trust This Computer if requested, and retry readiness."))
        }
        let status = mode == "disabled" ? "blocked" : (mode == "unknown" || ddi == nil || connectionState != "connected" || pairingState != "paired" ? "unknown" : (ddi == true ? "prerequisitesPresent" : "needsPreparation"))
        return Self(device: device, developerMode: mode, developerDiskImageServices: diskImage,
                    connection: connectionState, pairing: pairingState, status: status, issues: issues)
    }

    func requireDeveloperMode(operation: String) throws {
        if developerMode == "disabled" {
            throw CommandFailure(.deviceNotReady, "Cannot \(operation): Developer Mode is disabled. \(issues.first(where: { $0.code == "developerModeDisabled" })?.action ?? "Enable Developer Mode on the device.")", inputSent: .none)
        }
        if developerMode == "unknown" || developerDiskImageServices != "available" {
            FileHandle.standardError.write(Data("Device readiness: Developer Mode \(developerMode); developer-image services \(developerDiskImageServices). Run physical <device> readiness for preparation guidance.\n".utf8))
        }
    }

    func output() throws -> CommandOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return CommandOutput(data: try encoder.encode(self), exitCode: status == "prerequisitesPresent" ? 0 : 1)
    }
}
