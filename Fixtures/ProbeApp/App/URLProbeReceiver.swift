import os
import UIKit

/// `probe.url`: reports the URLs the app was opened with, so Manzanero's
/// `open-url` can be checked against an app of the project's own
/// (docs/probe-app.md#url-probe). The app registers the scheme
/// `manzanero-probe`; its value is `none`, or the count and the last URL.
/// Separate from the other probes.
@MainActor
final class URLProbeReceiver {
    static let scheme = "manzanero-probe"
    static let identifier = "probe.url"

    private var count = 0
    private var last: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe", category: "url")

    /// `none`, or `<count> <url>`.
    var value: String { last.map { "\(count) \($0)" } ?? "none" }

    func received(_ url: URL) {
        count += 1
        last = url.absoluteString
        logger.info("url \(self.count, privacy: .public) \(url.absoluteString, privacy: .public)")
    }

    /// Adds the element to the touch surface's accessibility elements, below
    /// `probe.log.emit`. It is an element, not a view, and has no action.
    func attach(to container: UIView) {
        let element = LogProbeEmitElement(accessibilityContainer: container)
        element.accessibilityIdentifier = Self.identifier
        element.accessibilityLabel = "Opened URL"
        element.accessibilityTraits = .staticText
        element.accessibilityFrameInContainerSpace = CGRect(x: 16, y: 460, width: 343, height: 36)
        element.read = { [unowned self] in value }
        container.accessibilityElements = (container.accessibilityElements ?? []) + [element]
    }
}
