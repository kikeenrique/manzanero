import Foundation

/// `remote <button> --report-focus`: the press, then where the focus went,
/// read from a fresh tree of the same device, in one command.
///
/// A remote press's receipt says what was sent, not what it did, so an
/// agent new to the tool took a screenshot after each press to find the
/// focus (2026-11-23). The tree of an Apple TV marks its focused node, so
/// the receipt can carry it. The tree is read as `tree` reads it: on a
/// physical Apple TV only over the tool's own tunnel, never Apple's
/// (`DirectPhysicalAccessibility.appleTVTunnelRefusal`).
///
/// The focus is read once, after a short settle; nothing is pressed again.
/// A failed read never turns a sent press into a failure: the receipt says
/// why in `focusUnavailable`.
enum RemoteFocusReport {
    static let flag = "--report-focus"
    /// Long enough for tvOS's focus animation after a press or a swipe,
    /// whose own duration is already over when the press returns.
    static let settle = Duration.milliseconds(600)

    static var plan: [String: Any] { [
        "settleMilliseconds": 600,
        "read": "After a press that succeeded, one tree of the device as tree reads it (on a physical Apple TV over the tool's own tunnel only); the node it marks focused is added to the receipt as focus. A failed read adds focusUnavailable and leaves the press's result as it is. Nothing is pressed again."] }

    /// The press's receipt with `focus` (the focused node's id, label,
    /// identifier, value and frame, or null when the tree marks none) or
    /// `focusUnavailable`. `readTree` waits and reads; it is called only
    /// when the press exited 0.
    static func annotate(_ press: CommandOutput, isolation: isolated (any Actor)? = #isolation,
                         readTree: () async throws -> CommandOutput) async -> CommandOutput {
        guard press.exitCode == 0, var receipt = (try? JSONSerialization.jsonObject(with: press.data)) as? [String: Any] else { return press }
        do {
            let tree = try await readTree()
            guard let root = try JSONSerialization.jsonObject(with: tree.data) as? [String: Any],
                  let nodes = root["nodes"] as? [[String: Any]] else {
                throw CommandFailure(.internal, "The tree had no nodes.", inputSent: .none)
            }
            if let node = nodes.first(where: { $0["focused"] as? Bool == true }) {
                var focus: [String: Any] = ["nodeId": node["id"] ?? NSNull()]
                for key in ["label", "identifier", "value", "frame"] { focus[key] = node[key] ?? NSNull() }
                receipt["focus"] = focus
            } else {
                receipt["focus"] = NSNull()
                receipt["focusNote"] = "The tree marks no focused element: the focus may be in another process (Control Centre is in TVSystemUIService's) or on nothing."
            }
            if let application = root["application"] { receipt["focusApplication"] = application }
        } catch is CancellationError {
            receipt["focusUnavailable"] = "Cancelled before the focus was read; the press was sent."
        } catch {
            receipt["focusUnavailable"] = "\(CommandFailure.classify(error).description) The press was sent; read the focus with tree."
        }
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) else { return press }
        return CommandOutput(data: data, exitCode: press.exitCode, note: press.note)
    }
}
