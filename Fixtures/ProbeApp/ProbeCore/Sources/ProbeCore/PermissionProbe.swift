/// The permission probe's plan: one accessibility element that asks for
/// notification permission, so that a real system prompt can be raised on
/// demand, and reports the app's current authorization in its value.
/// UIKit-free; `App/PermissionProbeRequester.swift` drives it.
public enum PermissionProbe {
    public static let requestIdentifier = "probe.permission.request"
    public static let requestLabel = "Request notification permission"

    /// The app's notification authorization, in `UNAuthorizationStatus` terms.
    /// `unknown` is the value before the first read finishes.
    public enum Status: String, CaseIterable, Sendable {
        case unknown, notDetermined, denied, authorized, provisional, ephemeral
    }

    /// The element's value: the status and how many requests this process
    /// made, keys sorted. The system shows its prompt only while the status
    /// is `notDetermined`, so a request after a decision changes nothing.
    public static func value(status: Status, requests: Int) -> String {
        "{\"requests\":\(requests),\"status\":\"\(status.rawValue)\",\"v\":1}"
    }
}
