import LocalAuthentication
import os
import UIKit

/// `probe.biometrics.request`: asks for a biometric evaluation (Face ID or
/// Touch ID) when activated through accessibility (`press --id
/// probe.biometrics.request`), which raises the system's biometric prompt
/// when biometrics are enrolled (`settings --biometrics on`). Its value
/// reports the outcome: `none`, `waiting`, `success`, or `failed:<code>`
/// with LocalAuthentication's error code, then how many requests were made
/// and which biometry the device offers. It authenticates nothing else.
@MainActor
final class BiometricProbeRequester {
    static let identifier = "probe.biometrics.request"
    private var outcome = "none"
    private var requests = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe", category: "biometrics")

    func attach(to container: UIView) {
        let element = LogProbeEmitElement(accessibilityContainer: container)
        element.accessibilityIdentifier = Self.identifier
        element.accessibilityLabel = "Request biometrics"
        element.accessibilityTraits = .button
        element.accessibilityFrameInContainerSpace = CGRect(x: 16, y: 504, width: 343, height: 44)
        element.read = { [unowned self] in "\(outcome) requests=\(requests) biometry=\(Self.biometry())" }
        element.activate = { [unowned self] in request() }
        container.accessibilityElements = (container.accessibilityElements ?? []) + [element]
    }

    /// What the device offers: faceID, touchID, opticID, none, or
    /// unavailable:<code> when the policy cannot be evaluated (not enrolled).
    private static func biometry() -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "unavailable:\(error?.code ?? 0)"
        }
        switch context.biometryType {
        case .faceID: return "faceID"
        case .touchID: return "touchID"
        case .opticID: return "opticID"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }

    private func request() {
        requests += 1
        outcome = "waiting"
        logger.info("biometrics request \(self.requests, privacy: .public)")
        Task { @MainActor in
            do {
                _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "The probe checks a biometric prompt.")
                outcome = "success"
            } catch {
                outcome = "failed:\((error as NSError).code)"
            }
            logger.info("biometrics outcome \(self.outcome, privacy: .public)")
        }
    }
}
