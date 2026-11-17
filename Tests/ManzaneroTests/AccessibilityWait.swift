import Darwin
import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

/// Time that moves only when the code under test sleeps: each sleep jumps to
/// its deadline. Poll counts and elapsed time are therefore exact.
final class VirtualTestClock: Clock, Sendable {
    typealias Instant = ManualTestClock.Instant
    private struct State { var now = Instant(offset: .zero); var sleeps = 0 }
    private let state = Mutex(State())
    var now: Instant { state.withLock { $0.now } }
    var sleeps: Int { state.withLock { $0.sleeps } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            if state.now < deadline { state.now = deadline }
            state.sleeps += 1
        }
    }
}

struct AccessibilityWaitTests {
    struct Element {
        var id = 2
        var identifier: String? = "fixture.target"
        var label: String? = "Target"
        var value: String?
        var visible: Bool? = true
        var enabled: Bool? = true
        var liveVisible: Bool?
        var foreignPID: Int32?
    }

    struct Screen {
        var pid: Int32 = 42
        var elements: [Element] = []
    }

    /// A scripted AX peer. Requests see the screen of the current poll, which
    /// the test derives from its clock; no request reaches a device.
    final class Wire: AccessibilitySessionTransport {
        let screen: (Int) -> Screen
        let poll: () -> Int
        /// (request type, poll, mode): "cancel", "eof" or "exited".
        var failure: (kind: UInt64, poll: Int, mode: String)?
        var unstableRecheckPolls: Set<Int> = []
        var onSnapshot: (() -> Void)?
        var incoming: [AccessibilityDTX] = []
        var kinds: [UInt64] = []
        var snapshots = 0, disables = 0
        var closed = false
        private var applicationsInPoll: [Int: Int] = [:]

        init(poll: @escaping () -> Int, screen: @escaping (Int) -> Screen) { self.poll = poll; self.screen = screen }

        func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
            guard !incoming.isEmpty else { throw CommandFailure(description: "Fixture EOF") }
            return incoming.removeFirst()
        }
        func close() { closed = true }

        func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
            guard message.kind == .invocation else { return }
            let fixture = AccessibilitySessionTests()
            let selector = try KeyedArchiveInspector.decodeProtocol(message.object)
            if selector == .string("deviceAPIVersion") {
                incoming.append(try fixture.reply(message.identifier, value: NSNumber(value: 26))); return
            }
            if selector == .string("clientNeedsAccessibility:") {
                if try KeyedArchiveInspector.decodeProtocol(message.archiveArgument()) == .boolean(false) { disables += 1 }
                incoming.append(try fixture.reply(message.identifier)); return
            }
            guard case .object("AXPTranslatorRequest", let fields) = try KeyedArchiveInspector.decodeProtocol(message.archiveArgument()),
                  let kind = fields["requestType"]?.unsignedInteger else { throw CommandFailure(description: "Bad fixture request") }
            kinds.append(kind)
            let current = poll(), state = screen(current)
            if let failure, failure.kind == kind, failure.poll == current {
                if failure.mode == "cancel" { throw CancellationError() }
                if failure.mode == "eof" { return }
            }
            let response: Response
            switch kind {
            case 1:
                applicationsInPoll[current, default: 0] += 1
                guard case .dictionary(let parameters) = fields["parameters"], let requested = parameters["pid"]?.unsignedInteger,
                      let pid = Int32(exactly: requested) else { throw CommandFailure(description: "Bad fixture application request") }
                let exited = failure.map { $0.kind == 1 && $0.poll == current && $0.mode == "exited" } ?? false
                let recheck = applicationsInPoll[current] == 2 && unstableRecheckPolls.contains(current)
                response = Response(kind: kind, result: Token(recheck ? 9 : 1, pid: exited ? pid + 1 : pid, application: true))
            case 2:
                snapshots += 1
                onSnapshot?()
                response = Response(kind: kind, translation: Token(1, pid: state.pid, application: true),
                    result: record(Token(1, pid: state.pid, application: true), label: "App", identifier: "app", visible: true,
                                   children: state.elements.map(record)))
            case 5:
                let element = state.elements.first { $0.foreignPID == nil } ?? Element()
                var live: [Int: Any] = [:]
                if let enabled = element.enabled { live[27] = NSNumber(value: enabled) }
                if let visible = element.liveVisible ?? element.visible { live[32] = NSNumber(value: visible) }
                response = Response(kind: kind, result: live as NSDictionary)
            case 6:
                response = Response(kind: kind, result: Token(7, pid: state.pid))
            default:
                throw CommandFailure(description: "Unexpected fixture request type \(kind); waits never act.")
            }
            incoming.append(try callback(response))
            incoming.append(try fixture.reply(message.identifier))
        }

        private func record(_ element: Element) -> NSDictionary {
            var attributes: [Int: Any] = [:]
            if element.foreignPID != nil { attributes[5003] = "AXRemoteElement" }
            return record(Token(element.id, pid: element.foreignPID ?? screen(poll()).pid), label: element.label,
                          identifier: element.identifier, value: element.value, visible: element.visible, extra: attributes)
        }

        private func record(_ token: Token, label: String?, identifier: String?, value: String? = nil, visible: Bool?,
                            children: [NSDictionary] = [], extra: [Int: Any] = [:]) -> NSDictionary {
            var attributes = extra
            attributes[2001] = label
            attributes[5019] = identifier
            attributes[2006] = value
            attributes[2025] = visible.map { NSNumber(value: $0) }
            attributes[2003] = NSValue(rect: NSRect(x: 10, y: 20, width: 30, height: 40))
            return ["UIAccessibilitySnapshotKeyElement": token, "UIAccessibilitySnapshotKeyChildren": children,
                    "UIAccessibilitySnapshotKeyChildrenCount": children.count,
                    "UIAccessibilitySnapshotKeyAttributes": attributes as NSDictionary] as NSDictionary
        }

        private func callback(_ response: Response) throws -> AccessibilityDTX {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            coder.setClassName("AXPTranslatorResponse", for: Response.self)
            coder.setClassName("AXPTranslationObject", for: Token.self)
            coder.encode(response, forKey: NSKeyedArchiveRootObjectKey); coder.finishEncoding()
            if let error = coder.error { throw error }
            return try AccessibilityDTX.invocation("processDataFromRemoteDevice:", argument: coder.encodedData as NSData, identifier: 90)
        }
    }

    @objc(ADCAXWaitTestToken)
    final class Token: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let id: Int
        let pid: Int32
        let application: Bool
        init(_ id: Int, pid: Int32, application: Bool = false) { self.id = id; self.pid = pid; self.application = application }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(pid, forKey: "pid"); coder.encode(NSNumber(value: id), forKey: "objectID")
            coder.encode(application, forKey: "isApplicationElement"); coder.encode(true, forKey: "didPopuldateAppInfo")
            coder.encode(nil as NSObject?, forKey: "rawElementData"); coder.encode(nil as NSObject?, forKey: "bridgeDelegateToken")
        }
    }

    @objc(ADCAXWaitTestResponse)
    final class Response: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: UInt64
        let translation: Token?
        let result: NSObject
        init(kind: UInt64, translation: Token? = nil, result: NSObject) { self.kind = kind; self.translation = translation; self.result = result }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(Int(kind), forKey: "associatedRequestType"); coder.encode(kind == 2 ? 52 : 0, forKey: "attribute")
            coder.encode(0, forKey: "error"); coder.encode(0, forKey: "notification")
            coder.encode(translation, forKey: "associatedTranslationObject"); coder.encode(result, forKey: "resultData")
        }
    }

    // MARK: - Helpers

    static func wait(_ operands: [String], operation: String = "wait-id") throws -> AccessibilityWait {
        try AccessibilityWait(CoreDeviceInput(device: "fixture", operation: operation, operands: operands))
    }

    struct Run {
        let wire: Wire
        let displays: Int
        let result: Result<[String: Any], any Error>
        var json: [String: Any]? { try? result.get() }
        var observation: [String: Any]? { json?["observation"] as? [String: Any] }
        var element: [String: Any]? { observation?["element"] as? [String: Any] }
        var error: String { if case .failure(let error) = result { return String(describing: error) }; return "" }
    }

    /// Runs one wait against a scripted screen sequence on virtual time.
    func run(_ operands: [String], operation: String = "wait-id", display: @escaping (Int) throws -> Data = { _ in try AccessibilityDisplayTests.data() },
             configure: (Wire) -> Void = { _ in }, screen: @escaping (Int) -> Screen) async throws -> Run {
        let clock = VirtualTestClock()
        let wire = Wire(poll: { clock.sleeps + 1 }, screen: screen)
        configure(wire)
        let wait = try Self.wait(operands, operation: operation)
        var displays = 0
        let result: Result<[String: Any], any Error>
        do {
            let data = try await wait.execute(device: "fixture", resolved: "resolved", session: AccessibilitySession(transport: wire, limits: wait.sessionLimits),
                                              display: { displays += 1; return try AccessibilityDisplay(display(displays)) }, clock: clock)
            result = .success(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        } catch { result = .failure(error) }
        return Run(wire: wire, displays: displays, result: result)
    }

    // MARK: - Conditions over time

    @Test func appearsAfterSeveralPollsInOneSession() async throws {
        let run = try await run(["fixture.target", "--timeout", "5"]) { poll in
            Screen(elements: poll < 3 ? [] : [Element()])
        }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "condition-met" && json["conditionMet"] as? Bool == true)
        #expect(json["polls"] as? Int == 3 && json["elapsedSeconds"] as? Double == 1.0)
        #expect(run.element?["identifier"] as? String == "fixture.target" && run.element?["label"] as? String == "Target")
        #expect(run.element?["enabled"] as? Bool == true && run.element?["visible"] as? Bool == true)
        #expect((run.element?["frame"] as? [String: Any])?["width"] as? Int == 30)
        #expect(run.observation?["matchCount"] as? Int == 1)
        #expect((json["application"] as? [String: Any])?["selection"] as? String == "centre-hit-test-per-poll")
        #expect(json["displayRecheck"] as? String == "unchanged" && run.displays == 2)
        #expect((json["cleanup"] as? [String: Any])?["confirmed"] as? Bool == true)
        #expect(json["readOnly"] as? Bool == true && json["inputSent"] as? Bool == false)
        // One subscription for the whole wait, then exactly one disable.
        #expect(run.wire.snapshots == 3 && run.wire.disables == 1 && run.wire.closed)
        #expect(!run.wire.kinds.contains(7))
        #expect(try AccessibilityWait.output(JSONSerialization.data(withJSONObject: json)).exitCode == 0)
    }

    @Test func alreadyPresentSucceedsOnTheFirstPollWithoutSleeping() async throws {
        let run = try await run(["fixture.target"]) { _ in Screen(elements: [Element()]) }
        let json = try #require(run.json)
        #expect(json["polls"] as? Int == 1 && json["elapsedSeconds"] as? Double == 0)
        // hit, application, snapshot, live attributes, application + hit recheck.
        #expect(run.wire.kinds == [6, 1, 2, 5, 1, 6])
    }

    @Test func neverAppearingTimesOutAsAnAnswerWithTheLastObservation() async throws {
        let run = try await run(["fixture.target", "--timeout", "2", "--interval", "0.5"]) { _ in Screen() }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "timed-out" && json["conditionMet"] as? Bool == false)
        #expect(json["polls"] as? Int == 5 && json["elapsedSeconds"] as? Double == 2.0)
        #expect(json["timeoutReason"] as? String == "deadline reached")
        #expect(run.observation?["reason"] as? String == "no-match" && run.observation?["element"] is NSNull)
        #expect(json["displayRecheck"] as? String == "unchanged")
        #expect((json["cleanup"] as? [String: Any])?["subscriptionStop"] as? String == "acknowledged")
        #expect(try AccessibilityWait.output(JSONSerialization.data(withJSONObject: json)).exitCode == AccessibilityWait.timeoutExitCode)
    }

    @Test func zeroTimeoutChecksExactlyOnce() async throws {
        let run = try await run(["fixture.target", "--timeout", "0"]) { _ in Screen() }
        #expect(run.json?["polls"] as? Int == 1 && run.json?["status"] as? String == "timed-out")
    }

    @Test(arguments: ["absent", "not-visible"])
    func goneIsMetWhenTheElementDisappearsOrHides(_ outcome: String) async throws {
        let run = try await run(["fixture.target", "--until", "gone"]) { poll in
            if poll < 3 { return Screen(elements: [Element()]) }
            return Screen(elements: outcome == "absent" ? [] : [Element(visible: false)])
        }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "condition-met" && json["polls"] as? Int == 3)
        #expect(run.observation?["reason"] as? String == outcome)
        #expect((json["condition"] as? [String: Any])?["until"] as? String == "gone")
        #expect(!run.wire.kinds.contains(5))
    }

    @Test func goneNeverTreatsMissingVisibilityAsHidden() async throws {
        let run = try await run(["fixture.target", "--until", "gone", "--timeout", "1"]) { _ in
            Screen(elements: [Element(visible: nil)])
        }
        #expect(run.json?["status"] as? String == "timed-out")
        #expect(run.observation?["reason"] as? String == "visibility-unknown")
    }

    @Test func ambiguityIsCountedAndNeverSatisfiesAPositiveCondition() async throws {
        let ambiguous = try await run(["fixture.target", "--timeout", "1"]) { _ in
            Screen(elements: [Element(id: 2), Element(id: 3)])
        }
        #expect(ambiguous.json?["status"] as? String == "timed-out")
        #expect(ambiguous.observation?["reason"] as? String == "ambiguous" && ambiguous.observation?["matchCount"] as? Int == 2)
        #expect(ambiguous.observation?["element"] is NSNull)
        // Repeated paths for one identity with equal attributes are one element.
        let repeated = try await run(["fixture.target"]) { _ in Screen(elements: [Element(id: 2), Element(id: 2)]) }
        #expect(repeated.json?["status"] as? String == "condition-met")
        #expect(repeated.observation?["matchCount"] as? Int == 1 && repeated.observation?["matchPaths"] as? Int == 2)
        // Gone needs every match hidden, however many there are.
        let hidden = try await run(["fixture.target", "--until", "gone"]) { _ in
            Screen(elements: [Element(id: 2, visible: false), Element(id: 3, visible: false)])
        }
        #expect(hidden.json?["status"] as? String == "condition-met" && hidden.observation?["matchCount"] as? Int == 2)
    }

    /// `--index` picks one of several matches by position, in node order.
    @Test func indexChoosesOneOfSeveralMatchesByPosition() async throws {
        let screen = Screen(elements: [Element(id: 2, value: "first"), Element(id: 3, value: "second"), Element(id: 4, visible: false)])
        let second = try await run(["fixture.target", "--index", "2", "--value", "second"]) { _ in screen }
        #expect(second.json?["status"] as? String == "condition-met")
        #expect((second.json?["selector"] as? [String: Any])?["index"] as? Int == 2)
        #expect(second.observation?["matchCount"] as? Int == 3 && !(second.observation?["element"] is NSNull))
        let first = try await run(["fixture.target", "--index", "1", "--value", "second", "--timeout", "0"]) { _ in screen }
        #expect(first.observation?["reason"] as? String == "value-differs")
        // The position is taken as given: a hidden element is not skipped.
        let hidden = try await run(["fixture.target", "--index", "3", "--timeout", "0"]) { _ in screen }
        #expect(hidden.observation?["reason"] as? String == "not-visible")
        let beyond = try await run(["fixture.target", "--index", "4", "--timeout", "0"]) { _ in screen }
        #expect(beyond.json?["status"] as? String == "timed-out" && beyond.observation?["reason"] as? String == "no-match")
        // Gone is about that one element, not about every match.
        let gone = try await run(["fixture.target", "--index", "3", "--until", "gone"]) { _ in screen }
        #expect(gone.json?["status"] as? String == "condition-met" && gone.observation?["reason"] as? String == "not-visible")
        let absent = try await run(["fixture.target", "--index", "4", "--until", "gone"]) { _ in screen }
        #expect(absent.observation?["reason"] as? String == "absent")
        let shown = try await run(["fixture.target", "--index", "1", "--until", "gone", "--timeout", "0"]) { _ in screen }
        #expect(shown.observation?["reason"] as? String == "still-visible")
        for operands in [["fixture.target", "--index", "0"], ["fixture.target", "--index", "513"], ["fixture.target", "--index", "x"],
                         ["fixture.target", "--index", "1", "--index", "2"], ["fixture.target", "--index"]] {
            #expect(throws: CommandFailure.self) { try Self.wait(operands) }
        }
    }

    /// Observed in Settings: a row and the hidden text inside it share a label.
    @Test func oneVisibleMatchAmongExplicitlyHiddenOnesIsTheElement() async throws {
        let row = try await run(["fixture.target"]) { _ in
            Screen(elements: [Element(id: 2), Element(id: 3, visible: false)])
        }
        #expect(row.json?["status"] as? String == "condition-met")
        #expect(row.observation?["matchCount"] as? Int == 2)
        #expect(!(row.observation?["element"] is NSNull))
        // A match of unknown visibility could be the real one: still ambiguous.
        let unknown = try await run(["fixture.target", "--timeout", "1"]) { _ in
            Screen(elements: [Element(id: 2), Element(id: 3, visible: nil)])
        }
        #expect(unknown.json?["status"] as? String == "timed-out")
        #expect(unknown.observation?["reason"] as? String == "ambiguous")
        // Two visible matches stay ambiguous whatever else is hidden.
        let two = try await run(["fixture.target", "--timeout", "1"]) { _ in
            Screen(elements: [Element(id: 2), Element(id: 3), Element(id: 4, visible: false)])
        }
        #expect(two.observation?["reason"] as? String == "ambiguous")
    }

    @Test func labelSelectorAndForeignReferencesAreExact() async throws {
        let label = try await run(["Target"], operation: "wait-label") { _ in Screen(elements: [Element(identifier: nil)]) }
        #expect(label.json?["status"] as? String == "condition-met")
        #expect((label.json?["selector"] as? [String: Any])?["by"] as? String == "label")
        let caseDiffers = try await run(["target"], operation: "wait-label") { _ in Screen(elements: [Element()]) }
        #expect(caseDiffers.observation?["reason"] as? String == "no-match")
        let foreign = try await run(["fixture.target", "--timeout", "0"]) { _ in Screen(elements: [Element(foreignPID: 77)]) }
        #expect(foreign.observation?["reason"] as? String == "foreign-process")
    }

    @Test func processChangeBetweenPollsIsFollowedWithoutAPID() async throws {
        let run = try await run(["fixture.target"]) { poll in
            poll < 2 ? Screen(pid: 42) : Screen(pid: 43, elements: [Element()])
        }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "condition-met" && json["polls"] as? Int == 2)
        #expect((json["application"] as? [String: Any])?["pid"] as? Int == 43)
        #expect(json["processesObserved"] as? [Int] == [42, 43] && json["processChanges"] as? Int == 1)
    }

    @Test func unstableSelectionDuringAMetPollKeepsWaiting() async throws {
        let run = try await run(["42", "fixture.target"], configure: { $0.unstableRecheckPolls = [1] }) { _ in
            Screen(elements: [Element()])
        }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "condition-met" && json["polls"] as? Int == 2)
        #expect((json["application"] as? [String: Any])?["selection"] as? String == "explicit-pid")
        // An explicit PID needs no display: neither selection nor recheck.
        #expect(run.displays == 0 && json["display"] == nil && !run.wire.kinds.contains(6))
    }

    @Test(arguments: ["enabled", "disabled", "value"])
    func liveEnabledAndExactValueConditions(_ until: String) async throws {
        var operands = ["fixture.target", "--until", until]
        if until == "value" { operands += ["--value", "Done"] }
        let run = try await run(operands) { poll in
            let later = poll >= 2
            switch until {
            case "enabled": return Screen(elements: [Element(enabled: later)])
            case "disabled": return Screen(elements: [Element(enabled: !later)])
            default: return Screen(elements: [Element(value: later ? "Done" : "Loading")])
            }
        }
        let json = try #require(run.json)
        #expect(json["status"] as? String == "condition-met" && json["polls"] as? Int == 2)
        #expect(run.element?["enabled"] as? Bool == (until != "disabled"))
        if until == "value" {
            #expect(run.element?["value"] as? String == "Done")
            #expect((json["condition"] as? [String: Any])?["value"] as? String == "Done")
        }
    }

    @Test(arguments: [("enabled", "enabled-unknown"), ("value", "value-differs"), ("visible", "live-visibility-differs"), ("visible", "not-visible")])
    func unmetConditionsReportWhy(_ until: String, _ reason: String) async throws {
        var operands = ["fixture.target", "--until", until, "--timeout", "0.5"]
        if until == "value" { operands += ["--value", "Done"] }
        let run = try await run(operands) { _ in
            switch reason {
            case "enabled-unknown": return Screen(elements: [Element(enabled: nil)])
            case "live-visibility-differs": return Screen(elements: [Element(liveVisible: false)])
            case "not-visible": return Screen(elements: [Element(visible: false)])
            default: return Screen(elements: [Element(value: "Loading")])
            }
        }
        #expect(run.json?["status"] as? String == "timed-out")
        #expect(run.observation?["reason"] as? String == reason)
    }

    // MARK: - Failures, display and cancellation

    @Test func explicitPIDExitEndsAsASessionFailureWithCleanup() async throws {
        let run = try await run(["42", "fixture.target"], configure: { $0.failure = (1, 2, "exited") }) { _ in Screen() }
        #expect(run.json == nil)
        #expect(run.error.contains("Direct physical wait failed") && run.error.contains("stage=application"))
        #expect(run.error.contains("polls=2") && run.error.contains("No input was sent"))
        #expect(run.error.contains("Subscription cleanup: acknowledged; confirmed=true"))
        #expect(run.wire.disables == 1 && run.wire.closed)
    }

    @Test func transportLossMidWaitIsAFailureNotATimeout() async throws {
        let run = try await run(["fixture.target"], configure: { $0.failure = (2, 3, "eof") }) { _ in Screen() }
        #expect(run.error.contains("stage=snapshot") && run.error.contains("polls=3"))
        #expect(run.error.contains("Last observation: pid=42, reason=no-match"))
        #expect(run.wire.closed)
    }

    @Test func malformedOrOversizedSnapshotsFailInsteadOfMatching() async throws {
        let run = try await run(["fixture.target"]) { _ in
            Screen(elements: (0..<520).map { Element(id: $0 + 2) })
        }
        #expect(run.error.contains("stage=snapshot") && run.error.contains("512 nodes"))
    }

    @Test func displayChangeBeforeReportingIsAFailureAndDisplayOffExplainsATimeout() async throws {
        let changed = try await run(["fixture.target"], display: { count in
            try AccessibilityDisplayTests.data(scale: count == 2 ? 2 : 3)
        }) { _ in Screen(elements: [Element()]) }
        #expect(changed.error.contains("display geometry/orientation changed") && changed.error.contains("stage=display-recheck"))
        let off = try await run(["fixture.target", "--timeout", "0"], display: { count in
            try AccessibilityDisplayTests.data(backlight: count == 2 ? "off" : "activeOn")
        }) { _ in Screen() }
        #expect(off.json?["status"] as? String == "timed-out")
        #expect((off.json?["displayRecheck"] as? String ?? "").hasPrefix("unavailable: Primary display is off"))
        let asleep = try await run(["fixture.target"], display: { _ in try AccessibilityDisplayTests.data(backlight: "off") }) { _ in
            Issue.record("A sleeping display reached AX"); return Screen()
        }
        #expect(asleep.error.contains("stage=display") && asleep.wire.kinds.isEmpty)
        #expect(asleep.error.contains("Subscription cleanup: not-subscribed"))
    }

    @Test func cancellationInsideAPollRunsCleanup() async throws {
        let run = try await run(["fixture.target"], configure: { $0.failure = (2, 2, "cancel") }) { _ in Screen() }
        guard case .failure(let error) = run.result else { Issue.record("Cancelled wait returned a result"); return }
        #expect(error is CancellationError)
        #expect(run.wire.disables == 1 && run.wire.closed)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationWhileSleepingStopsPromptlyAndCleansUp() async throws {
        let polled = TestSignal()
        let task = Task { () -> (cancelled: Bool, disables: Int, closed: Bool, snapshots: Int) in
            let clock = ManualTestClock()
            let wire = Wire(poll: { 1 }, screen: { _ in Screen() })
            wire.onSnapshot = { polled.signal() }
            let wait = try Self.wait(["fixture.target", "--timeout", "60", "--interval", "5"])
            do {
                _ = try await wait.execute(device: "fixture", resolved: "resolved", session: AccessibilitySession(transport: wire),
                                           display: { try AccessibilityDisplay(AccessibilityDisplayTests.data()) }, clock: clock)
                return (false, wire.disables, wire.closed, wire.snapshots)
            } catch {
                return (error is CancellationError, wire.disables, wire.closed, wire.snapshots)
            }
        }
        await polled.wait()
        task.cancel()
        let outcome = try await task.value
        // The manual clock never advances: only cancellation can end the wait.
        #expect(outcome.cancelled && outcome.disables == 1 && outcome.closed && outcome.snapshots == 1)
    }

    // MARK: - Options, limits and front ends

    @Test func optionsParseWithDefaultsAndBounds() throws {
        let plain = try Self.wait(["fixture.target"])
        #expect(plain.pid == nil && plain.condition == .visible && plain.selector == AccessibilitySelector(by: "identifier", text: "fixture.target"))
        #expect(plain.timeoutMilliseconds == 10_000 && plain.intervalMilliseconds == 500 && plain.maximumPolls == 22)
        let full = try Self.wait(["42", "Done", "--until", "value", "--value", "Ready", "--timeout", "60", "--interval", "0.25"], operation: "wait-label")
        #expect(full.pid == 42 && full.selector.by == "label" && full.condition == .value("Ready"))
        #expect(full.timeoutMilliseconds == 60_000 && full.intervalMilliseconds == 250 && full.maximumPolls == 242)
        #expect(try Self.wait(["x", "--value", "v"]).condition == .value("v"))
        #expect(try Self.wait(["x", "--until", "gone"]).condition == .gone)
        #expect(try Self.wait(["x", "--until", "disabled"]).condition == .disabled)
        // The first operand is always positional; a numeric selector stays a selector.
        #expect(try Self.wait(["--until"]).selector.text == "--until")
        let numeric = try Self.wait(["42", "--timeout", "1"])
        #expect(numeric.pid == nil && numeric.selector.text == "42")
        let invalid: [[String]] = [
            [], ["0", "x"], ["-1", "x"], ["2147483648", "x"], ["42", "x", "extra"], [""], ["a\0b"], [String(repeating: "a", count: 4097)],
            ["x", "--until"], ["x", "--until", "soon"], ["x", "--until", "gone", "--until", "gone"], ["x", "--until", "value"],
            ["x", "--until", "gone", "--value", "v"], ["x", "--value", ""], ["x", "--timeout", "61"], ["x", "--timeout", "-1"],
            ["x", "--timeout", "nan"], ["x", "--timeout", "inf"], ["x", "--interval", "0.1"], ["x", "--interval", "6"],
            ["x", "--timeout", "1", "--timeout", "2"], ["x", "--timeout", "1", "stray"], ["42", "--until", "--until", "gone"]
        ]
        for operands in invalid {
            #expect(throws: CommandFailure.self, "\(operands)") { try Self.wait(operands) }
        }
        #expect(throws: CommandFailure.self) { try Self.wait(["x"], operation: "wait-hint") }
        #expect(try Self.wait(["x"], operation: "wait-value").selector == AccessibilitySelector(by: "value", text: "x"))
    }

    @Test func sessionBudgetsScaleWithThePollBoundAndDefaultsAreUnchanged() throws {
        #expect(AccessibilitySession.Limits.standard == .init(lifetime: .seconds(30), frames: 256, callbackBytes: 40 * 1024 * 1024))
        let limits = try Self.wait(["x", "--timeout", "60", "--interval", "0.25"]).sessionLimits
        #expect(limits.lifetime == .seconds(90) && limits.frames == 64 + 16 * 242 && limits.callbackBytes == 242 * 4 * 1024 * 1024)
        #expect(try Self.wait(["x", "--timeout", "0"]).sessionLimits.callbackBytes == 40 * 1024 * 1024)
    }

    @Test func cliParsingSignalsAndDryRunNeverQueryADevice() async throws {
        let args = ["wait", "--label", "Done", "--pid", "42", "--until", "gone", "--timeout", "3", "--device", "fixture"]
        let native = try #require(try physicalInput(args))
        #expect(native.operation == "wait-label" && native.operands == ["42", "Done", "--until", "gone", "--timeout", "3"])
        #expect(try request(args).signalContext == "physical input")
        await #expect(throws: CommandFailure.self) {
            try await CommandService().run(["wait", "--id", "x", "--interval", "9", "--device", "fixture"], dryRun: true)
        }
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried a device"); return Data() })
        let output = try await service.run(args, dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(output.exitCode == 0 && plan["operation"] as? String == "wait" && plan["readOnly"] as? Bool == true)
        #expect(plan["pid"] as? Int == 42 && (plan["condition"] as? [String: Any])?["until"] as? String == "gone")
        #expect(plan["timeoutSeconds"] as? Double == 3 && plan["intervalSeconds"] as? Double == 0.5 && plan["maximumPolls"] as? Int == 8)
        #expect(plan["timeoutExitCode"] as? Int == 124 && plan["liveVerified"] as? Bool == false)
        #expect((plan["identityArguments"] as? [String])?.contains("details") == true)
        let foreground = try await service.run(["wait", "--id", "x", "--device", "fixture"], dryRun: true)
        #expect((try JSONSerialization.jsonObject(with: foreground.data) as? [String: Any])?["pid"] is NSNull)
    }

    @Test func mcpToolIsReadOnlyAndRoutesToTheCLIForm() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "wait_for_element" })
        #expect(tool.tool.annotations.readOnlyHint == true)
        let schema = try #require(tool.tool.inputSchema.objectValue)
        #expect(Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)) == ["device", "by", "text"])
        #expect(try tool.command(["device": "fixture", "by": "identifier", "text": "fixture.target"])
            == ["wait", "--device=fixture", "--id=fixture.target"])
        let full = try tool.command(["device": "fixture", "by": "label", "text": "Done", "pid": 42, "until": "value", "value": "Ready",
                                     "timeout_seconds": 2.5, "interval_seconds": 1])
        #expect(full == ["wait", "--device=fixture", "--label=Done", "--pid=42", "--until=value", "--value=Ready", "--timeout=2.5", "--interval=1"])
        #expect(summary(try request(full)) == ["physical", "fixture", "wait-label", "42", "Done", "--until", "value", "--value", "Ready", "--timeout", "2.5", "--interval", "1"])
        let parsed = try #require(try physicalInput(full))
        let wait = try AccessibilityWait(parsed)
        #expect(wait.pid == 42 && wait.condition == .value("Ready") && wait.timeoutMilliseconds == 2500 && wait.intervalMilliseconds == 1000)
        for invalid: [String: Value] in [["device": "fixture", "by": "name", "text": "x"], ["device": "fixture", "by": "label"],
                                         ["device": "fixture", "by": "label", "text": "x", "until": "soon"],
                                         ["device": "fixture", "by": "label", "text": "x", "timeout_seconds": "5"]] {
            #expect(throws: MCPError.self) { try tool.command(invalid) }
        }
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried a device"); return Data() })
        let result = try await MCPTools.call(name: "wait_for_element", arguments: ["device": "fixture", "by": "label", "text": "Done", "until": "gone"]) {
            try await service.run($0, dryRun: true)
        }
        #expect(result.isError == false)
        #expect(result.structuredContent?.objectValue?["result"]?.objectValue?["operation"] == "wait")
    }

    @Test func mcpReportsATimeoutAsAnAnswerAndOtherExitsAsErrors() async throws {
        let timedOut = Data("{\"status\":\"timed-out\",\"conditionMet\":false}".utf8)
        #expect(try AccessibilityWait.output(timedOut).exitCode == 124)
        #expect(try AccessibilityWait.output(Data("{\"status\":\"condition-met\"}".utf8)).exitCode == 0)
        let arguments: [String: Value] = ["device": "fixture", "by": "identifier", "text": "x"]
        let answer = try await MCPTools.call(name: "wait_for_element", arguments: arguments) { _ in try AccessibilityWait.output(timedOut) }
        #expect(answer.isError == false && answer.structuredContent?.objectValue?["result"]?.objectValue?["status"] == "timed-out")
        let failed = try await MCPTools.call(name: "wait_for_element", arguments: arguments) { _ in
            throw CommandFailure(description: "Direct physical wait failed: fixture")
        }
        #expect(failed.isError == true)
        // Other tools keep treating any nonzero exit as an error.
        let doctor = try await MCPTools.call(name: "doctor", arguments: [:]) { _ in CommandOutput(data: Data("{}".utf8), exitCode: 124) }
        #expect(doctor.isError == true)
    }

    @Test func waitTakesNoDeviceLeaseWhileAnotherProcessOwnsTheDevice() async throws {
        let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F", udid = "00008110-000A1B2C3D4E5F60"
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = open(directory.appendingPathComponent("\(uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { _ = close(owner) }
        try #require(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
        // Details without a tunnel address stop the wait before any connection.
        let details = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": "enabled"], "hardware": ["udid": udid]]]])
        let service = CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in details })
        do {
            _ = try await service.run(["wait", "--id", "fixture.target", "--device", udid])
            Issue.record("Fixture details unexpectedly reached a device connection")
        } catch {
            let text = String(describing: error)
            #expect(!text.contains("another manzanero process"))
            #expect(text.contains("tunnel address"))
        }
    }
}
