import AppleDeviceBridge
import Foundation
import Synchronization

/// `hold <x> <y>` and `release`: batch steps that keep one contact down on a
/// physical device's touchscreen while the steps between them run, so each
/// later step can act on a fresh look instead of a precomputed coordinate
/// (docs/gesture-sequences.md#holding-a-contact-across-steps).
///
/// The held contact is contact 0 of one live Universal HID stream
/// (`ADCPerformLiveDigitizerReports`): one connection for the whole hold,
/// its complete-state report sent again every 250 ms while nothing else
/// moves. Touch steps inside the hold are not sent on their own: their
/// frames join the same stream as contacts 1...4 (`HoldSegment`). The stream
/// ends at `release`, at the end of the batch, at a failed step or on
/// cancellation, and every active contact is then released.
struct HoldStep: Sendable, Equatable {
    static let operation = "hold"
    static let releaseOperation = "release"
    /// The digitizer takes five contacts and the hold takes one.
    static let maximumExtraContacts = 4
    static let refreshMilliseconds = 250
    static let batchOnly = "hold and release are batch steps: they keep a contact down while the steps between them run, and run only inside batch (see manzanero batch --help). Nothing was run."

    let device: String
    /// A simulator's hold: the same stream on the touchscreen of the
    /// display the interface is on (`ADCSimulatorPerformLiveDigitizerReports`).
    let simulator: Bool
    let x: Double
    let y: Double

    init(_ target: Target, x: String, y: String) throws {
        guard let x = Double(x), let y = Double(y), x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw CommandFailure.usage("hold takes normalized x and y in 0...1 of the current interface.")
        }
        device = target.identifier
        simulator = target.platform == .simulator
        self.x = x
        self.y = y
    }
}

/// One hold of a batch as the batch was built: where it starts and ends,
/// the steps that run while it is down and the touch steps merged into it.
struct HoldSpan: Sendable, Equatable {
    /// 1-based step numbers.
    let step: Int
    var releaseStep: Int?
    var stepsWhileHeld: [Int] = []
    var mergedSteps: [Int] = []
    /// Contacts of every report of the stream: the held one and the most
    /// any merged step uses.
    var contactSlots = 1
    let x: Double
    let y: Double

    var plan: [String: Any] {
        ["step": step, "releaseStep": releaseStep.map { $0 as Any } ?? NSNull(), "releasedAtEndOfBatch": releaseStep == nil,
         "x": x, "y": y, "contact": 0, "contactSlots": contactSlots, "stepsWhileHeld": stepsWhileHeld, "mergedSteps": mergedSteps,
         "refreshMilliseconds": HoldStep.refreshMilliseconds,
         "stream": "One live Universal HID stream on one connection: contact 0 down at x, y and its report sent again every \(HoldStep.refreshMilliseconds) ms; each merged touch step's frames sent in it as further contacts (ids from 1, \(contactSlots) contacts per report) beside the held contact; every active contact released when the stream ends (release, end of batch, a failed step or cancellation)."]
    }
}

/// A touch step's frames as extra contacts of a held stream: positions in
/// the digitizer's 16-bit portrait space, per local contact (0...k-1, which
/// become contacts 1...k of the stream), and which are down in each frame.
struct HoldSegment: Equatable {
    struct Frame: Equatable {
        let nanoseconds: UInt64
        let positions: [[Int]]
        let active: Set<Int>
    }
    let frames: [Frame]
    let contactCount: Int
    var durationNanoseconds: UInt64 { frames.last?.nanoseconds ?? 0 }

    /// Steps whose frames join a held stream: every touch operation.
    static func handles(_ input: CoreDeviceInput) -> Bool {
        DirectPhysicalGesture.handles(input) || DirectPhysicalTouch.operations.contains(input.operation)
    }

    /// The step's frames, built by the same planners as when it runs alone.
    /// Without a display the coordinates are left as given (for the check
    /// made when the batch is built, and for plans).
    init(_ input: CoreDeviceInput, display: DirectTouchDisplay? = nil) throws {
        let display = display ?? DirectTouchDisplay(portraitPoints: 1, height: 1, scale: 1)
        if DirectPhysicalGesture.handles(input) {
            let sequence = try DirectPhysicalGesture.sequence(for: input, transform: display.portrait)
            contactCount = sequence.contactCount
            frames = zip(sequence.times, sequence.reports).map { time, report in
                let positions = (0..<sequence.contactCount).map { id in
                    let offset = 3 + id * 5
                    return [Int(report[offset + 1]) | Int(report[offset + 2]) << 8, Int(report[offset + 3]) | Int(report[offset + 4]) << 8]
                }
                let active = Set((0..<sequence.contactCount).filter { report[3 + $0 * 5] & 0xc0 != 0 })
                return Frame(nanoseconds: UInt64(time) * 1_000_000, positions: positions, active: active)
            }
            return
        }
        let samples = try DirectPhysicalTouch.plan(input, display: display)
        func position(_ x: Double, _ y: Double) -> [Int] { [x, y].map { Int((min(max($0, 0), 1) * 65535).rounded()) } }
        contactCount = samples.first?.second == nil ? 1 : 2
        frames = samples.map { sample in
            var positions = [position(sample.x, sample.y)]
            if let second = sample.second { positions.append(position(second.x, second.y)) }
            return Frame(nanoseconds: sample.nanoseconds, positions: positions,
                         active: sample.phase == 2 ? [] : Set(0..<positions.count))
        }
    }
}

/// The state of one live stream: what the bridge sends next, and what the
/// batch waits for. The bridge calls `next(now:)` on its own thread; the
/// batch enqueues segments and waits on the same condition.
final class HoldStream: @unchecked Sendable {
    enum Next: Equatable {
        /// Send this report after the delay (nanoseconds from now).
        case send([UInt8], delay: UInt64)
        /// Nothing to send yet; ask again after the delay.
        case idle(UInt64)
        case end
    }

    struct Outcome: Sendable, Equatable {
        /// `ADCPerformLiveDigitizerReports`'s status.
        let status: Int32
        let surface: UInt64
        let message: String
        var failure: CommandFailure? {
            status == 0 ? nil : CommandFailure.inputDispatch(status: status, message: message)
        }
    }

    static let refreshNanoseconds = UInt64(HoldStep.refreshMilliseconds) * 1_000_000
    /// How often the bridge asks while nothing is due, so that a step
    /// enqueued meanwhile starts within this time.
    static let pollNanoseconds: UInt64 = 10_000_000

    /// What the last handed-out report means once it has been sent, which
    /// the next call to `next` confirms.
    private struct Handout {
        var first = false
        var refresh = false
        var completes: Int?
    }

    private struct Running {
        let id: Int
        let segment: HoldSegment
        let start: UInt64
        var frame = 0
    }

    // `condition` guards every stored property below.
    private let condition = NSCondition()
    let slots: Int
    private var positions: [[Int]]
    private var active: Set<Int> = [0]
    private var lastDue: UInt64?
    private var handout: Handout?
    private var waiting: [(id: Int, segment: HoldSegment)] = []
    private var running: Running?
    private var completed: Set<Int> = []
    private var nextID = 0
    private var ending = false
    private var stopping = false
    private var holding = false
    private var outcome: Outcome?
    private var reportsSent = 0
    private var refreshReports = 0
    private var firstDue: UInt64?

    /// `held` is contact 0's position in the digitizer's 16-bit portrait space.
    init(slots: Int, held: [Int]) {
        precondition((1...5).contains(slots))
        self.slots = slots
        positions = [held] + Array(repeating: [0, 0], count: slots - 1)
    }

    var isStopping: Bool { condition.withLock { stopping } }

    /// Reports sent, of them refreshes of an unchanged state, and the time
    /// from the first report to the last.
    var statistics: (reports: Int, refreshes: Int, heldNanoseconds: UInt64) {
        condition.withLock {
            (reportsSent, refreshReports, (lastDue ?? 0) - (firstDue ?? lastDue ?? 0))
        }
    }

    private func report() -> [UInt8] { NativeTouchFrames.report(positions: positions, active: active) }

    /// The bridge's question. Never blocks.
    func next(now: UInt64) -> Next {
        condition.lock()
        defer { condition.unlock() }
        if let sent = handout {
            // The bridge asks again only after sending what it was given.
            handout = nil
            reportsSent += 1
            if sent.refresh { refreshReports += 1 }
            if sent.first { holding = true }
            if let id = sent.completes { completed.insert(id); running = nil }
            condition.broadcast()
        }
        guard let lastDue else {
            // The first report puts the held contact down at once.
            handout = Handout(first: true)
            self.lastDue = now
            firstDue = now
            return .send(report(), delay: 0)
        }
        if running == nil, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running = Running(id: next.id, segment: next.segment, start: now)
        }
        if running == nil, ending { return .end }
        let refreshDue = lastDue + Self.refreshNanoseconds
        let frameDue = running.map { $0.start + $0.segment.frames[$0.frame].nanoseconds }
        let due = min(refreshDue, frameDue ?? .max)
        guard due <= now + Self.pollNanoseconds else { return .idle(Self.pollNanoseconds) }
        let delay = due > now ? due - now : 0
        if let frameDue, frameDue <= refreshDue, var current = running {
            let frame = current.segment.frames[current.frame]
            for local in 0..<current.segment.contactCount {
                let slot = local + 1
                // An inactive contact keeps its last position: the bridge
                // refuses one that moves.
                if frame.active.contains(local) {
                    positions[slot] = frame.positions[local]
                    active.insert(slot)
                } else {
                    active.remove(slot)
                }
            }
            current.frame += 1
            let last = current.frame == current.segment.frames.count
            if last { for local in 0..<current.segment.contactCount { active.remove(local + 1) } }
            running = current
            handout = Handout(completes: last ? current.id : nil)
        } else {
            handout = Handout(refresh: true)
        }
        self.lastDue = now + delay
        return .send(report(), delay: delay)
    }

    /// `next` in the bridge's form.
    func provider(clock: @escaping @Sendable () -> UInt64) -> (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt64>?) -> Int32 {
        { [self] report, delay in
            switch next(now: clock()) {
            case .end: return ADCLiveDigitizerEnd
            case .idle(let wait):
                delay?.pointee = wait
                return ADCLiveDigitizerIdle
            case .send(let bytes, let wait):
                guard let report, bytes.count == 58 else { return ADCLiveDigitizerEnd }
                bytes.withUnsafeBufferPointer { report.update(from: $0.baseAddress!, count: 58) }
                delay?.pointee = wait
                return ADCLiveDigitizerSend
            }
        }
    }

    /// Called once, when the bridge has returned.
    func finish(_ result: Outcome) {
        condition.withLock {
            outcome = result
            condition.broadcast()
        }
    }

    /// Blocks until the held contact's first report was sent (nil) or the
    /// stream ended before that (its outcome).
    func waitUntilHolding() -> Outcome? {
        condition.withLock {
            while !holding && outcome == nil { condition.wait() }
            return holding ? nil : outcome
        }
    }

    /// Sends a segment in the stream and blocks until its last frame was
    /// sent (nil), or the stream ended first (its outcome).
    func perform(_ segment: HoldSegment) -> Outcome? {
        guard let id = enqueue(segment) else { return condition.withLock { outcome } }
        return condition.withLock {
            while !completed.contains(id) && outcome == nil { condition.wait() }
            return completed.contains(id) ? nil : outcome
        }
    }

    /// Queues a segment without waiting; nil when the stream has ended.
    func enqueue(_ segment: HoldSegment) -> Int? {
        condition.withLock {
            precondition(segment.contactCount < slots, "A merged step needs more contacts than the stream has.")
            guard outcome == nil, !ending else { return nil }
            let id = nextID
            nextID += 1
            waiting.append((id, segment))
            return id
        }
    }

    /// Whether every frame of a queued segment was sent.
    func isCompleted(_ id: Int) -> Bool { condition.withLock { completed.contains(id) } }

    /// Ends the stream after any segment in flight, and blocks until the
    /// bridge has released and returned.
    func end() -> Outcome {
        condition.withLock {
            ending = true
            while outcome == nil { condition.wait() }
            return outcome!
        }
    }

    /// Stops the stream at once (cancellation): the bridge releases every
    /// active contact and reports an unknown outcome. Does not wait.
    func stop() {
        condition.withLock {
            stopping = true
            ending = true
            condition.broadcast()
        }
    }
}

/// Runs a live stream on a thread of its own (the bridge blocks for the
/// whole hold), so the batch's other steps run meanwhile.
struct HoldTransport: Sendable {
    typealias Provider = (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias Run = @Sendable (_ uuid: String, _ version: String, _ touchscreen: String?, _ next: @escaping Provider,
                               _ shouldStop: @escaping () -> Int32) -> HoldStream.Outcome
    /// Runs the stream on the calling thread and returns when it has ended.
    /// `touchscreen`: the display's own touchscreen on a device with more
    /// than one (an iPhone Duo, `DirectTouchDisplay.touchscreen`).
    let run: Run

    init(touchscreen run: @escaping Run) { self.run = run }

    /// A transport that has no use for a named touchscreen.
    init(_ run: @escaping @Sendable (_ uuid: String, _ version: String, _ next: @escaping Provider,
                                     _ shouldStop: @escaping () -> Int32) -> HoldStream.Outcome) {
        self.run = { uuid, version, _, next, shouldStop in run(uuid, version, next, shouldStop) }
    }

    static let live = HoldTransport(touchscreen: { uuid, version, touchscreen, next, shouldStop in
        var error = [CChar](repeating: 0, count: 1024), surface: UInt64 = 0
        let status = ADCPerformLiveDigitizerReports(uuid, version, touchscreen, next, shouldStop, &surface, &error, error.count)
        return HoldStream.Outcome(status: status, surface: surface,
                                  message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    })

    /// A simulator's stream: `uuid` is the simulator's and `version` the
    /// unique identifier of the display whose touchscreen takes the reports.
    static let simulator = HoldTransport { uuid, display, next, shouldStop in
        var error = [CChar](repeating: 0, count: 1024), surface: UInt64 = 0
        let owner: SimulatorBridgeOwner
        do {
            owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: SimulatorDevice.developerDirectory(), accessibility: false)
        } catch {
            return HoldStream.Outcome(status: 1, surface: 0, message: "\(CommandFailure.classify(error).description) No input sent.")
        }
        let status = ADCSimulatorPerformLiveDigitizerReports(owner.pointer, display, next, shouldStop, &surface, &error, error.count)
        return HoldStream.Outcome(status: status, surface: surface, message: DirectSimulatorInput.message(error))
    }

    /// The C live scheduler with a local sink instead of a device, mapped
    /// onto the device function's status contract.
    static func local(_ sink: @escaping @Sendable ([UInt8]) -> Void) -> HoldTransport {
        HoldTransport { _, _, next, shouldStop in
            let status = ADCRunLiveDigitizer(next, shouldStop) { report in
                if let report { sink(Array(UnsafeBufferPointer(start: report, count: 58))) }
            }
            switch status {
            case 0: return HoldStream.Outcome(status: 0, surface: 0, message: "")
            case 2: return HoldStream.Outcome(status: 1, surface: 0, message: "Invalid first report; no input sent.")
            default: return HoldStream.Outcome(status: ADCInputOutcomeUnknown, surface: 0,
                                               message: "Live stream stopped (\(status)); release was attempted for active contacts.")
            }
        }
    }

    /// Starts the stream on a new thread; `stream.finish` is called when it ends.
    func start(_ stream: HoldStream, uuid: String, version: String, touchscreen: String? = nil,
               clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        let run = run
        let thread = Thread {
            let result = run(uuid, version, touchscreen, stream.provider(clock: clock), { stream.isStopping ? 1 : 0 })
            stream.finish(result)
        }
        thread.name = "manzanero.hold"
        thread.start()
    }
}

/// One hold while its batch runs: the stream, the device it owns and the
/// display its coordinates were mapped with.
final class HoldSession: @unchecked Sendable {
    let span: HoldSpan
    let stream: HoldStream
    let device: String
    let uuid: String
    let display: DirectTouchDisplay
    /// A simulator's display as it was read when the hold started, which
    /// every merged step reads again and compares; nil on a device.
    let simulatorDisplay: SimulatorDisplay?
    private let lease: DeviceLease?
    /// Steps that ran while the contact was down; touched by the batch only.
    var stepsWhileHeld: [Int] = []
    var mergedSteps: [Int] = []
    private let ended = NSLock()
    private var outcome: HoldStream.Outcome?

    init(span: HoldSpan, stream: HoldStream, device: String, uuid: String, display: DirectTouchDisplay, lease: DeviceLease?,
         simulatorDisplay: SimulatorDisplay? = nil) {
        self.span = span
        self.device = device
        self.stream = stream
        self.uuid = uuid
        self.display = display
        self.lease = lease
        self.simulatorDisplay = simulatorDisplay
    }

    var backend: String { simulatorDisplay == nil ? "coredevice-direct" : DirectSimulatorInput.backend }

    /// Ends the stream (or, with `stop`, stops it) and releases the lease;
    /// the outcome of the first call is kept.
    func finish(stop: Bool = false) -> HoldStream.Outcome {
        if stop { stream.stop() }
        let result = stream.end()
        ended.withLock {
            if outcome == nil {
                outcome = result
                lease?.release()
            }
        }
        return ended.withLock { outcome! }
    }

    func holdReceipt() -> [String: Any] {
        [simulatorDisplay == nil ? "resolvedCoreDeviceUUID" : "resolvedSimulatorUUID": uuid,
         "backend": backend, "operation": HoldStep.operation, "status": "holding", "verified": false,
         "device": device, "step": span.step, "contact": 0, "x": span.x, "y": span.y, "contactSlots": span.contactSlots,
         "refreshMilliseconds": HoldStep.refreshMilliseconds,
         "coordinateSpace": "normalized-current-interface", "displayRotationDegrees": display.rotation,
         "releasedBy": span.releaseStep.map { "step \($0)" } ?? "the end of the batch"]
    }

    /// The hold as the batch receipt reports it.
    func summary(releasedBy: String, releaseStep: Int?, outcome: HoldStream.Outcome) -> [String: Any] {
        let statistics = stream.statistics
        var summary: [String: Any] = ["step": span.step, "x": span.x, "y": span.y, "contactSlots": span.contactSlots,
            "stepsWhileHeld": stepsWhileHeld, "mergedSteps": mergedSteps, "releasedBy": releasedBy,
            "releaseStep": releaseStep.map { $0 as Any } ?? NSNull(),
            "release": outcome.status == 0 ? "confirmed-by-barrier" : (outcome.status == ADCInputOutcomeUnknown ? "unknown" : "not-sent"),
            "reportsSent": statistics.reports, "refreshReports": statistics.refreshes,
            "holdMilliseconds": Int(statistics.heldNanoseconds / 1_000_000), "surfaceID": outcome.surface,
            "verified": false]
        if let failure = outcome.failure { summary["error"] = failure.fields.compactMapValues { $0 } }
        return summary
    }
}

/// The hold a running batch has down, for its cancellation handler, which
/// stops the stream at once from whichever thread cancels.
final class ActiveHold: Sendable {
    private let session = Mutex<HoldSession?>(nil)

    func set(_ value: HoldSession?) { session.withLock { $0 = value } }

    func stop() { session.withLock { $0 }?.stream.stop() }
}
