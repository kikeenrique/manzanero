import Foundation

/// An owned transport must enforce the supplied monotonic deadline and poll
/// cancellation during I/O. close() must be idempotent. Session checks alone
/// cannot interrupt blocking I/O.
protocol AccessibilitySessionTransport: AnyObject {
    func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX
    func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws
    func close()
}

/// Synchronous, single-owner AX exchange. Keep this object within one operation;
/// it is deliberately not Sendable or reusable after an error/timeout.
final class AccessibilitySession {
    enum Cleanup: Sendable, Equatable {
        case notSubscribed
        case stopAcknowledged
        case unconfirmed(String)
        /// The carrier has no subscription to stop (the simulator route).
        case notApplicable
    }

    /// Whole-session bounds against a slow, chatty or hostile peer. The
    /// standard values serve single observations and actions; a bounded wait
    /// scales them to its own maximum poll count. Cleanup keeps its separate
    /// three-second/32-frame allowance either way.
    /// The lifetime was 30 s until 2026-11-22, when a press in Control Centre
    /// on the iPhone 13 mini ran out of it: each snapshot of SpringBoard took
    /// 8 to 15 s there, and a press reads several.
    struct Limits: Sendable, Equatable {
        var lifetime: Duration = .seconds(120)
        var frames = 256
        var callbackBytes = 40 * 1024 * 1024
        static let standard = Limits()
    }

    private enum State { case new, active, closed }
    private let transport: any AccessibilitySessionTransport
    private let now: () -> ContinuousClock.Instant
    private let cancelled: () -> Bool
    private let limits: Limits
    private let deadline: ContinuousClock.Instant
    private var state = State.new
    private var busy = false
    private var stopping = false
    private var attemptedSubscription = false
    private var next: UInt32 = 1
    private var frames = 0
    private var callbackBytes = 0
    private var expected: AccessibilityResponse.Expected?
    private var results: [AccessibilityArchiveValue] = []
    private(set) var cleanup: Cleanup?

    init(transport: any AccessibilitySessionTransport, limits: Limits = .standard,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.transport = transport
        self.now = now
        self.cancelled = cancelled
        self.limits = limits
        deadline = now().advanced(by: limits.lifetime)
    }

    deinit { transport.close() }

    func start() throws {
        guard state == .new, !busy else { throw invalid("session already started or closed") }
        busy = true
        defer { busy = false }
        do {
            let version = try invoke("deviceAPIVersion", argument: nil, until: phase())
            guard version?.unsignedInteger == 26 else { throw invalid("unsupported device API version") }
            // An ambiguous enable must still be followed by a disable attempt.
            attemptedSubscription = true
            _ = try invoke("clientNeedsAccessibility:", argument: NSNumber(value: true), until: phase())
            state = .active
        } catch {
            _ = close()
            throw error
        }
    }

    func application(pid: Int32) throws -> AccessibilityRequest.Token {
        let result = try exchange(AccessibilityRequest.application(pid: pid), expected: .application(pid: pid))
        return try AccessibilityResponse.token(result)
    }

    /// Hit points arrive in interface points (the tree's frames) and are sent
    /// in the display's native portrait points, as a simulator takes them.
    /// Set by each foreground selection from the display read for it.
    private var hitDisplay: AccessibilityDisplay?

    func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token {
        let point = hitDisplay?.native(x, y) ?? (x: x, y: y)
        let result = try exchange(AccessibilityRequest.hit(x: point.x, y: point.y), expected: .hit)
        return try AccessibilityResponse.token(result)
    }

    /// The process that owns the display centre. Asked as a container hit, so
    /// an app whose centre has no accessibility element (a canvas, a game, an
    /// empty area) is still selected instead of refused.
    ///
    /// On an external display (an Apple TV) the frontmost application is
    /// asked for instead, as on a simulator: tvOS has no touch point to test.
    func foregroundProcess(_ display: AccessibilityDisplay) throws -> AccessibilityRequest.Token {
        hitDisplay = display
        if display.external {
            return try AccessibilityResponse.token(try exchange(AccessibilityRequest.frontmost(), expected: .frontmost))
        }
        let centre = display.native(display.center.x, display.center.y)
        let result = try exchange(AccessibilityRequest.hit(x: centre.x, y: centre.y, container: true), expected: .hit)
        return try AccessibilityResponse.token(result)
    }

    func snapshot(_ token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        try exchange(AccessibilityRequest.snapshot(token), expected: .snapshot(token), answerWithin: Self.snapshotAnswer)
    }

    func attributes(_ attributes: [Int], of token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        try exchange(AccessibilityRequest.attributes(attributes, of: token), expected: .attributes(token))
    }

    func performAction(_ token: AccessibilityRequest.Token, action: AccessibilityRequest.Action, onSubmission: () -> Void) throws -> Bool {
        let result = try exchange(AccessibilityRequest.action(token, action: action), expected: .action, onSubmission: onSubmission)
        guard let accepted = AccessibilityResponse.booleanResult(result) else { throw invalid("unknown action result") }
        return accepted
    }

    func isSettable(_ token: AccessibilityRequest.Token) throws -> Bool {
        let result = try exchange(AccessibilityRequest.settable(token), expected: .settable)
        guard let settable = AccessibilityResponse.booleanResult(result) else { throw invalid("unknown settable result") }
        return settable
    }

    func setValue(_ token: AccessibilityRequest.Token, text: String, onSubmission: () -> Void) throws {
        _ = try exchange(AccessibilityRequest.setValue(token, text: text), expected: .setValue, onSubmission: onSubmission)
    }

    @discardableResult
    func close() -> Cleanup {
        if let cleanup { return cleanup }
        state = .closed
        expected = nil
        results.removeAll()
        stopping = true
        defer { stopping = false; transport.close() }
        guard attemptedSubscription else {
            cleanup = .notSubscribed
            return .notSubscribed
        }
        let started = now()
        do {
            // Cleanup has its own budget and ignores task cancellation so a
            // cancellation still attempts disable. Transport loss stays unknown.
            _ = try invoke("clientNeedsAccessibility:", argument: NSNumber(value: false),
                           until: started.advanced(by: .seconds(3)))
            cleanup = .stopAcknowledged
        } catch {
            // How long the stop ran and how much arrived meanwhile tells a
            // lost acknowledgement (the full 3 s, few frames) from a device
            // still sending callbacks (the 32-frame budget) or a closed link.
            let elapsed = started.duration(to: now())
            let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            cleanup = .unconfirmed("\(error) (stop exchange: \(milliseconds) ms of 3000, \(cleanupFrames) of 32 cleanup frames read)")
        }
        return cleanup ?? .unconfirmed("missing cleanup outcome")
    }

    /// How long a snapshot's answer may take. Other answers have four
    /// seconds; a snapshot of a system process can take longer: with Control
    /// Centre open over an app, every tree on the iPhone 13 mini failed at
    /// four seconds (2026-11-22).
    static let snapshotAnswer: Duration = .seconds(40)

    private func exchange(_ archive: Data, expected: AccessibilityResponse.Expected, answerWithin: Duration = .seconds(4),
                          onSubmission: () -> Void = {}) throws -> AccessibilityArchiveValue {
        guard state == .active, !busy else { throw invalid("session unavailable or request already active") }
        busy = true
        self.expected = expected
        results.removeAll()
        defer { busy = false; self.expected = nil; results.removeAll() }
        do {
            _ = try invoke("processDataFromHost:", argument: archive as NSData, until: phase(), beforeWrite: onSubmission)
            let responseDeadline = min(deadline, now().advanced(by: answerWithin))
            while results.isEmpty { _ = try receive(until: responseDeadline) }
            try check(responseDeadline)
            guard results.count == 1 else { throw invalid("multiple matching semantic callbacks") }
            return results[0]
        } catch {
            _ = close()
            throw error
        }
    }

    private func phase() -> ContinuousClock.Instant { min(deadline, now().advanced(by: .seconds(4))) }

    private func check(_ limit: ContinuousClock.Instant) throws {
        if !stopping, cancelled() { throw CancellationError() }
        guard now() < limit else { throw invalid("deadline exceeded; session must close") }
    }

    private func invoke(_ selector: String, argument: NSObject?, until limit: ContinuousClock.Instant, beforeWrite: () -> Void = {}) throws -> AccessibilityArchiveValue? {
        try check(limit)
        let (following, overflow) = next.addingReportingOverflow(1)
        guard !overflow else { throw invalid("identifier overflow") }
        let message = try AccessibilityDTX.invocation(selector, argument: argument, identifier: next)
        next = following
        beforeWrite()
        try transport.write(message, until: limit, cancelled: { !self.stopping && self.cancelled() })
        while true {
            let frame = try receive(until: limit)
            guard frame.isReply(to: message) else { continue }
            switch frame.kind {
            case .acknowledgement: return nil
            case .object:
                guard frame.auxiliary.isEmpty else { throw invalid("object reply has unexpected arguments") }
                let value = try KeyedArchiveInspector.decodeProtocol(frame.object)
                try check(limit)
                return value
            default: throw invalid("remote DTX error reply to '\(selector)'")
            }
        }
    }

    @discardableResult
    private func receive(until limit: ContinuousClock.Instant) throws -> AccessibilityDTX {
        try check(limit)
        // Reserve a separate frame budget for cleanup after a read budget fails.
        if !stopping {
            guard frames < limits.frames else { throw invalid("frame budget exceeded") }
            frames += 1
        } else {
            guard cleanupFrames < 32 else { throw invalid("cleanup frame budget exceeded") }
            cleanupFrames += 1
        }
        let frame = try transport.read(until: limit, cancelled: { !self.stopping && self.cancelled() })
        try check(limit)
        guard frame.kind == .invocation else { return frame }
        guard frame.channel == 0, frame.conversation == 0, frame.object.count <= 4096,
              case .string(let selector) = try KeyedArchiveInspector.decodeProtocol(frame.object) else {
            throw invalid("invalid callback channel, conversation or selector")
        }
        switch selector {
        // The daemon's service behind the shim (the older "remoteserver"
        // name, which Apple's Accessibility Inspector uses) spells it
        // hostApiVersion.
        case "hostAPIVersion", "hostApiVersion":
            guard frame.expectsReply, frame.auxiliary.isEmpty else { throw invalid("invalid host version invocation") }
            let version = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
            try transport.write(frame.reply(object: version), until: limit, cancelled: { !self.stopping && self.cancelled() })
        case "_notifyOfPublishedCapabilities:", "processDataFromRemoteDevice:":
            if frame.expectsReply {
                try transport.write(frame.reply(), until: limit, cancelled: { !self.stopping && self.cancelled() })
            }
            if selector == "processDataFromRemoteDevice:" {
                let bytes = try frame.archiveArgument()
                guard bytes.count <= limits.callbackBytes - callbackBytes else { throw invalid("callback byte budget exceeded") }
                callbackBytes += bytes.count
                // Startup/cleanup callbacks cannot satisfy a later request.
                if let expected {
                    if try KeyedArchiveInspector.protocolResponseType(bytes) == expected.requestType {
                        let response = try AccessibilityResponse(archive: bytes)
                        if let result = try response.matchingResult(for: expected) {
                            guard results.count < 8 else { throw invalid("callback queue budget exceeded") }
                            results.append(result)
                        }
                    }
                }
            }
        default: throw invalid("unsupported callback selector '\(selector.prefix(80))'")
        }
        try check(limit)
        return frame
    }

    private var cleanupFrames = 0

    private func invalid(_ reason: String) -> CommandFailure {
        // The session cannot know which stage its caller is in; callers refine inputSent.
        CommandFailure(.transportFailed, "Accessibility session: \(reason).", inputSent: .unknown)
    }
}
