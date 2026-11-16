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
final class SimulatorAccessibilitySession: AccessibilityValueSetting {
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
        let point = hitMapping?.native(x, y) ?? (x, y)
        return try AccessibilityResponse.token(exchange(AccessibilityRequest.hit(x: point.0, y: point.1), expected: .hit))
    }

    /// Hit points arrive in interface points (the tree's frames); the
    /// simulator answers hit tests in native portrait points (measured in
    /// landscape). Set from the latest display read; nil sends them unchanged.
    var hitMapping: SimulatorHitMapping?

    /// The frontmost application, or nil when the simulator reports none.
    func frontmost() throws -> AccessibilityRequest.Token? {
        let result = try exchange(AccessibilityRequest.frontmost(), expected: .frontmost, allowEmpty: true)
        return result == .null ? nil : try AccessibilityResponse.token(result)
    }

    /// How each foreground selection was made, in order.
    private(set) var selections: [String] = []

    /// The frontmost application; when the simulator reports none (observed
    /// for minutes after a fresh boot, on the Home Screen and in apps alike),
    /// the element under the display centre, hit-tested with client type 2.
    func foregroundProcess(_ display: AccessibilityDisplay) throws -> AccessibilityRequest.Token {
        if let token = try frontmost() {
            selections.append("frontmost")
            return token
        }
        selections.append("centre-hit")
        return try hit(x: display.center.x, y: display.center.y)
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

    func isSettable(_ token: AccessibilityRequest.Token) throws -> Bool {
        let result = try exchange(AccessibilityRequest.settable(token), expected: .settable)
        guard let settable = AccessibilityResponse.booleanResult(result) else { throw invalid("unknown settable result") }
        return settable
    }

    func setValue(_ token: AccessibilityRequest.Token, text: String, onSubmission: () -> Void) throws {
        _ = try exchange(AccessibilityRequest.setValue(token, text: text), expected: .setValue, onSubmission: onSubmission)
    }

    @discardableResult
    func close() -> AccessibilitySession.Cleanup {
        state = .closed
        return .notApplicable
    }

    private func exchange(_ archive: Data, expected: AccessibilityResponse.Expected, allowEmpty: Bool = false,
                          onSubmission: () -> Void = {}) throws -> AccessibilityArchiveValue {
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
            if allowEmpty, response.requestType == expected.requestType, response.error == 0, response.notification == 0,
               response.attribute == 0, response.result == .null {
                return .null
            }
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
    static func bridge(device uuid: String, developerDirectory: String, lifetime: Duration) throws -> SimulatorAccessibilitySession {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: developerDirectory, accessibility: true)
        let carrier: Carrier = { request, timeout in
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
        }
        return SimulatorAccessibilitySession(carrier: carrier, lifetime: lifetime)
    }
}

/// Converts interface points to the simulator's native portrait points for
/// hit tests, following the latest display read of one command.
final class SimulatorHitMapping: @unchecked Sendable {
    private let lock = NSLock()
    private var rotation = 0
    private var interface = (width: 1.0, height: 1.0)
    private var native = (width: 1.0, height: 1.0)

    func update(_ display: SimulatorDisplay, _ info: SimulatorDeviceInfo) {
        let bounds = display.accessibility(info).bounds
        lock.withLock {
            rotation = display.rotation
            interface = (bounds.width, bounds.height)
            native = (info.widthPoints, info.heightPoints)
        }
    }

    /// The physical `DirectTouchDisplay.portrait` mapping, in points.
    func native(_ x: Double, _ y: Double) -> (Double, Double) {
        lock.withLock {
            let display = DirectTouchDisplay(rotation: rotation)
            let point = display.portrait(x / interface.width, y / interface.height)
            return (point.0 * native.width, point.1 * native.height)
        }
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
        selectionSubject: "foreground application", selection: "frontmost-or-centre-hit", failurePrefix: "Simulator",
        treeSelectionLimitation: "The foreground application is the simulator's frontmost application, or the process under the screen centre when the simulator reports none (see foregroundSelection); system overlays such as alerts or the keyboard belong to other processes. This is not a combined display tree.",
        waitSelectionLimitation: "Every poll re-selects the foreground application (frontmost, else the process under the screen centre); an app launch is followed once the simulator reports it, which can lag the launch by seconds. The condition is evaluated in that poll's process.",
        cleanupLimitation: "The simulator route has no accessibility subscription; each request is independent.")
}
