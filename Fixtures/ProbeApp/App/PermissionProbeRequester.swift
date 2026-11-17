import ProbeCore
import UIKit
import UserNotifications

/// `probe.permission.request`: asks for notification permission when
/// activated through accessibility (Manzanero `press --id
/// probe.permission.request`), which raises the system's own prompt while the
/// app's authorization is still undetermined. Its value reports the current
/// authorization. Separate from the touch and log probes; it posts no
/// notification.
@MainActor
final class PermissionProbeRequester {
    private var status = PermissionProbe.Status.unknown
    private var requests = 0

    /// Adds the element to an accessibility container that already lists its
    /// elements (the touch surface), to the right of `probe.log.emit`. It is
    /// an element, not a view, so it never receives touches.
    func attach(to container: UIView) {
        let element = LogProbeEmitElement(accessibilityContainer: container)
        element.accessibilityIdentifier = PermissionProbe.requestIdentifier
        element.accessibilityLabel = PermissionProbe.requestLabel
        element.accessibilityTraits = .button
        element.accessibilityFrameInContainerSpace = CGRect(x: 204, y: 400, width: 155, height: 52)
        element.read = { [unowned self] in PermissionProbe.value(status: status, requests: requests) }
        element.activate = { [unowned self] in request() }
        container.accessibilityElements = (container.accessibilityElements ?? []) + [element]
        refresh()
    }

    /// Reads the authorization again: at attach, when the app becomes active
    /// (the user may have changed it in Settings) and after a request.
    func refresh() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            status = Self.status(settings.authorizationStatus)
        }
    }

    private func request() {
        requests += 1
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            refresh()
        }
    }

    private static func status(_ status: UNAuthorizationStatus) -> PermissionProbe.Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }
}
