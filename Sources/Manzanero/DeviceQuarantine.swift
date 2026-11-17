import Foundation

/// The command side of quarantine (`DeviceLeaseRegistry` keeps the mark):
/// which failures mark a device, and `clear-quarantine`.
///
/// A device is marked when an operation that presses something (touch, a
/// button, keys) fails with `input-outcome-unknown`: the bridge attempted
/// input and could not confirm the end of it, so a contact, key or button
/// may still be held. Accessibility actions hold nothing and never mark.
/// Until the mark is cleared, input to that device is refused as
/// `device-quarantined`; observations and captures still run, so the caller
/// can look at the device before clearing. Nothing is sent to the device to
/// release anything: that has never been observed on hardware.
enum DeviceQuarantine {
    static let operation = "clear-quarantine"

    /// Whether a failed `operation` can have left something held.
    static func canLeaveInputHeld(_ operation: String) -> Bool {
        !(operation.hasPrefix("press-") || operation.hasPrefix("scroll-") || DirectAccessibilitySetValue.operations.contains(operation)
            || CommandService.nativeObservations.contains(operation) || SimulatorHinge.operations.contains(operation))
    }

    /// Marks `device` when `error` says an input's outcome is unknown.
    static func note(_ error: any Error, device: String?, operation: String, leases: DeviceLeaseRegistry) {
        guard let device, let failure = error as? CommandFailure, failure.code == .inputOutcomeUnknown,
              canLeaveInputHeld(operation) else { return }
        leases.markUncertain(device: device, reason: "\(operation) by pid \(getpid()) ended with an unknown outcome")
    }

    static func plan(_ target: Target) -> [String: Any] {
        ["operation": operation, "platform": target.platform.rawValue, "device": target.identifier,
         "execution": "Removes this Mac's quarantine mark for the device, after the caller has inspected it. Sends nothing to the device and releases nothing on it."]
    }

    /// `key` is the lease key: the resolved CoreDevice identifier or the simulator UUID.
    static func clear(_ target: Target, key: String, leases: DeviceLeaseRegistry) throws -> [String: Any] {
        let reason = try leases.clearQuarantine(device: key)
        return ["operation": operation, "platform": target.platform.rawValue, "device": target.identifier,
                "status": reason == nil ? "not-quarantined" : "cleared", "reason": reason ?? NSNull(),
                "inputSent": false,
                "note": "Nothing was sent to the device. Clearing states that it was inspected; it does not release a held contact, key or button."]
    }
}
