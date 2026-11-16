import Foundation

/// A read-only, bounded wait for an exact-selector condition inside one AX
/// session. Each poll is a fresh, non-atomic snapshot; no input is sent and
/// no action handle survives between polls.
struct AccessibilityWait {
    enum Condition: Equatable, Sendable {
        /// Exactly one matching identity, visible in the snapshot.
        case visible
        /// No match, or every match explicitly not visible.
        case gone
        /// `visible`, and the live enabled attribute is true / false.
        case enabled, disabled
        /// `visible`, and the snapshot value is exactly this string.
        case value(String)
        /// `visible`, and the live focused attribute (28) is true: the
        /// Apple TV focus (docs/other-families.md).
        case focused

        var name: String {
            switch self {
            case .visible: "visible"
            case .gone: "gone"
            case .enabled: "enabled"
            case .disabled: "disabled"
            case .value: "value"
            case .focused: "focused"
            }
        }
    }

    static let operations = ["wait-id", "wait-label"]
    static let optionNames: Set<String> = ["--until", "--value", "--timeout", "--interval"]
    static let conditionNames = ["visible", "gone", "enabled", "disabled", "value", "focused"]
    static let timeoutRange: ClosedRange<Double> = 0...60
    static let intervalRange: ClosedRange<Double> = 0.25...5
    static let defaultTimeout = 10.0
    static let defaultInterval = 0.5
    /// Distinct from 1 (failure) and 130/143 (signals); GNU timeout's value.
    static let timeoutExitCode: Int32 = 124

    let pid: Int32?
    let selector: AccessibilitySelector
    let condition: Condition
    let timeoutMilliseconds: Int64
    let intervalMilliseconds: Int64

    var timeout: Duration { .milliseconds(timeoutMilliseconds) }
    var interval: Duration { .milliseconds(intervalMilliseconds) }
    /// An upper bound: polls normally drift apart because each one takes time.
    var maximumPolls: Int { Int(timeoutMilliseconds / intervalMilliseconds) + 2 }

    /// One session lasts the whole wait, so its budgets scale with the poll
    /// bound instead of the 30-second/256-frame single-observation defaults.
    /// A poll is at most five requests (hit, application, snapshot, live
    /// attributes, recheck), two or more frames each.
    var sessionLimits: AccessibilitySession.Limits {
        .init(lifetime: timeout + .seconds(30), frames: 64 + 16 * maximumPolls,
              callbackBytes: max(40 * 1024 * 1024, 4 * 1024 * 1024 * maximumPolls))
    }

    private static let usage = "Native AX wait usage: wait (--id <identifier> | --label <label>) [--pid <positive-pid>] [--until visible|gone|enabled|disabled|value|focused] [--value <exact-text>] [--timeout <seconds 0...60, default 10>] [--interval <seconds 0.25...5, default 0.5>]."

    init(_ input: CoreDeviceInput) throws {
        guard Self.operations.contains(input.operation), !input.operands.isEmpty else { throw Self.invalid("") }
        let operands = input.operands
        // The first operand is always positional, so a selector may itself
        // begin with "--"; options start at the first later option name.
        var end = 1
        while end < operands.count, !Self.optionNames.contains(operands[end]) { end += 1 }
        guard end <= 2 else { throw Self.invalid("Expected an optional positive PID and one exact selector before options.") }
        if end == 2 {
            guard let pid = Int32(operands[0]), pid > 0 else { throw Self.invalid("PID must be in 1...2147483647.") }
            self.pid = pid
        } else { pid = nil }
        let text = operands[end - 1]
        guard (1...4096).contains(text.utf8.count), !text.contains("\0") else {
            throw Self.invalid("Selector must be 1...4096 UTF-8 bytes without NUL.")
        }
        selector = AccessibilitySelector(by: input.operation == "wait-id" ? "identifier" : "label", text: text)
        var until: String?, value: String?, timeout: Double?, interval: Double?
        var index = end
        while index < operands.count {
            let name = operands[index]
            guard Self.optionNames.contains(name) else { throw Self.invalid("Unknown option or extra operand: \(name).") }
            guard index + 1 < operands.count else { throw Self.invalid("\(name) requires a value.") }
            let argument = operands[index + 1]
            func seconds(_ range: ClosedRange<Double>) throws -> Double {
                guard let number = Double(argument), number.isFinite, range.contains(number) else {
                    throw Self.invalid("\(name) must be a number of seconds in " + String(format: "%g...%g.", range.lowerBound, range.upperBound))
                }
                return number
            }
            switch name {
            case "--until":
                guard until == nil, Self.conditionNames.contains(argument) else { throw Self.invalid("--until must appear once, as visible, gone, enabled, disabled, value or focused.") }
                until = argument
            case "--value":
                guard value == nil, (1...4096).contains(argument.utf8.count), !argument.contains("\0") else {
                    throw Self.invalid("--value must appear once, with 1...4096 UTF-8 bytes without NUL.")
                }
                value = argument
            case "--timeout":
                guard timeout == nil else { throw Self.invalid("--timeout must appear once.") }
                timeout = try seconds(Self.timeoutRange)
            default:
                guard interval == nil else { throw Self.invalid("--interval must appear once.") }
                interval = try seconds(Self.intervalRange)
            }
            index += 2
        }
        switch (until, value) {
        case (nil, nil), ("visible", nil): condition = .visible
        case (nil, let value?), ("value", let value?): condition = .value(value)
        case ("value", nil): throw Self.invalid("--until value requires --value <exact-text>.")
        case (_, .some): throw Self.invalid("--value applies only to --until value.")
        case ("gone", nil): condition = .gone
        case ("enabled", nil): condition = .enabled
        case ("focused", nil): condition = .focused
        default: condition = .disabled
        }
        timeoutMilliseconds = Int64(((timeout ?? Self.defaultTimeout) * 1000).rounded())
        intervalMilliseconds = Int64(((interval ?? Self.defaultInterval) * 1000).rounded())
    }

    private static func invalid(_ reason: String) -> CommandFailure {
        CommandFailure.usage(reason.isEmpty ? usage : "\(reason) \(usage)")
    }

    /// A timeout is an answer with structured output, not a malfunction.
    static func output(_ data: Data) throws -> CommandOutput {
        let status = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
        return CommandOutput(data: data, exitCode: status == "timed-out" ? timeoutExitCode : 0)
    }

    var conditionJSON: [String: Any] {
        var value: [String: Any] = ["until": condition.name]
        if case .value(let text) = condition { value["value"] = text }
        return value
    }

    func plan(identityArguments: [String]) -> [String: Any] {
        ["backend": "coredevice-direct", "operation": "wait", "readOnly": true, "inputSent": false,
         "deviceLease": "not taken (observation)", "selector": ["by": selector.by, "text": selector.text],
         "pid": pid.map { Int($0) as Any } ?? NSNull(), "condition": conditionJSON,
         "timeoutSeconds": Double(timeoutMilliseconds) / 1000, "intervalSeconds": Double(intervalMilliseconds) / 1000,
         "maximumPolls": maximumPolls, "timeoutExitCode": Int(Self.timeoutExitCode),
         "identityArguments": identityArguments, "liveVerified": false,
         "execution": "Native Apple tunnel assertion, exact-address RSD discovery and one raw AX DTX session for the whole wait. Omitted PID requires an awake portrait primary display and re-selects its centre process on every poll; an explicit PID is observed even in the background. Each poll reads application identity and one bounded snapshot, evaluates the exact selector, and rechecks the selection before reporting a met condition. No input, fallback or reconnection."]
    }

    // MARK: - Execution

    struct Observation {
        let pid: Int32
        var met: Bool
        var reason: String
        var detail: String
        var matchCount = 0
        var matchPaths = 0
        var foreignMatches = 0
        var element: [String: Any]?

        var json: [String: Any] {
            var value: [String: Any] = ["pid": Int(pid), "conditionMet": met, "reason": reason, "detail": detail,
                "matchCount": matchCount, "matchPaths": matchPaths, "foreignProcessMatches": foreignMatches]
            value["element"] = element ?? NSNull()
            return value
        }
    }

    /// Distinct observed PIDs in order (bounded) and how often the observed
    /// process changed from one poll to the next.
    private struct ProcessHistory {
        var observed: [Int32] = []
        var changes = 0
        var last: Int32?
        mutating func record(_ pid: Int32) {
            if let last, last != pid { changes += 1 }
            last = pid
            if !observed.contains(pid), observed.count < 16 { observed.append(pid) }
        }
    }

    /// Holds the actor/queue only while a poll's blocking requests run; the
    /// interval between polls is a suspension, so other work can interleave.
    func execute<C: Clock>(device: String, resolved: String, session: any AccessibilityExchange,
                           display: () throws -> AccessibilityDisplay, clock: C,
                           isolation: isolated (any Actor)? = #isolation) async throws -> Data where C.Duration == Duration {
        defer { session.close() }
        let platform = session.platform
        var stage = "display"
        var polls = 0
        var last: Observation?
        var history = ProcessHistory()
        let start = clock.now
        do {
            // Display geometry is read before subscribing, as for a tree.
            let selectedDisplay: AccessibilityDisplay? = pid == nil ? try display() : nil
            stage = "start"
            try session.start()
            let deadline = start.advanced(by: timeout)
            while true {
                try Task.checkCancellation()
                polls += 1
                let observation = try poll(session, display: selectedDisplay, stage: &stage)
                history.record(observation.pid)
                last = observation
                if observation.met { break }
                let now = clock.now
                if now >= deadline || polls >= maximumPolls { break }
                stage = "interval"
                try await clock.sleep(until: min(now.advanced(by: interval), deadline), tolerance: nil)
            }
            let elapsed = start.duration(to: clock.now)
            guard let last else { throw failure("no observation was made", .internal) }
            var displayRecheck: String?
            if let selectedDisplay {
                stage = "display-recheck"
                if last.met {
                    guard try display() == selectedDisplay else {
                        throw failure("display geometry/orientation changed during the wait; the condition is not reported", .preconditionChanged)
                    }
                    displayRecheck = "unchanged"
                } else {
                    // A timeout stays an answer; say whether the screen moved.
                    do { displayRecheck = try display() == selectedDisplay ? "unchanged" : "changed" }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        displayRecheck = "unavailable: \(String(String(describing: error).prefix(500)))"
                    }
                }
            }
            try Task.checkCancellation()
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            try Task.checkCancellation()
            var result: [String: Any] = ["backend": platform.backend, "operation": "wait", "readOnly": true, "inputSent": false,
                "device": device, platform.resolvedKey: resolved,
                "status": last.met ? "condition-met" : "timed-out", "conditionMet": last.met,
                "selector": ["by": selector.by, "text": selector.text], "condition": conditionJSON,
                "timeoutSeconds": Double(timeoutMilliseconds) / 1000, "intervalSeconds": Double(intervalMilliseconds) / 1000,
                "elapsedSeconds": Self.seconds(elapsed), "polls": polls,
                "application": ["pid": Int(last.pid), "selection": pid == nil ? "\(platform.selection)-per-poll" : "explicit-pid"],
                "processesObserved": history.observed.map(Int.init), "processChanges": history.changes,
                "observation": last.json, "atomic": false, "coordinateSpace": "device-logical-points",
                "cleanup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup)),
                "limitations": limitations(platform)]
            if let selectedDisplay {
                result["display"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selectedDisplay))
            }
            if let displayRecheck { result["displayRecheck"] = displayRecheck }
            if !last.met {
                result["timeoutReason"] = polls >= maximumPolls && elapsed < timeout
                    ? "poll bound reached before the deadline" : "deadline reached"
            }
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let cleanup = DirectPhysicalAccessibility.Cleanup(session.close())
            var detail = "AX wait stage=\(stage), polls=\(polls), elapsed=\(Self.seconds(start.duration(to: clock.now)))s. No input was sent; no reconnection or retry."
            if let last { detail += " Last observation: pid=\(last.pid), reason=\(last.reason)." }
            detail += " Subscription cleanup: \(cleanup.subscriptionStop); confirmed=\(cleanup.confirmed). \(cleanup.diagnostic ?? "")"
            if error is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("Native AX wait cancelled. \(detail)\n".utf8))
                throw CancellationError()
            }
            // A wait only reads, so nothing was sent whatever failed.
            throw CommandFailure("\(platform.failurePrefix) wait failed: \(error) \(detail)", wrapping: error).noInputSent()
        }
    }

    private func limitations(_ platform: AccessibilityPlatform) -> [String] { [
        "Each poll is a separate non-atomic snapshot; a state shorter than the interval can be missed, and descendants can change during a poll.",
        pid == nil ? platform.waitSelectionLimitation
            : "An explicit PID may be a background app. If it exits, the wait ends as a session failure, not as gone.",
        "Visibility is the native snapshot attribute, not hittability or pixel verification; a missing attribute never satisfies a condition.",
        "One AX session serves the whole wait; a transport or session failure ends it without reconnection.",
        platform.cleanupLimitation
    ] }

    private func poll(_ session: any AccessibilityExchange, display: AccessibilityDisplay?, stage: inout String) throws -> Observation {
        stage = "select-process"
        let selected: Int32
        if let pid { selected = pid }
        else if let display { selected = try session.foregroundProcess(display).pid }
        else { throw failure("missing process selection", .internal) }
        stage = "application"
        let root = try session.application(pid: selected)
        stage = "snapshot"
        let matches = try selector.matches(session.snapshot(root), root: root, failure: { failure($0, .transportFailed) })
        var observation = try evaluate(matches, root: root, session: session, stage: &stage)
        if observation.met {
            // A met condition counts only if the poll's selection held.
            stage = "selection-recheck"
            let after = try session.application(pid: selected)
            var stable = after.pid == root.pid && after.objectID == root.objectID
            if stable, let display { stable = try session.foregroundProcess(display).pid == selected }
            if !stable {
                observation.met = false
                observation.reason = "selection-changed"
                observation.detail = "The application identity or \(session.platform.selectionSubject) process changed during the poll."
            }
        }
        return observation
    }

    private func evaluate(_ matches: [AccessibilitySelector.Match], root: AccessibilityRequest.Token,
                          session: any AccessibilityExchange, stage: inout String) throws -> Observation {
        let local = matches.filter { $0.node.token.pid == root.pid }
        var distinct: [AccessibilitySelector.Match] = []
        var inconsistent = false
        for match in local {
            if let first = distinct.first(where: { $0.node.token.pid == match.node.token.pid && $0.node.token.objectID == match.node.token.objectID }) {
                if first.attributes != match.attributes { inconsistent = true }
            } else { distinct.append(match) }
        }
        var observation = Observation(pid: root.pid, met: false, reason: "", detail: "")
        observation.matchCount = distinct.count
        observation.matchPaths = matches.count
        observation.foreignMatches = matches.count - local.count
        if distinct.count == 1 { observation.element = try Self.describe(distinct[0].node) }

        if condition == .gone {
            let shown = matches.filter { $0.node.visible == true }.count
            let unknown = matches.filter { $0.node.visible == nil }.count
            if matches.isEmpty {
                observation.met = true; observation.reason = "absent"; observation.detail = "No element matches the exact selector."
            } else if shown == 0 && unknown == 0 {
                observation.met = true; observation.reason = "not-visible"
                observation.detail = "Every matching element (\(matches.count) path(s)) is explicitly not visible."
            } else if shown > 0 {
                observation.reason = "still-visible"; observation.detail = "\(shown) matching path(s) are visible."
            } else {
                observation.reason = "visibility-unknown"; observation.detail = "\(unknown) matching path(s) have no visibility attribute."
            }
            return observation
        }

        guard !matches.isEmpty else {
            observation.reason = "no-match"; observation.detail = "No element matches the exact selector in the bounded snapshot."
            return observation
        }
        guard observation.foreignMatches == 0 else {
            observation.reason = "foreign-process"; observation.detail = "A match is a reference into another process and cannot be evaluated here."
            return observation
        }
        // A list row and the text inside it often share one label, with only the
        // row visible (observed in Settings). When exactly one match is visible
        // and every other is explicitly hidden, the visible one is the element.
        // Any match with unknown visibility keeps the result ambiguous.
        var candidates = distinct
        if candidates.count > 1, candidates.allSatisfy({ $0.node.visible != nil }) {
            let shown = candidates.filter { $0.node.visible == true }
            if shown.count == 1 {
                candidates = shown
                observation.element = try Self.describe(shown[0].node)
            }
        }
        guard candidates.count == 1 else {
            observation.reason = "ambiguous"; observation.detail = "\(distinct.count) distinct elements match; the condition needs exactly one visible."
            return observation
        }
        guard !inconsistent else {
            observation.reason = "inconsistent-duplicates"; observation.detail = "Repeated paths for one element carry different attributes."
            return observation
        }
        let node = candidates[0].node
        guard let visible = node.visible else {
            observation.reason = "visibility-unknown"; observation.detail = "The element has no visibility attribute."
            return observation
        }
        guard visible else {
            observation.reason = "not-visible"; observation.detail = "The element is present but not visible."
            return observation
        }
        if case .value(let expected) = condition, node.value != .string(expected) {
            observation.reason = "value-differs"
            observation.detail = node.value == nil ? "The element has no value." : "The element's value differs from the expected exact text."
            return observation
        }
        stage = "live-attributes"
        // Focus is read only for the focused condition, so other waits send
        // exactly the requests they always did.
        let live = try session.attributes(condition == .focused ? [27, 32, AccessibilityRequest.focusedAttribute] : [27, 32], of: node.token)
        guard case .dictionary(let fields) = live else { throw failure("live attributes are not a dictionary", .transportFailed) }
        let enabled = fields["27"].flatMap(AccessibilityResponse.booleanResult)
        observation.element?["enabled"] = enabled ?? NSNull()
        if let liveVisible = fields["32"].flatMap(AccessibilityResponse.booleanResult), !liveVisible {
            observation.reason = "live-visibility-differs"; observation.detail = "The live visibility attribute disagrees with the snapshot."
            return observation
        }
        switch condition {
        case .enabled, .disabled:
            let wanted = condition == .enabled
            guard let enabled else {
                observation.reason = "enabled-unknown"; observation.detail = "The live enabled attribute is unavailable."
                return observation
            }
            guard enabled == wanted else {
                observation.reason = wanted ? "not-enabled" : "still-enabled"
                observation.detail = wanted ? "The element is visible but disabled." : "The element is visible and enabled."
                return observation
            }
        case .focused:
            let focused = fields[String(AccessibilityRequest.focusedAttribute)].flatMap(AccessibilityResponse.booleanResult)
            observation.element?["focused"] = focused ?? NSNull()
            guard let focused else {
                observation.reason = "focus-unknown"; observation.detail = "The live focused attribute is unavailable."
                return observation
            }
            guard focused else {
                observation.reason = "not-focused"; observation.detail = "The element is visible but does not have focus."
                return observation
            }
        default: break
        }
        observation.met = true
        observation.reason = condition.name
        observation.detail = "Exactly one matching element satisfies the condition."
        return observation
    }

    private static func describe(_ node: AccessibilitySnapshot.Node) throws -> [String: Any] {
        guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any] else {
            throw CommandFailure(.internal, "Invalid internal wait element JSON.", inputSent: .none)
        }
        for key in ["id", "parentId", "children", "depth", "attributeSource"] { json.removeValue(forKey: key) }
        json["visible"] = node.visible.map { $0 as Any } ?? NSNull()
        return json
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return (value * 1000).rounded() / 1000
    }

    private func failure(_ reason: String, _ code: CommandFailure.Code) -> CommandFailure {
        CommandFailure(code, "Native AX wait: \(reason).", inputSent: .none)
    }
}
