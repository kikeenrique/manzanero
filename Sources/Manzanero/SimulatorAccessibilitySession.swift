import AppleDeviceBridge
import Foundation

/// The simulator carrier for accessibility requests: the same
/// `AccessibilityRequest` archives the physical DTX session sends, handed to
/// CoreSimulator one at a time, and the same `AccessibilityResponse` decoding
/// and matching. Differences from the physical session, all deliberate:
///
/// - no subscription, so `start` only opens the session and `close` reports
///   `notApplicable`;
/// - the foreground process is the frontmost application (request type 4),
///   because a display-centre hit over an empty area fails on the simulator;
/// - hit tests carry client type 2 (set by the bridge).
///
/// Synchronous and single-owner like `AccessibilitySession`; any failure
/// closes it.
final class SimulatorAccessibilitySession: AccessibilityExchange {
    /// Sends one request archive and returns the response archive. As with
    /// the DTX session, an action counts as submitted from just before the
    /// carrier runs, so any carrier failure after that is an unknown outcome.
    typealias Carrier = (_ request: Data, _ timeout: Duration) throws -> Data

    let platform = AccessibilityPlatform.simulator
    private enum State { case new, active, closed }
    private let carrier: Carrier
    private let now: () -> ContinuousClock.Instant
    private let cancelled: () -> Bool
    private let deadline: ContinuousClock.Instant
    private let requestTimeout: Duration
    private var state = State.new
    private var busy = false
    private(set) var requests = 0

    init(carrier: @escaping Carrier, lifetime: Duration = .seconds(30), requestTimeout: Duration = .seconds(5),
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.carrier = carrier
        self.now = now
        self.cancelled = cancelled
        self.requestTimeout = requestTimeout
        deadline = now().advanced(by: lifetime)
    }

    func start() throws {
        guard state == .new, !busy else { throw invalid("session already started or closed") }
        if cancelled() { _ = close(); throw CancellationError() }
        state = .active
    }

    func application(pid: Int32) throws -> AccessibilityRequest.Token {
        try AccessibilityResponse.token(exchange(AccessibilityRequest.application(pid: pid), expected: .application(pid: pid)))
    }

    func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token {
        try AccessibilityResponse.token(exchange(AccessibilityRequest.hit(x: x, y: y), expected: .hit))
    }

    func frontmost() throws -> AccessibilityRequest.Token {
        try AccessibilityResponse.token(exchange(AccessibilityRequest.frontmost(), expected: .frontmost))
    }

    func foregroundProcess(_ display: AccessibilityDisplay) throws -> AccessibilityRequest.Token {
        try frontmost()
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
    func close() -> AccessibilitySession.Cleanup {
        state = .closed
        return .notApplicable
    }

    private func exchange(_ archive: Data, expected: AccessibilityResponse.Expected, onSubmission: () -> Void = {}) throws -> AccessibilityArchiveValue {
        guard state == .active, !busy else { throw invalid("session unavailable or request already active") }
        busy = true
        defer { busy = false }
        do {
            if cancelled() { throw CancellationError() }
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { throw invalid("deadline exceeded; session must close") }
            requests += 1
            onSubmission()
            let bytes = try carrier(archive, min(requestTimeout, remaining))
            if cancelled() { throw CancellationError() }
            guard try KeyedArchiveInspector.protocolResponseType(bytes) == expected.requestType else {
                throw invalid("response is for another request type")
            }
            let response = try AccessibilityResponse(archive: bytes)
            if case .snapshot = expected, response.error == 0, response.result == .null {
                // Observed for SpringBoard: its full-depth snapshot exceeds a
                // roughly three-second budget and comes back empty.
                throw invalid("the simulator returned no snapshot data for this application; a large hierarchy such as the Home Screen's can exceed the simulator's snapshot time budget")
            }
            guard let result = try response.matchingResult(for: expected) else {
                throw invalid("response does not match the request")
            }
            return result
        } catch {
            _ = close()
            throw error
        }
    }

    private func invalid(_ reason: String) -> CommandFailure {
        // As for the DTX session, callers refine inputSent by stage.
        CommandFailure(.transportFailed, "Simulator accessibility session: \(reason).", inputSent: .unknown)
    }

    /// The production carrier: one CoreSimulator request per call.
    static func bridge(device uuid: String, developerDirectory: String) throws -> SimulatorAccessibilitySession {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: developerDirectory, accessibility: true)
        return SimulatorAccessibilitySession(carrier: { request, timeout in
            var error = [CChar](repeating: 0, count: 1024)
            var response = Data()
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            let status = request.withUnsafeBytes { bytes in
                ADCSimulatorAXExchange(owner.pointer, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, seconds,
                                       { Task.isCancelled ? 1 : 0 }, { pointer, count in
                    if let pointer { response = Data(bytes: pointer, count: count) }
                }, &error, error.count)
            }
            guard status == 0 else {
                if Task.isCancelled { throw CancellationError() }
                // Callers refine inputSent by stage, as for the DTX session.
                let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                throw CommandFailure(.transportFailed, "Simulator accessibility request failed: \(message)", inputSent: .unknown)
            }
            return response
        })
    }
}

/// Owns one bridge SimDevice reference for the lifetime of a simulator session.
final class SimulatorBridgeOwner {
    let pointer: UnsafeMutableRawPointer
    let info: SimulatorDeviceInfo

    init(uuid: String, developerDirectory: String, accessibility: Bool) throws {
        var error = [CChar](repeating: 0, count: 1024)
        if accessibility, ADCPrepareCoreSimulator(1, &error, error.count) != 0 {
            throw CommandFailure(.hostRequirement, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), inputSent: .none)
        }
        var raw = ADCSimulatorInfo()
        var owner: UnsafeMutableRawPointer?
        let status = ADCOpenSimulatorDevice(developerDirectory, uuid, &raw, &owner, &error, error.count)
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard status == 0, let owner else {
            ADCCloseSimulatorDevice(owner)
            throw CommandFailure(status == ADCSimulatorNotFound ? .targetUnresolved : .hostRequirement, message, inputSent: .none)
        }
        pointer = owner
        info = raw.swift(uuid: uuid)
    }

    deinit { ADCCloseSimulatorDevice(pointer) }
}

extension AccessibilityPlatform {
    static let simulator = AccessibilityPlatform(
        backend: "coresimulator-ax", resolvedKey: "resolvedSimulatorUUID", deviceAPIVersion: nil,
        selectionSubject: "frontmost application", selection: "frontmost-application", failurePrefix: "Simulator",
        treeSelectionLimitation: "Frontmost-application selection may miss system overlays such as alerts or the keyboard, which belong to other processes; this is not a combined display tree.",
        waitSelectionLimitation: "Every poll re-selects the frontmost application; an app launch is followed once CoreSimulator reports it frontmost, which can lag the launch by seconds. The condition is evaluated in that poll's process.",
        cleanupLimitation: "The simulator route has no accessibility subscription; each request is independent.")
}
