import Foundation

/// A session that can ask whether a value is settable (request type 3,
/// attribute 53) and set it (type 8). Both the physical DTX session and the
/// simulator session conform.
protocol AccessibilityValueSetting: AccessibilityExchange {
    func isSettable(_ token: AccessibilityRequest.Token) throws -> Bool
    func setValue(_ token: AccessibilityRequest.Token, text: String, onSubmission: () -> Void) throws
}

/// `set-value-id` / `set-value-label`: replaces one element's value through
/// accessibility, which enters any Unicode text without the clipboard or the
/// keyboard. Selection and guards are those of `press-id`/`press-label`
/// (`DirectAccessibilityAction`): foreground selection, two fresh unique
/// snapshots, live enabled/visible state and frame, an exact centre hit and
/// application/display rechecks. One more guard comes first: the element
/// must report its value settable, or nothing is sent. After the request the
/// value is read back once and compared; the receipt reports the comparison
/// rather than failing on it, because the app may legitimately transform it.
struct DirectAccessibilitySetValue {
    static let operations = AccessibilitySelector.operations("set-value")
    static let maximumTextBytes = 65536

    let guards: DirectAccessibilityAction
    let value: String
    var operation: String { guards.operation }

    /// Operands: `[pid] <selector> <text> [--index <n>]`.
    init(_ input: CoreDeviceInput) throws {
        var operands = input.operands
        let index = try AccessibilitySelector.takeIndex(&operands, minimumCount: 4)
        guard Self.operations.contains(input.operation), (2...3).contains(operands.count) else {
            throw CommandFailure.usage("Usage: set-value-id|set-value-label|set-value-value [positive-pid] <exact-selector> <text>; text is 1...\(Self.maximumTextBytes) UTF-8 bytes without NUL.")
        }
        let selector = operands[operands.count - 2], value = operands[operands.count - 1]
        guard (1...4096).contains(selector.utf8.count), !selector.contains("\0") else {
            throw CommandFailure.usage("Native AX set-value requires an exact selector of 1...4096 UTF-8 bytes without NUL.")
        }
        guard (1...Self.maximumTextBytes).contains(value.utf8.count), !value.contains("\0") else {
            throw CommandFailure.usage("Native AX set-value text must be 1...\(Self.maximumTextBytes) UTF-8 bytes without NUL.")
        }
        var pid: Int32?
        if operands.count == 3 {
            guard let value = Int32(operands[0]), value > 0 else { throw CommandFailure.usage("Native AX selector PID must be positive.") }
            pid = value
        }
        guards = DirectAccessibilityAction(guardsFor: "set-value", by: AccessibilitySelector.by(operation: input.operation),
                                           text: selector, pid: pid, index: index)
        self.value = value
    }

    /// Whether a read-back is the masked form of `value`: nothing but bullets
    /// (U+2022), one per character sent. Seen on a secure `UITextField` on
    /// the phone, 14 bullets for 14 characters. A value that is itself all
    /// bullets is compared as text instead.
    static func isMasked(_ readBack: String, for value: String) -> Bool {
        readBack != value && readBack.count == value.count && readBack.allSatisfy { $0 == "\u{2022}" }
    }

    func execute(session: any AccessibilityValueSetting, display: () throws -> AccessibilityDisplay) throws -> Data {
        defer { session.close() }
        let platform = session.platform
        var state = "not-sent"
        var stage = "display"
        do {
            let geometry = try display()
            stage = "start"
            try session.start()
            stage = "select-process"
            let selected = try session.foregroundProcess(geometry)
            let process = try guards.actionProcess(selected: selected.pid, session: session)
            stage = "application"
            let root = try session.application(pid: process)
            stage = "first-snapshot"
            let first = try guards.resolve(session.snapshot(root), root: root)
            stage = "second-snapshot"
            let target = try guards.resolve(session.snapshot(root), root: root)
            guard guards.sameIdentity(first.token, target.token) else {
                throw guards.failure("selector identity changed between snapshots", .preconditionChanged)
            }
            stage = "live-attributes"
            let before = try guards.liveState(target, session: session, requireVisible: true)
            stage = "settable"
            guard try session.isSettable(target.token) else {
                throw guards.failure("the target does not report a settable value (request type 3, attribute 53); nothing was sent. Select the text field itself, not its label or container", .targetUnresolved)
            }
            stage = "target-hit"
            try guards.verifyHit(target, frame: before.frame, geometry: geometry, session: session)
            stage = "application/display-recheck"
            try guards.verifySelection(root, centre: selected.pid, geometry: geometry, session: session, display: display)
            stage = "set-value"
            try session.setValue(target.token, text: value, onSubmission: { state = "submitted" })
            state = "acknowledged"
            var result: [String: Any] = ["backend": platform.backend, "operation": operation,
                "status": "acknowledged", "verified": false, "atomic": false,
                "application": guards.applicationJSON(root.pid, centre: selected.pid, platform: platform),
                "selector": guards.selector.json, "coordinateSpace": "device-logical-points",
                "target": before.json, "requestedUTF8Bytes": value.utf8.count,
                "limitations": ["Sequential guards are not atomic or a complete hittability check.",
                    "The value replaces the element's whole value; it is not typed at a caret, and no keyboard, clipboard or return key is involved.",
                    "The app may transform or reject the value; valueMatches compares one read-back, and is null with readBack 'masked' when a secure field answers one bullet per character.",
                    "No coordinate fallback or automatic replay. Inspect a fresh observation before retrying."]]
            stage = "read-back"
            do {
                guard case .dictionary(let fields) = try session.attributes([AccessibilityRequest.valueAttribute], of: target.token) else {
                    throw guards.failure("value read-back is not a dictionary", .transportFailed)
                }
                let readBack = fields[String(AccessibilityRequest.valueAttribute)]
                if case .string(let text) = readBack {
                    result["readBackUTF8Bytes"] = text.utf8.count
                    if Self.isMasked(text, for: value) {
                        // A secure field answers one bullet per character, so
                        // the text cannot be compared; only its length can.
                        result["valueMatches"] = NSNull()
                        result["readBack"] = "masked"
                        result["maskedLengthMatches"] = true
                    } else {
                        result["valueMatches"] = text == value
                    }
                } else {
                    result["valueMatches"] = false
                    result["readBack"] = "not a string"
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                result["valueMatches"] = NSNull()
                result["readBackFailure"] = String(String(describing: error).prefix(2000))
            }
            try Task.checkCancellation()
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            result["cleanup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup))
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            let detail = "AX \(operation) state=\(state), stage=\(stage); UI effect unverified. No automatic retry. Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed). \(cleanup.diagnostic ?? "")"
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("\(detail)\n".utf8))
                throw CancellationError()
            }
            let failure = CommandFailure("\(error) \(detail)", wrapping: error)
            throw state == "not-sent" ? failure.noInputSent()
                : CommandFailure(.inputOutcomeUnknown, failure.description, inputSent: .possible)
        }
    }
}
