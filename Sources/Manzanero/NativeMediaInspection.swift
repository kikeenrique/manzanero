import AppleDeviceBridge
import Foundation

/// Read-only control evidence for the in-process video implementation. No
/// negotiator offer, stream start/stop, decoder hook or media socket is created.
enum NativeMediaInspection {
    /// The number of media sessions the device runs now, read over a fresh
    /// connection; nothing is started or stopped. Recording recovery reads it
    /// to see a lost session gone before it opens the next.
    static func sessionCount(uuid: String, version: String) throws -> UInt64 {
        var result = ADCMediaInspection(), error = [CChar](repeating: 0, count: 1024)
        let status = ADCInspectMedia(uuid, version, { Task.isCancelled ? 1 : 0 }, &result, &error, error.count)
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure(.transportFailed, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        return result.sessionCount
    }

    static func execute(device: String, query: (DeviceCommand) throws -> Data) throws -> Data {
        try Task.checkCancellation()
        let input = CoreDeviceInput(device: device, operation: "media-status", operands: [])
        let details = try query(input.identityPlan())
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
              let properties = (root["result"] as? [String: Any])?["properties"] as? [String: Any],
              let udid = (properties["hardware"] as? [String: Any])?["udid"] as? String else {
            throw CommandFailure(.deviceNotReady, "Media inspection requires fresh physical hardware identity.", inputSent: .none)
        }
        _ = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid)
        var result = ADCMediaInspection(), error = [CChar](repeating: 0, count: 1024)
        let status = ADCInspectMedia(identity.uuid, identity.version, { Task.isCancelled ? 1 : 0 }, &result, &error, error.count)
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure(.transportFailed, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        let version = withUnsafeBytes(of: result.avcVersion) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "media-status", "device": device,
            "resolvedCoreDeviceUUID": identity.uuid, "supportedFeatures": result.supportedFeatures, "avcFrameworkVersion": version,
            "running": result.running != 0, "sessionCount": result.sessionCount, "runDurationSeconds": result.runDurationSeconds,
            "streamMutationRequested": false, "localConnectionCloseRequested": true,
            "limitations": ["Capability flags and server status do not prove recording, decoding or session-specific teardown.",
                "Session identifiers, negotiation data and keys are not exported. Existing sessions are never stopped.",
                "Local connection cancellation is requested; independent remote teardown is not verified."]
        ], options: [.prettyPrinted, .sortedKeys])
    }
}
