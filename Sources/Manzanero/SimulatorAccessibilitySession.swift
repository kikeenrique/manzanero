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
/// - as on a phone, the centre hit that selects a process asks with client
///   type 2 (container) and element hits with type 0: type 2 at a row's
///   centre answered with an outer container on iPhone Duo and Apple TV.
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
    /// Blocks for at most the given chunk (10 ms in production); injectable
    /// so tests never wait.
    private let sleep: (Duration) -> Void

    init(carrier: @escaping Carrier, lifetime: Duration = .seconds(30), requestTimeout: Duration = .seconds(5),
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         cancelled: @escaping () -> Bool = { Task.isCancelled },
         sleep: @escaping (Duration) -> Void = { Thread.sleep(forTimeInterval: Double($0.components.attoseconds) / 1e18 + Double($0.components.seconds)) }) {
        self.carrier = carrier
        self.now = now
        self.cancelled = cancelled
        self.requestTimeout = requestTimeout
        self.sleep = sleep
        deadline = now().advanced(by: lifetime)
    }

    /// Waits in 10 ms chunks; cancellation or the session deadline ends it
    /// and closes the session.
    private func pause(_ duration: Duration) throws {
        let end = now().advanced(by: duration)
        while now() < end {
            if cancelled() { _ = close(); throw CancellationError() }
            guard now() < deadline else { _ = close(); throw invalid("deadline exceeded; session must close") }
            sleep(min(.milliseconds(10), now().duration(to: end)))
        }
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
        try hit(x: x, y: y, container: false)
    }

    func hit(x: Double, y: Double, container: Bool) throws -> AccessibilityRequest.Token {
        let point = hitMapping?.native(x, y) ?? (x, y)
        return try AccessibilityResponse.token(exchange(AccessibilityRequest.hit(x: point.0, y: point.1, container: container,
                                                                                 displayId: hitMapping?.displayId ?? 0), expected: .hit))
    }

    /// Hit points arrive in interface points (the tree's frames); the
    /// simulator answers hit tests in native portrait points (measured in
    /// landscape). Set from the latest display read; nil sends them unchanged.
    var hitMapping: SimulatorHitMapping?

    /// The frontmost application, or nil when the simulator reports none.
    func frontmost() throws -> AccessibilityRequest.Token? {
        let result = try exchange(AccessibilityRequest.frontmost(displayId: hitMapping?.displayId ?? 0), expected: .frontmost, allowEmpty: true)
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
        return try hit(x: display.center.x, y: display.center.y, container: true)
    }

    /// The shallower depth retried when a full-depth snapshot comes back empty.
    /// Measured on the iPhone 17e Home Screen: depth 10 answered in about 2 s
    /// and included the page's icons and the dock; depth 12 and deeper came
    /// back empty after the roughly three-second budget.
    static let shallowDepth = 10
    /// After an empty snapshot the app keeps answering every snapshot empty,
    /// at once, for several seconds (it is still building the abandoned one).
    /// The shallow request is therefore repeated once a second for at most
    /// this long; each empty answer costs about a millisecond.
    static let shallowRetryWindow: Duration = .seconds(12)

    /// Processes whose full-depth snapshot came back empty in this session;
    /// later snapshots of them use the shallow depth directly.
    private(set) var shallowPIDs: Set<Int32> = []
    /// Seconds spent waiting for the shallow retry, in total.
    private(set) var shallowWait: Duration = .zero

    /// Processes whose hosted snapshot this session has already read twice.
    private(set) var placedPIDs: Set<Int32> = []

    /// A process shown inside another's view, a web page in an app's
    /// `WKWebView`, answers its snapshot rooted at the host's remote element.
    /// The first snapshot any client reads of such a process has frames
    /// relative to the web view, not to the screen; from the next read on they
    /// are in screen points, however long after the page appeared the first
    /// read came (the probe's inset web view on an iOS 27.2 simulator,
    /// 2026-11-22: "Top button" at (12, 95), then (52, 249)). Safari's web
    /// view starts at the screen's corner, where both reads agree. So the
    /// first hosted snapshot of a process in a session is read again and the
    /// second one is used.
    func snapshot(_ token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        let first = try rawSnapshot(token)
        guard !placedPIDs.contains(token.pid) else { return first }
        placedPIDs.insert(token.pid)
        guard (try? AccessibilitySnapshot.normalize(first, root: token).first?.externalProcessReference) == true else { return first }
        return try rawSnapshot(token)
    }

    private func rawSnapshot(_ token: AccessibilityRequest.Token) throws -> AccessibilityArchiveValue {
        if !shallowPIDs.contains(token.pid) {
            do {
                return try exchange(AccessibilityRequest.snapshot(token), expected: .snapshot(token), keepOpenOnEmptySnapshot: true)
            } catch SnapshotEmpty.empty {
                shallowPIDs.insert(token.pid)
            }
        }
        let started = now()
        while true {
            do {
                let result = try exchange(AccessibilityRequest.snapshot(token, maxDepth: Self.shallowDepth), expected: .snapshot(token),
                                          keepOpenOnEmptySnapshot: true)
                shallowWait += started.duration(to: now())
                return Self.closingTruncatedRecords(result, count: &truncatedRecords)
            } catch SnapshotEmpty.empty {
                guard started.duration(to: now()) < Self.shallowRetryWindow else {
                    _ = close()
                    throw invalid("the simulator returned no snapshot data for this application, at full depth and at depth \(Self.shallowDepth) for \(Self.shallowRetryWindow); a large hierarchy such as the Home Screen's can exceed the simulator's snapshot time budget")
                }
                // Short chunks: cancellation and the session deadline end it.
                try pause(.seconds(1))
            }
        }
    }

    private enum SnapshotEmpty: Error { case empty }

    /// Records at the shallow depth limit that report children the snapshot
    /// does not include, summed over this session's shallow snapshots.
    private(set) var truncatedRecords = 0

    /// A depth-limited snapshot keeps each cut record's children count but
    /// omits the children, which the shared normalizer rightly rejects as
    /// malformed. Such records (children empty, count above zero) get count
    /// zero here, and are counted so the result can say how many were cut.
    static func closingTruncatedRecords(_ value: AccessibilityArchiveValue, count: inout Int) -> AccessibilityArchiveValue {
        guard case .dictionary(var record) = value else { return value }
        if case .array(let children) = record["UIAccessibilitySnapshotKeyChildren"] {
            if children.isEmpty, let reported = record["UIAccessibilitySnapshotKeyChildrenCount"]?.unsignedInteger, reported > 0 {
                record["UIAccessibilitySnapshotKeyChildrenCount"] = .unsigned(0)
                count += 1
            } else {
                record["UIAccessibilitySnapshotKeyChildren"] = .array(children.map { closingTruncatedRecords($0, count: &count) })
            }
        }
        return .dictionary(record)
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
                          keepOpenOnEmptySnapshot: Bool = false, onSubmission: () -> Void = {}) throws -> AccessibilityArchiveValue {
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
                if keepOpenOnEmptySnapshot { throw SnapshotEmpty.empty }
                throw invalid("the simulator returned no snapshot data for this application; a large hierarchy such as the Home Screen's can exceed the simulator's snapshot time budget")
            }
            guard let result = try response.matchingResult(for: expected) else {
                throw invalid("response does not match the request")
            }
            return result
        } catch SnapshotEmpty.empty {
            // The caller retries shallower; the session stays usable.
            throw SnapshotEmpty.empty
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
    private var display = 0

    /// The display ID point queries name: 0 for the primary display, else the
    /// interface display's screen ID (an unfolded iPhone Duo's LCD-1 is 3).
    var displayId: Int { lock.withLock { display } }

    func update(_ display: SimulatorDisplay, _ info: SimulatorDeviceInfo) {
        let bounds = display.accessibility(info).bounds, size = display.native(info)
        lock.withLock {
            rotation = display.rotation
            interface = (bounds.width, bounds.height)
            native = (size.width, size.height)
            self.display = display.secondary?.id ?? 0
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
        cleanupLimitation: "The simulator route has no accessibility subscription; each request is independent.",
        acceptsShownProcess: true)
}
