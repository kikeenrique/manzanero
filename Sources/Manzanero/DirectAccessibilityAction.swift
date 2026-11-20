import Foundation

/// One native action after fresh sequential guards. These checks reduce stale
/// targeting; they are not an atomic transaction or XCTest hittability.
struct DirectAccessibilityAction {
    let action: AccessibilityRequest.Action
    var operation: String { operationName ?? (action == .press ? "press" : "scroll-to-visible") }
    let pid: Int32?
    let by: String
    let text: String
    /// `--index`: the position among the distinct matches, counted from 1.
    let index: Int?
    /// `--search`, scroll only: how many steps to look forward for a target
    /// that is not in the tree yet (a list that loads its rows as it moves).
    let search: Int?
    /// One session serves a whole search, and the standard allowance (256
    /// frames, 30 seconds) ends a long one: on an Apple TV 4K a search of
    /// 21 steps finished and one of about 39 stopped with "frame budget
    /// exceeded". A step is a scroll request and the snapshots that follow
    /// it until the tree settles, so each step adds to every limit.
    var sessionLimits: AccessibilitySession.Limits {
        guard let search else { return .standard }
        return .init(lifetime: .seconds(30 + 3 * search), frames: 256 + 32 * search,
                     callbackBytes: 40 * 1024 * 1024 + 2 * 1024 * 1024 * search)
    }
    static let searchOption = "--search"
    static let searchRange = 1...200
    /// How many anchors a search tries at one position before it stops.
    static let searchCandidates = 4
    /// `--toward`, with `--search`: the way the search moves; down unless given.
    let toward: SearchDirection
    /// A process that draws over the application in front and may be acted
    /// on although it is neither that application nor its host. No operand
    /// sets it: only `remote sleep` does, for an Apple TV's system UI
    /// process, whose Control Centre is on the screen while PineBoard is the
    /// frontmost application (`AppleTVPower`). `--pid` stays as narrow as
    /// `actionProcess` says.
    var overlayProcess: Int32? = nil
    static let towardOption = "--toward"

    /// The edge of the tree a search step scrolls from.
    enum SearchDirection: String, CaseIterable, Sendable {
        case down, up, left, right

        /// How far a frame reaches in this direction; the largest is the anchor.
        func reach(_ frame: AccessibilitySnapshot.Frame) -> Double {
            switch self {
            case .down: frame.y + frame.height
            case .up: -frame.y
            case .right: frame.x + frame.width
            case .left: -frame.x
            }
        }
    }
    /// Set only by another operation that reuses these guards (set-value);
    /// it names that operation in messages instead of press.
    private var operationName: String? = nil

    /// The selector and guards for an operation other than press or scroll
    /// (`DirectAccessibilitySetValue`); `execute` is not used with it.
    init(guardsFor operation: String, by: String, text: String, pid: Int32?, index: Int? = nil) {
        action = .press
        operationName = operation
        self.by = by
        self.text = text
        self.pid = pid
        self.index = index
        search = nil
        toward = .down
    }

    /// Operands: `[pid] <selector> [--index <n>] [--search <steps> [--toward <direction>]]`.
    init(_ input: CoreDeviceInput) throws {
        var operands = input.operands
        if operands.count >= 5, operands[operands.count - 2] == Self.towardOption, operands[operands.count - 4] == Self.searchOption {
            guard let direction = SearchDirection(rawValue: operands[operands.count - 1]) else {
                throw CommandFailure.usage("\(Self.towardOption) is down, up, left or right, and belongs to scroll \(Self.searchOption).")
            }
            toward = direction
            operands.removeLast(2)
        } else { toward = .down }
        if operands.count >= 3, operands[operands.count - 2] == Self.searchOption {
            guard input.operation.hasPrefix("scroll-"), let steps = Int(operands[operands.count - 1]), Self.searchRange.contains(steps) else {
                throw CommandFailure.usage("\(Self.searchOption) belongs to scroll and must be a whole number of steps in \(Self.searchRange.lowerBound)...\(Self.searchRange.upperBound).")
            }
            search = steps
            operands.removeLast(2)
        } else { search = nil }
        index = try AccessibilitySelector.takeIndex(&operands, minimumCount: 3)
        guard Self.operations.contains(input.operation), (1...2).contains(operands.count),
              let text = operands.last, (1...4096).contains(text.utf8.count), !text.contains("\0") else {
            throw CommandFailure.usage("Native AX selector action requires an optional positive PID and 1...4096 UTF-8 bytes of exact selector without NUL.")
        }
        if operands.count == 2 {
            guard let pid = Int32(operands[0]), pid > 0 else { throw CommandFailure.usage("Native AX selector PID must be positive.") }
            self.pid = pid
        } else { pid = nil }
        action = input.operation.hasPrefix("scroll-") ? .scrollToVisible : .press
        by = AccessibilitySelector.by(operation: input.operation)
        self.text = text
    }

    /// `press-…` and `scroll-…` for every selector kind.
    static let operations = AccessibilitySelector.operations("press") + AccessibilitySelector.operations("scroll")

    var selector: AccessibilitySelector { AccessibilitySelector(by: by, text: text, index: index) }

    func resolve(_ snapshot: AccessibilityArchiveValue, root: AccessibilityRequest.Token) throws -> AccessibilitySnapshot.Node {
        // One entry per distinct element; repeated paths must agree.
        var distinct: [AccessibilitySelector.Match] = []
        for match in try selector.matches(snapshot, root: root, failure: { failure($0, .transportFailed) }) {
            guard match.node.token.pid == root.pid else { throw failure("target belongs to another process", .targetUnresolved) }
            if let first = distinct.first(where: { sameIdentity($0.node.token, match.node.token) }) {
                guard first.attributes == match.attributes else {
                    throw failure("selector has multiple distinct or inconsistent matches", .targetUnresolved)
                }
            } else { distinct.append(match) }
        }
        guard let first = distinct.first else { throw failure("selector has no match in the fresh bounded snapshot", .targetUnresolved) }
        // The caller chose by position: the nth distinct element in node
        // order, whatever its visibility. The guards that follow (a second
        // snapshot with the same identity, live state, frame and hit) still
        // apply to it.
        if let index {
            guard index <= distinct.count else {
                throw failure("selector index \(index) is beyond the \(distinct.count) matching element(s): \(Self.describe(distinct.map(\.node)))", .targetUnresolved)
            }
            return distinct[index - 1].node
        }
        if distinct.count == 1 { return first.node }
        // A list row and the text inside it often share one label, with only the
        // row visible (observed in Settings). When exactly one match is visible
        // and every other is explicitly hidden, the visible one is the target.
        // The same rule as a wait; any unknown visibility keeps it ambiguous.
        let shown = distinct.filter { $0.node.visible == true }
        guard shown.count == 1, distinct.allSatisfy({ $0.node.visible != nil }) else {
            throw failure("selector has multiple distinct or inconsistent matches: \(Self.describe(distinct.map(\.node)))", .targetUnresolved)
        }
        return shown[0].node
    }

    /// Looks forward for a target the tree does not hold yet. A list that
    /// loads its rows as it moves has only the rows near the screen in the
    /// tree: the tvOS probe's forty-row list showed 13, and each scroll to
    /// the lowest of them added one. Each step asks for the lowest element
    /// of a list to be scrolled into view, then reads the tree again once
    /// it has settled. It stops when the selector matches, when no anchor
    /// moves the tree along the axis (the end of the list), or after
    /// `maximum` steps. One way only, and never repeated.
    /// "Lowest" is for a search downward; `toward` makes it the highest,
    /// leftmost or rightmost instead. Returns the number of steps taken.
    func searchForward(maximum: Int, root: AccessibilityRequest.Token, session: any AccessibilityExchange,
                       displayHeight: Double, displayWidth: Double = .infinity, onSubmission: () -> Void,
                       pause: () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) throws -> Int {
        func layout(_ nodes: [AccessibilitySnapshot.Node]) -> [String] {
            nodes.map { "\($0.token.objectID) \($0.frame.map { "\($0.x) \($0.y) \($0.width) \($0.height)" } ?? "")" }
        }
        func reach(_ node: AccessibilitySnapshot.Node) -> Double { node.frame.map(toward.reach) ?? 0 }
        /// Where a node sits along the axis the search moves on.
        func position(_ node: AccessibilitySnapshot.Node) -> Double? {
            node.frame.map { toward == .down || toward == .up ? $0.y : $0.x }
        }
        /// Whether the tree moved along the search's axis. A strip that moves
        /// sideways during a search downward is another list, not progress.
        func progressed(_ before: [AccessibilitySnapshot.Node], _ after: [AccessibilitySnapshot.Node]) -> Bool {
            let positions = Dictionary(before.map { ($0.token.objectID, position($0)) }, uniquingKeysWith: { first, _ in first })
            let common = after.filter { positions[$0.token.objectID] != nil }
            guard !common.isEmpty else { return layout(after) != layout(before) }
            return common.contains { positions[$0.token.objectID] != .some(position($0)) }
        }
        /// The tree once it has stopped changing. A scroll is animated, and a
        /// list loads its next rows after it: read at once, the probe's list
        /// still had the old row as its lowest. Bounded: at most six reads.
        func settled() throws -> [AccessibilitySnapshot.Node] {
            var current = try AccessibilitySnapshot.normalize(session.snapshot(root), root: root)
            for _ in 0..<5 {
                pause()
                let next = try AccessibilitySnapshot.normalize(session.snapshot(root), root: root)
                if layout(next) == layout(current) { return next }
                current = next
            }
            return current
        }
        var steps = 0
        /// Candidates tried at this position that moved nothing along the axis.
        var failed = 0
        /// The line of the last anchor that moved the tree: the list being searched.
        var preferred: Double?
        while true {
            try Task.checkCancellation()
            let snapshot = try session.snapshot(root)
            if try !selector.matches(snapshot, root: root, failure: { failure($0, .transportFailed) }).isEmpty { return steps }
            let sent: CommandFailure.InputSent = steps > 0 ? .possible : .none
            guard steps < maximum else {
                throw failure("selector not found after \(steps) search step(s); the list was moved and not moved back", .targetUnresolved, inputSent: sent)
            }
            let nodes = try AccessibilitySnapshot.normalize(snapshot, root: root)
            // Not the list itself: a container taller than the display is the
            // lowest element of all once its content has grown, and scrolling
            // to it put the tvOS probe's list back at its top.
            let placed = nodes.dropFirst().filter {
                $0.token.pid == root.pid && ($0.frame?.height ?? 0) > 0 && ($0.frame?.height ?? 0) <= displayHeight
                    && ($0.frame?.width ?? 0) <= displayWidth
            }
            // Nor any other container: a strip as wide as the display reaches
            // further right than its last column. Elements without children.
            // And only ones that say what they are: the probe's tree also has
            // unnamed, hidden backdrops the size of the display.
            let leaves = placed.filter { $0.children.isEmpty && ($0.label != nil || $0.identifier != nil || $0.value != nil) }
            /// Where a node starts across the axis: the elements of one list
            /// share it (the probe's rows start at one x, its columns at one
            /// y). Their parents do not say: each row has a parent of its own.
            func line(_ node: AccessibilitySnapshot.Node) -> Double? {
                node.frame.map { toward == .down || toward == .up ? $0.x.rounded() : $0.y.rounded() }
            }
            // A screen can hold several lists, and the furthest element of
            // all may belong to another one: the tvOS probe's strip of
            // columns lies below its list of rows. So each line offers its
            // furthest element, and they are tried in turn until one moves
            // the tree along the axis: the line that moved last first, then
            // by reach. Hidden elements get no preference: the probe's rows
            // have hidden parts on screen, and a hidden row above the screen
            // moved a search downward back up.
            // A line with one element is no list along this axis (each
            // column of the strip, in a search downward), and scrolling to
            // it would move a list that runs the other way: such lines are
            // left out when another remains.
            var candidates: [AccessibilitySnapshot.Node] = []
            let groups = Dictionary(grouping: leaves.isEmpty ? Array(placed) : leaves, by: { line($0) ?? .nan }).values
            let along = groups.filter { Set($0.compactMap(position)).count > 1 }
            for group in along.isEmpty ? Array(groups) : along {
                if let furthest = group.max(by: { reach($0) < reach($1) }) { candidates.append(furthest) }
            }
            candidates.sort { first, second in
                let listed = (preferred != nil && line(first) == preferred, preferred != nil && line(second) == preferred)
                if listed.0 != listed.1 { return listed.0 }
                if reach(first) != reach(second) { return reach(first) > reach(second) }
                return first.token.objectID < second.token.objectID
            }
            guard !candidates.isEmpty else {
                throw failure("selector not found and the tree has no element to scroll from", .targetUnresolved, inputSent: sent)
            }
            guard failed < min(candidates.count, Self.searchCandidates) else {
                throw failure("selector not found: the list stopped moving after \(steps) search step(s)", .targetUnresolved, inputSent: sent)
            }
            let anchor = candidates[failed]
            _ = try session.performAction(anchor.token, action: .scrollToVisible, onSubmission: onSubmission)
            steps += 1
            let after = try settled()
            if progressed(Array(nodes), after) {
                failed = 0
                preferred = line(anchor)
            } else { failed += 1 }
        }
    }

    /// What an ambiguous selector matched, so the caller can choose a unique
    /// identifier or a position instead: at most five elements, in the
    /// order `--index` counts them, with their identifier, visibility and
    /// frame. Nothing is chosen for the caller.
    static func describe(_ nodes: [AccessibilitySnapshot.Node]) -> String {
        let listed = nodes.prefix(5).map { node -> String in
            var parts: [String] = []
            if case .string(let identifier) = node.identifier { parts.append("identifier '\(identifier.prefix(120))'") } else { parts.append("no identifier") }
            parts.append(node.visible.map { $0 ? "visible" : "hidden" } ?? "visibility unknown")
            if let frame = node.frame {
                parts.append("frame \(Int(frame.x.rounded())),\(Int(frame.y.rounded())) \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))")
            }
            return parts.joined(separator: ", ")
        }
        let more = nodes.count > listed.count ? "; and \(nodes.count - listed.count) more" : ""
        return "\(nodes.count) elements (\(listed.joined(separator: "; "))\(more)). Select one by a unique identifier, or by its position in this list with --index"
    }

    func execute(session: any AccessibilityExchange, display: () throws -> AccessibilityDisplay) throws -> Data {
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
            let process = try actionProcess(selected: selected.pid, session: session)
            stage = "application"
            let root = try session.application(pid: process)
            var searchSteps: Int?
            if let search, action == .scrollToVisible {
                stage = "search"
                searchSteps = try searchForward(maximum: search, root: root, session: session, displayHeight: geometry.bounds.height, displayWidth: geometry.bounds.width, onSubmission: { state = "search-submitted" })
            }
            stage = "first-snapshot"
            let first = try resolve(session.snapshot(root), root: root)
            stage = "second-snapshot"
            let target = try resolve(session.snapshot(root), root: root)
            guard sameIdentity(first.token, target.token) else { throw failure("selector identity changed between snapshots", .preconditionChanged) }
            stage = "live-attributes"
            let before = try liveState(target, session: session, requireVisible: action == .press)
            if action == .press {
                stage = "target-hit"
                try verifyHit(target, frame: before.frame, geometry: geometry, session: session)
            }
            stage = "application/display-recheck"
            try verifySelection(root, centre: selected.pid, geometry: geometry, session: session, display: display)
            stage = operation
            let native = try session.performAction(target.token, action: action, onSubmission: { state = "submitted" })
            var result: [String: Any] = ["backend": platform.backend, "operation": operation,
                "verified": false, "atomic": false,
                "application": applicationJSON(root.pid, centre: selected.pid, platform: platform),
                "selector": selector.json, "coordinateSpace": "device-logical-points",
                "limitations": ["Sequential guards are not atomic or a complete hittability check.",
                    "Unit attribute/action replies can lack target/sequence identity; one request is outstanding.",
                    "No coordinate fallback or automatic replay. Inspect a fresh observation before retrying."]]
            if action == .press {
                state = native ? "accepted" : "refused"
                guard native else { throw failure("native press was refused", .inputOutcomeUnknown, inputSent: .possible) }
                result["status"] = state
                result["nativeAccepted"] = true
                result["effectVerified"] = false
                result["target"] = before.json
            } else {
                state = native ? "native-true" : "native-false"
                result["nativeResult"] = native
                if let searchSteps { result["search"] = ["steps": searchSteps, "maximum": search ?? 0, "toward": toward.rawValue] }
                result["before"] = before.json
                stage = "post-action-observation"
                do {
                    let afterTarget = try resolve(session.snapshot(root), root: root)
                    guard sameIdentity(afterTarget.token, target.token) else { throw failure("target identity changed after scroll", .preconditionChanged) }
                    let after = try liveState(afterTarget, session: session, requireVisible: true)
                    try verifyHit(afterTarget, frame: after.frame, geometry: geometry, session: session)
                    try verifySelection(root, centre: selected.pid, geometry: geometry, session: session, display: display)
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
            // Before submission only read-only AX requests were sent; after it
            // the action may have reached the app whatever failed next.
            let failure = CommandFailure("\(error) \(detail)", wrapping: error)
            throw state == "not-sent" ? failure.noInputSent()
                : CommandFailure(.inputOutcomeUnknown, failure.description, inputSent: .possible)
        }
    }

    func liveState(_ target: AccessibilitySnapshot.Node, session: any AccessibilityExchange,
                           requireVisible: Bool) throws -> (frame: AccessibilitySnapshot.Frame, json: [String: Any]) {
        let live = try session.attributes([21, 25, 27, 32], of: target.token)
        guard case .dictionary(let fields) = live,
              fields["27"].flatMap(AccessibilityResponse.booleanResult) == true,
              let visible = fields["32"].flatMap(AccessibilityResponse.booleanResult),
              target.visible == visible, !requireVisible || visible else {
            throw failure("target enabled/visible state is unavailable, changed or unsuitable", .preconditionChanged)
        }
        if let identifier = target.identifier {
            guard case .string(let identifier) = identifier, fields["25"] == .string(identifier) else { throw failure("live identifier differs", .preconditionChanged) }
        }
        guard let frame = target.frame, frame.width > 0, frame.height > 0, let liveFrame = fields["21"],
              try AccessibilitySnapshot.rectangle(liveFrame) == frame else { throw failure("live geometry is unavailable or differs", .preconditionChanged) }
        guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any] else {
            throw failure("invalid internal target JSON", .internal)
        }
        for key in ["id", "parentId", "children", "depth"] { json.removeValue(forKey: key) }
        json["enabled"] = true
        json["visible"] = visible
        return (frame, json)
    }

    func verifyHit(_ target: AccessibilitySnapshot.Node, frame: AccessibilitySnapshot.Frame,
                           geometry: AccessibilityDisplay, session: any AccessibilityExchange) throws {
        // The element may reach past an edge: a web page zoomed by focusing a
        // field puts a 392-point field on a 375-point display. Its centre
        // must be on the display, and the hit test there must answer the
        // element itself, which is what says it can be pressed.
        let bounds = geometry.bounds
        let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
        guard x >= bounds.x, y >= bounds.y, x < bounds.x + bounds.width, y < bounds.y + bounds.height else {
            throw failure("target centre is outside the primary display", .targetUnresolved)
        }
        // An Apple TV has no pointer: activation goes to the element, not to
        // a point, and the hit test there can answer the system process.
        if geometry.focusDriven { return }
        let hit = try session.hit(x: x, y: y)
        guard try sameIdentity(hit, target.token) || sameElement(hit, as: target, frame: frame, session: session) else {
            throw failure("target centre hit is another native element", .targetUnresolved)
        }
    }

    /// The process the action runs in. Without `--pid`, or with the PID of
    /// the display-centre process, that process. With another PID, only the
    /// process that hosts the centre one: a web page's content process
    /// answers its snapshot rooted at the browser's remote element, and the
    /// browser's own controls (address bar, toolbar) are in the browser's
    /// tree. Any other PID is refused, as before. The guards that follow are
    /// unchanged, and the hit test at the target's centre still has to
    /// answer the target itself, in that process.
    func actionProcess(selected: Int32, session: any AccessibilityExchange) throws -> Int32 {
        guard let pid, pid != selected else { return selected }
        if pid == overlayProcess { return pid }
        let subject = session.platform.selectionSubject
        let page = try session.application(pid: selected)
        let nodes = try AccessibilitySnapshot.normalize(session.snapshot(page), root: page)
        guard let host = nodes.first, host.externalProcessReference == true, host.processIdentifier == pid else {
            throw failure("requested PID differs from \(subject) process and does not host it", .targetUnresolved)
        }
        return pid
    }

    /// `application` in a receipt: the process acted on and how it was chosen.
    func applicationJSON(_ process: Int32, centre: Int32, platform: AccessibilityPlatform) -> [String: Any] {
        guard process != centre else {
            return ["pid": process, "selection": pid == nil ? platform.selection : "explicit-pid+\(platform.selection)"]
        }
        if process == overlayProcess { return ["pid": process, "selection": "overlay-process", "frontmostPid": centre] }
        return ["pid": process, "selection": "explicit-pid-hosting-\(platform.selection)", "hostedPid": centre]
    }

    /// `centre` is the display-centre process seen at selection; it differs
    /// from `root.pid` only when the action runs in the process hosting it.
    func verifySelection(_ root: AccessibilityRequest.Token, centre: Int32? = nil, geometry: AccessibilityDisplay,
                                 session: any AccessibilityExchange, display: () throws -> AccessibilityDisplay) throws {
        let after = try session.application(pid: root.pid)
        guard sameIdentity(after, root) else { throw failure("application identity changed", .preconditionChanged) }
        let displayed = try session.foregroundProcess(geometry)
        guard displayed.pid == centre ?? root.pid else { throw failure("\(session.platform.selectionSubject) process changed", .preconditionChanged) }
        guard try display() == geometry else { throw failure("display geometry changed", .preconditionChanged) }
    }

    /// Whether a hit answered the target by another object. A plain table
    /// row has two: the cell, which a snapshot holds, and UIKit's element
    /// for it, which a hit test answers (an iOS 27.2 simulator, 2026-11-20:
    /// same identifier, label and frame, another object). It is the same
    /// element only if it is in the same process, has the target's frame,
    /// and has the target's identifier, or its label when it has no
    /// identifier; a view that merely covers the target has neither.
    func sameElement(_ hit: AccessibilityRequest.Token, as target: AccessibilitySnapshot.Node,
                     frame: AccessibilitySnapshot.Frame, session: any AccessibilityExchange) throws -> Bool {
        guard hit.pid == target.token.pid, case .dictionary(let fields) = try session.attributes([3, 21, 25], of: hit),
              let liveFrame = fields["21"], try AccessibilitySnapshot.rectangle(liveFrame) == frame else { return false }
        if case .string(let identifier)? = target.identifier, !identifier.isEmpty { return fields["25"] == .string(identifier) }
        if case .string(let label)? = target.label, !label.isEmpty { return fields["3"] == .string(label) }
        return false
    }

    func sameIdentity(_ a: AccessibilityRequest.Token, _ b: AccessibilityRequest.Token) -> Bool {
        a.pid == b.pid && a.objectID == b.objectID
    }
    func failure(_ reason: String, _ code: CommandFailure.Code, inputSent: CommandFailure.InputSent = .none) -> CommandFailure {
        CommandFailure(code, "Native AX \(operation): \(reason).", inputSent: inputSent)
    }
}

/// One exact identifier, label or value selector, shared by actions and waits so
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
    /// 1-based position among the distinct matching elements, in the tree's
    /// node order (the order an ambiguous-selector failure lists them); nil
    /// requires the selector to settle on one element by itself.
    var index: Int? = nil

    static let indexOption = "--index"
    static let indexRange = 1...512

    /// The node fields a selector can compare, by the suffix of the internal
    /// operation name (`press-id`, `wait-label`, `set-value-value`). `value`
    /// is for elements with neither label nor identifier, such as a search
    /// field that only carries its placeholder.
    static let kinds: [(suffix: String, by: String)] = [("id", "identifier"), ("label", "label"), ("value", "value")]

    /// `press` gives `press-id`, `press-label` and `press-value`.
    static func operations(_ base: String) -> [String] { kinds.map { "\(base)-\($0.suffix)" } }

    /// The field an operation name selects by; `label` for anything else.
    static func by(operation: String) -> String {
        let suffix = operation.split(separator: "-").last.map(String.init) ?? ""
        return kinds.first { $0.suffix == suffix }?.by ?? "label"
    }

    /// The operation-name suffix for a field name, the inverse of `by(operation:)`.
    static func suffix(by: String) -> String { kinds.first { $0.by == by }?.suffix ?? "label" }

    /// The selector as receipts and plans print it.
    var json: [String: Any] {
        var json: [String: Any] = ["by": by, "text": text]
        if let index { json["index"] = index }
        return json
    }

    /// Removes a trailing `--index <n>` from positional selector operands.
    /// `minimumCount` is the smallest operand count that can carry one, so a
    /// selector or value that is itself "--index" is not mistaken for it.
    static func takeIndex(_ operands: inout [String], minimumCount: Int) throws -> Int? {
        guard operands.count >= minimumCount, operands[operands.count - 2] == indexOption else { return nil }
        let index = try parseIndex(operands[operands.count - 1])
        operands.removeLast(2)
        return index
    }

    static func parseIndex(_ text: String) throws -> Int {
        guard let index = Int(text), indexRange.contains(index) else {
            throw CommandFailure.usage("\(indexOption) must be a whole number in \(indexRange.lowerBound)...\(indexRange.upperBound): the position among the matching elements, counted from 1.")
        }
        return index
    }

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
            let value = by == "identifier" ? node.identifier : by == "value" ? node.value : node.label
            if value == .string(text) { found.append(Match(node: node, attributes: attributes)) }
        }
        return found
    }
}
