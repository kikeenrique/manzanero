import Foundation

/// The accessibility requests that trees, selector actions and waits make,
/// independent of how a request reaches the device. The physical raw-DTX
/// `AccessibilitySession` and the simulator's CoreSimulator session both send
/// the same `AccessibilityRequest` archives and decode the same
/// `AccessibilityResponse`s; only the carrier and process selection differ.
///
/// Implementations are synchronous, single-owner and not reusable after an
/// error, a timeout or `close()`. `close()` must be idempotent.
protocol AccessibilityExchange: AnyObject {
    /// Wording, backend names and selection names for results and errors.
    var platform: AccessibilityPlatform { get }
    func start() throws
    func application(pid: Int32) throws -> AccessibilityRequest.Token
    func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token
    func snapshot(_ token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue
    func attributes(_ attributes: [Int], of token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue
    func performAction(_ token: AccessibilityRequest.Token, action: AccessibilityRequest.Action, onSubmission: () -> Void) throws -> Bool
    /// The process the platform treats as the foreground app of `display`.
    /// Physical devices hit-test the display centre.
    func foregroundProcess(_ display: AccessibilityDisplay) throws -> AccessibilityRequest.Token
    @discardableResult func close() -> AccessibilitySession.Cleanup
}

extension AccessibilityExchange {
    func foregroundProcess(_ display: AccessibilityDisplay) throws -> AccessibilityRequest.Token {
        try hit(x: display.center.x, y: display.center.y)
    }
}

/// The per-platform text of accessibility results. The physical values are
/// the strings the physical commands have always printed.
struct AccessibilityPlatform: Sendable {
    let backend: String
    /// JSON key naming the resolved identifier in a tree or wait result.
    let resolvedKey: String
    /// Reported in a tree; nil omits it.
    let deviceAPIVersion: Int?
    /// How the foreground process is chosen, lowercase, for error messages.
    let selectionSubject: String
    /// `application.selection` without a PID.
    let selection: String
    /// Prefix of a wrapped tree or wait failure.
    let failurePrefix: String
    let treeSelectionLimitation: String
    let waitSelectionLimitation: String
    let cleanupLimitation: String
    /// Whether `--pid` may also name a process the foreground one shows in a
    /// remote element: a web page inside Safari on a simulator, where the
    /// browser is the foreground application (the human owner's word of
    /// 2026-11-21), and on a phone or iPad since the human owner's word of
    /// 2026-11-25, for a web view embedded in native content, whose page is
    /// neither the display-centre process nor its host. Not on an Apple TV
    /// (a focus-driven display), where `--pid` stays as narrow as before.
    var acceptsShownProcess = false

    var capitalizedSelectionSubject: String { selectionSubject.prefix(1).uppercased() + selectionSubject.dropFirst() }

    static let physical = AccessibilityPlatform(
        backend: "coredevice-direct", resolvedKey: "resolvedCoreDeviceUUID", deviceAPIVersion: 26,
        selectionSubject: "display-centre", selection: "centre-hit-test", failurePrefix: "Direct physical",
        treeSelectionLimitation: "Primary display-centre selection may identify an overlay or embedded process; this is not a combined display tree.",
        waitSelectionLimitation: "Every poll re-selects the primary display-centre process; an overlay or embedded process can be selected. The condition is evaluated in that poll's process.",
        cleanupLimitation: "A disable acknowledgement is not independent verification of phone-side subscription teardown.",
        acceptsShownProcess: true)
}

extension AccessibilitySession: AccessibilityValueSetting {
    var platform: AccessibilityPlatform { .physical }
}
