import Foundation

/// One native action after fresh sequential guards. These checks reduce stale
/// targeting; they are not an atomic transaction or XCTest hittability.
struct DirectAccessibilityAction {
    let action: AccessibilityRequest.Action
    var operation: String { action == .press ? "press" : "scroll-to-visible" }
    let pid: Int32?
    let by: String
    let text: String

    init(_ input: CoreDeviceInput) throws {
        guard ["press-id", "press-label", "scroll-id", "scroll-label"].contains(input.operation), (1...2).contains(input.operands.count),
              let text = input.operands.last, (1...4096).contains(text.utf8.count), !text.contains("\0") else {
            throw CommandFailure(description: "Native AX selector action requires an optional positive PID and 1...4096 UTF-8 bytes of exact selector without NUL.")
        }
        if input.operands.count == 2 {
            guard let pid = Int32(input.operands[0]), pid > 0 else { throw CommandFailure(description: "Native AX selector PID must be positive.") }
            self.pid = pid
        } else { pid = nil }
        action = input.operation.hasPrefix("scroll-") ? .scrollToVisible : .press
        by = input.operation.hasSuffix("-id") ? "identifier" : "label"
        self.text = text
    }

    var selector: AccessibilitySelector { AccessibilitySelector(by: by, text: text) }

    func resolve(_ snapshot: AccessibilityArchiveValue, root: AccessibilityRequest.Token) throws -> AccessibilitySnapshot.Node {
        var found: AccessibilitySelector.Match?
        for match in try selector.matches(snapshot, root: root, failure: failure) {
            guard match.node.token.pid == root.pid else { throw failure("target belongs to another process") }
            if let found {
                guard sameIdentity(found.node.token, match.node.token), found.attributes == match.attributes else {
                    throw failure("selector has multiple distinct or inconsistent matches")
                }
            } else { found = match }
        }
        guard let found else { throw failure("selector has no match in the fresh bounded snapshot") }
        return found.node
    }

    func execute(session: AccessibilitySession, display: () throws -> AccessibilityDisplay) throws -> Data {
        defer { session.close() }
        var state = "not-sent"
        var stage = "display"
        do {
            let geometry = try display()
            stage = "start"
            try session.start()
            stage = "select-process"
            let selected = try session.hit(x: geometry.center.x, y: geometry.center.y)
            if let pid, pid != selected.pid { throw failure("requested PID differs from display-centre process") }
            stage = "application"
            let root = try session.application(pid: selected.pid)
            stage = "first-snapshot"
            let first = try resolve(session.snapshot(root), root: root)
            stage = "second-snapshot"
            let target = try resolve(session.snapshot(root), root: root)
            guard sameIdentity(first.token, target.token) else { throw failure("selector identity changed between snapshots") }
            stage = "live-attributes"
            let before = try liveState(target, session: session, requireVisible: action == .press)
            if action == .press {
                stage = "target-hit"
                try verifyHit(target, frame: before.frame, geometry: geometry, session: session)
            }
            stage = "application/display-recheck"
            try verifySelection(root, geometry: geometry, session: session, display: display)
            stage = operation
            let native = try session.performAction(target.token, action: action, onSubmission: { state = "submitted" })
            var result: [String: Any] = ["backend": "coredevice-direct", "operation": operation,
                "verified": false, "atomic": false,
                "application": ["pid": root.pid, "selection": pid == nil ? "centre-hit-test" : "explicit-pid+centre-hit-test"],
                "selector": ["by": by, "text": text], "coordinateSpace": "device-logical-points",
                "limitations": ["Sequential guards are not atomic or a complete hittability check.",
                    "Unit attribute/action replies can lack target/sequence identity; one request is outstanding.",
                    "No coordinate fallback or automatic replay. Inspect a fresh observation before retrying."]]
            if action == .press {
                state = native ? "accepted" : "refused"
                guard native else { throw failure("native press was refused") }
                result["status"] = state
                result["nativeAccepted"] = true
                result["effectVerified"] = false
                result["target"] = before.json
            } else {
                state = native ? "native-true" : "native-false"
                result["nativeResult"] = native
                result["before"] = before.json
                stage = "post-action-observation"
                do {
                    let afterTarget = try resolve(session.snapshot(root), root: root)
                    guard sameIdentity(afterTarget.token, target.token) else { throw failure("target identity changed after scroll") }
                    let after = try liveState(afterTarget, session: session, requireVisible: true)
                    try verifyHit(afterTarget, frame: after.frame, geometry: geometry, session: session)
                    try verifySelection(root, geometry: geometry, session: session, display: display)
                    result["after"] = after.json
                    result["status"] = "postcondition-verified"
                    result["postconditionVerified"] = true
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    result["status"] = "postcondition-failed"
                    result["postconditionVerified"] = false
                    result["postconditionFailure"] = String(String(describing: error).prefix(2000))
                }
            }
            try Task.checkCancellation()
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            try Task.checkCancellation()
            result["cleanup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup))
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            let detail = "AX \(operation) state=\(state), stage=\(stage); UI effect unverified. No automatic retry. Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed). \(cleanup.diagnostic ?? "")"
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("\(detail)\n".utf8))
                throw CancellationError()
            }
            throw CommandFailure(description: "\(error) \(detail)")
        }
    }

    private func liveState(_ target: AccessibilitySnapshot.Node, session: AccessibilitySession,
                           requireVisible: Bool) throws -> (frame: AccessibilitySnapshot.Frame, json: [String: Any]) {
        let live = try session.attributes([21, 25, 27, 32], of: target.token)
        guard case .dictionary(let fields) = live,
              fields["27"].flatMap(AccessibilityResponse.booleanResult) == true,
              let visible = fields["32"].flatMap(AccessibilityResponse.booleanResult),
              target.visible == visible, !requireVisible || visible else {
            throw failure("target enabled/visible state is unavailable, changed or unsuitable")
        }
        if let identifier = target.identifier {
            guard case .string(let identifier) = identifier, fields["25"] == .string(identifier) else { throw failure("live identifier differs") }
        }
        guard let frame = target.frame, frame.width > 0, frame.height > 0, let liveFrame = fields["21"],
              try AccessibilitySnapshot.rectangle(liveFrame) == frame else { throw failure("live geometry is unavailable or differs") }
        guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any] else {
            throw failure("invalid internal target JSON")
        }
        for key in ["id", "parentId", "children", "depth"] { json.removeValue(forKey: key) }
        json["enabled"] = true
        json["visible"] = visible
        return (frame, json)
    }

    private func verifyHit(_ target: AccessibilitySnapshot.Node, frame: AccessibilitySnapshot.Frame,
                           geometry: AccessibilityDisplay, session: AccessibilitySession) throws {
        let bounds = geometry.bounds
        guard frame.x >= bounds.x, frame.y >= bounds.y, frame.x + frame.width <= bounds.x + bounds.width,
              frame.y + frame.height <= bounds.y + bounds.height else { throw failure("target is not wholly inside the primary display") }
        let hit = try session.hit(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        guard sameIdentity(hit, target.token) else { throw failure("target centre hit is another native element") }
    }

    private func verifySelection(_ root: AccessibilityRequest.Token, geometry: AccessibilityDisplay,
                                 session: AccessibilitySession, display: () throws -> AccessibilityDisplay) throws {
        let after = try session.application(pid: root.pid)
        guard sameIdentity(after, root) else { throw failure("application identity changed") }
        let displayed = try session.hit(x: geometry.center.x, y: geometry.center.y)
        guard displayed.pid == root.pid else { throw failure("display-centre process changed") }
        guard try display() == geometry else { throw failure("display geometry changed") }
    }

    private func sameIdentity(_ a: AccessibilityRequest.Token, _ b: AccessibilityRequest.Token) -> Bool {
        a.pid == b.pid && a.objectID == b.objectID
    }
    private func failure(_ reason: String) -> CommandFailure { CommandFailure(description: "Native AX \(operation): \(reason).") }
}

/// One exact identifier or label selector, shared by actions and waits so
/// both read a snapshot the same way. Matching is exact, case-sensitive string
/// equality on the normalized node field; non-string scalars never match.
struct AccessibilitySelector: Sendable, Equatable {
    struct Match {
        let node: AccessibilitySnapshot.Node
        /// The node's full native attribute record, for duplicate-path checks.
        let attributes: AccessibilityArchiveValue
    }

    let by: String
    let text: String

    /// Normalizes the snapshot (its node/depth bounds apply) and returns every
    /// matching node in traversal order, including repeated paths and foreign
    /// process references. Callers decide what ambiguity means.
    func matches(_ snapshot: AccessibilityArchiveValue, root: AccessibilityRequest.Token,
                 failure: (String) -> CommandFailure) throws -> [Match] {
        let nodes = try AccessibilitySnapshot.normalize(snapshot, root: root)
        var records = [snapshot]
        var found: [Match] = []
        for (index, node) in nodes.enumerated() {
            guard case .dictionary(let record) = records[index], case .array(let children) = record["UIAccessibilitySnapshotKeyChildren"],
                  let attributes = record["UIAccessibilitySnapshotKeyAttributes"] else { throw failure("invalid snapshot record") }
            records.append(contentsOf: children)
            let value = by == "identifier" ? node.identifier : node.label
            if value == .string(text) { found.append(Match(node: node, attributes: attributes)) }
        }
        return found
    }
}
