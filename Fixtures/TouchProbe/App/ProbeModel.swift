import ProbeCore
import UIKit

/// Main-actor owner of the recorder and the log. UIKit types stop here; the
/// recording rules live in ProbeCore.
@MainActor
final class ProbeModel {
    struct Mark {
        let contact: Int
        let point: CGPoint
    }

    private(set) var recorder: TouchRecorder<ObjectIdentifier>
    private let log: TouchLog
    private var started = false
    private var scale: Double = 1
    /// Landing positions of recent contacts, newest last, for the on-screen display.
    private(set) var landings: [Mark] = []
    /// Current positions of contacts that are down.
    private(set) var current: [Int: CGPoint] = [:]
    var onChange: (() -> Void)?

    static let maximumLandings = 40

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        log = TouchLog(url: documents.appendingPathComponent("touch-log.jsonl"))
        recorder = TouchRecorder(session: makeProbeSessionID(), interface: InterfaceSize(width: 0, height: 0))
    }

    var summaryJSON: String { ProbeJSON.string(recorder.summary(log: log.status)) }
    var lastGestureJSON: String { ProbeJSON.string(recorder.lastGesture) }
    var summary: SummaryReadout { recorder.summary(log: log.status) }

    /// Called on layout. The log session starts once the interface size is known.
    func interfaceDidChange(size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        self.scale = Double(scale)
        recorder.setInterface(InterfaceSize(width: Double(size.width), height: Double(size.height)))
        if !started {
            started = true
            startLog(reason: "launch")
        }
    }

    /// Clear the log and all counters and start a new session.
    func reset() {
        recorder.reset(session: makeProbeSessionID())
        landings.removeAll()
        current.removeAll()
        startLog(reason: "reset")
        onChange?()
    }

    func flush() { log.flush() }

    /// Record each touch of one UIKit callback. Positions are in window coordinates.
    func handle(_ touches: Set<UITouch>, phase: TouchPhase) {
        guard started else { return }
        // A set has no order; record by timestamp so sequence numbers follow UIKit's clock.
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let location = touch.location(in: nil)
            let key = ObjectIdentifier(touch)
            guard let event = recorder.record(
                key: key, phase: phase, point: ProbePoint(x: Double(location.x), y: Double(location.y)),
                timestamp: touch.timestamp, kind: Self.kind(touch.type), radius: Double(touch.majorRadius)) else { continue }
            log.append(event)
            switch phase {
            case .began:
                landings.append(Mark(contact: event.contact, point: location))
                if landings.count > Self.maximumLandings { landings.removeFirst(landings.count - Self.maximumLandings) }
                current[event.contact] = location
            case .moved:
                current[event.contact] = location
            case .ended, .cancelled:
                current[event.contact] = nil
            }
        }
        // Make a completed gesture available to `pull` without waiting for the buffer to fill.
        if recorder.activeCount == 0 { log.flush() }
        onChange?()
    }

    private func startLog(reason: String) {
        let header = SessionHeaderRecord(
            session: recorder.session, reason: reason,
            started: Date().formatted(.iso8601),
            uptime: ProcessInfo.processInfo.systemUptime,
            size: recorder.interface, scale: scale)
        log.start(header)
    }

    private static func kind(_ type: UITouch.TouchType) -> String {
        switch type {
        case .direct: "direct"
        case .indirect: "indirect"
        case .pencil: "pencil"
        case .indirectPointer: "indirectPointer"
        @unknown default: "unknown"
        }
    }
}
