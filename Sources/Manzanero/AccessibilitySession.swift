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
    }

    /// Whole-session bounds against a slow, chatty or hostile peer. The
    /// standard values serve single observations and actions; a bounded wait
    /// scales them to its own maximum poll count. Cleanup keeps its separate
    /// three-second/32-frame allowance either way.
    struct Limits: Sendable, Equatable {
        var lifetime: Duration = .seconds(30)
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

    func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token {
        let result = try exchange(AccessibilityRequest.hit(x: x, y: y), expected: .hit)
        return try AccessibilityResponse.token(result)
    }

    func snapshot(_ token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        try exchange(AccessibilityRequest.snapshot(token), expected: .snapshot(token))
    }

    func attributes(_ attributes: [Int], of token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        try exchange(AccessibilityRequest.attributes(attributes, of: token), expected: .attributes(token))
    }

    func performAction(_ token: AccessibilityRequest.Token, action: AccessibilityRequest.Action, onSubmission: () -> Void) throws -> Bool {
        let result = try exchange(AccessibilityRequest.action(token, action: action), expected: .action, onSubmission: onSubmission)
        guard let accepted = AccessibilityResponse.booleanResult(result) else { throw invalid("unknown action result") }
        return accepted
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
        do {
            // Cleanup has its own budget and ignores task cancellation so a
            // cancellation still attempts disable. Transport loss stays unknown.
            _ = try invoke("clientNeedsAccessibility:", argument: NSNumber(value: false),
                           until: now().advanced(by: .seconds(3)))
            cleanup = .stopAcknowledged
        } catch {
            cleanup = .unconfirmed(String(describing: error))
        }
        return cleanup ?? .unconfirmed("missing cleanup outcome")
    }

    private func exchange(_ archive: Data, expected: AccessibilityResponse.Expected, onSubmission: () -> Void = {}) throws -> AccessibilityArchiveValue {
        guard state == .active, !busy else { throw invalid("session unavailable or request already active") }
        busy = true
        self.expected = expected
        results.removeAll()
        defer { busy = false; self.expected = nil; results.removeAll() }
        do {
            _ = try invoke("processDataFromHost:", argument: archive as NSData, until: phase(), beforeWrite: onSubmission)
            let responseDeadline = phase()
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
            default: throw invalid("remote DTX error reply")
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
        case "hostAPIVersion":
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
        default: throw invalid("unsupported callback selector")
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
