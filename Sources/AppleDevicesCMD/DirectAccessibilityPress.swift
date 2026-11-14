import Foundation

/// One native action after fresh sequential guards. These checks reduce stale
/// targeting; they are not an atomic transaction or XCTest hittability.
struct DirectAccessibilityPress {
    let pid: Int32?
    let by: String
    let text: String

    init(_ input: CoreDeviceInput) throws {
        guard ["press-id", "press-label"].contains(input.operation), (1...2).contains(input.operands.count),
              let text = input.operands.last, (1...4096).contains(text.utf8.count), !text.contains("\0") else {
            throw CommandFailure(description: "Native AX press requires an optional positive PID and 1...4096 UTF-8 bytes of exact selector without NUL.")
        }
        if input.operands.count == 2 {
            guard let pid = Int32(input.operands[0]), pid > 0 else { throw CommandFailure(description: "Native AX press PID must be positive.") }
            self.pid = pid
        } else { pid = nil }
        by = input.operation == "press-id" ? "identifier" : "label"
        self.text = text
    }

    func resolve(_ snapshot: AccessibilityArchiveValue, root: AccessibilityRequest.Token) throws -> AccessibilitySnapshot.Node {
        let nodes = try AccessibilitySnapshot.normalize(snapshot, root: root)
        var records = [snapshot]
        var found: (AccessibilitySnapshot.Node, AccessibilityArchiveValue)?
        for (index, node) in nodes.enumerated() {
            guard case .dictionary(let record) = records[index], case .array(let children) = record["UIAccessibilitySnapshotKeyChildren"],
                  let attributes = record["UIAccessibilitySnapshotKeyAttributes"] else { throw failure("invalid snapshot record") }
            records.append(contentsOf: children)
            let value = by == "identifier" ? node.identifier : node.label
            guard value == .string(text) else { continue }
            guard node.token.pid == root.pid else { throw failure("target belongs to another process") }
            if let found {
                guard sameIdentity(found.0.token, node.token), found.1 == attributes else {
                    throw failure("selector has multiple distinct or inconsistent matches")
                }
            } else { found = (node, attributes) }
        }
        guard let found else { throw failure("selector has no match in the fresh bounded snapshot") }
        return found.0
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
            let live = try session.attributes([21, 25, 27, 32], of: target.token)
            guard case .dictionary(let fields) = live,
                  fields["27"].flatMap(AccessibilityResponse.booleanResult) == true,
                  fields["32"].flatMap(AccessibilityResponse.booleanResult) == true, target.visible == true else {
                throw failure("target is not known enabled and visible")
            }
            if let identifier = target.identifier {
                guard case .string(let identifier) = identifier, fields["25"] == .string(identifier) else { throw failure("live identifier differs") }
            }
            guard let frame = target.frame, let liveFrame = fields["21"],
                  try AccessibilitySnapshot.rectangle(liveFrame) == frame else { throw failure("live geometry differs") }
            let bounds = geometry.bounds
            guard frame.width > 0, frame.height > 0, frame.x >= bounds.x, frame.y >= bounds.y,
                  frame.x + frame.width <= bounds.x + bounds.width,
                  frame.y + frame.height <= bounds.y + bounds.height else { throw failure("target is not wholly inside the primary display") }
            stage = "target-hit"
            let hit = try session.hit(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            guard sameIdentity(hit, target.token) else { throw failure("target centre hit is another native element") }
            stage = "application-recheck"
            let after = try session.application(pid: root.pid)
            guard sameIdentity(after, root) else { throw failure("application identity changed") }
            stage = "display-recheck"
            let displayed = try session.hit(x: geometry.center.x, y: geometry.center.y)
            guard displayed.pid == root.pid else { throw failure("display-centre process changed") }
            guard try display() == geometry else { throw failure("display geometry changed") }
            stage = "press"
            let accepted = try session.press(target.token, onSubmission: { state = "submitted" })
            state = accepted ? "accepted" : "refused"
            guard accepted else { throw failure("native press was refused") }
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            var targetJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any] ?? [:]
            for key in ["id", "parentId", "children", "depth"] { targetJSON.removeValue(forKey: key) }
            return try JSONSerialization.data(withJSONObject: ["backend": "coredevice-direct", "operation": "press", "status": state,
                "nativeAccepted": true, "verified": false, "effectVerified": false, "atomic": false,
                "application": ["pid": root.pid, "selection": pid == nil ? "centre-hit-test" : "explicit-pid+centre-hit-test"],
                "selector": ["by": by, "text": text], "target": targetJSON, "coordinateSpace": "device-logical-points",
                "cleanup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup)),
                "limitations": ["Sequential guards are not atomic or a complete hittability check.",
                    "Action replies have no target/sequence identity; one request is outstanding. Native acceptance does not verify effect.",
                    "No coordinate fallback or automatic replay. Inspect a fresh observation before retrying."]
            ], options: [.prettyPrinted, .sortedKeys])
        } catch {
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            let detail = "AX press state=\(state), stage=\(stage); UI effect unverified. No automatic retry. Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed). \(cleanup.diagnostic ?? "")"
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("\(detail)\n".utf8))
                throw CancellationError()
            }
            throw CommandFailure(description: "\(error) \(detail)")
        }
    }

    private func sameIdentity(_ a: AccessibilityRequest.Token, _ b: AccessibilityRequest.Token) -> Bool {
        a.pid == b.pid && a.objectID == b.objectID
    }
    private func failure(_ reason: String) -> CommandFailure { CommandFailure(description: "Native AX press: \(reason).") }
}
