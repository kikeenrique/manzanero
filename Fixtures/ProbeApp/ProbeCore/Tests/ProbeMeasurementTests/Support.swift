import Foundation
@testable import ProbeAnalysis
import ProbeCore
@testable import ProbeTouchRunner

let probeInterface = InterfaceSize(width: 390, height: 844)

/// Drives the real `TouchRecorder` the app uses, so canned logs and readouts have the
/// probe's exact shapes. Positions are normalised; times are fake device uptime.
struct ProbeSimulator {
    struct Touch {
        var key: Int
        var time: Double
        var phase: TouchPhase
        var point: NormalizedPoint
    }

    /// How the simulated device distorts one action.
    struct Delivery {
        var dx = 0.0
        var dy = 0.0
        var holdDelta = 0.0
        /// Expected contact indexes (across the action) that never arrive.
        var drop: Set<Int> = []
        var cancel: Set<Int> = []
        /// Contacts that never lift.
        var keepDown: Set<Int> = []
        /// Contacts are delivered one after another, so no two are down at once.
        var serialize = false
        /// Suppress `moved` events.
        var noMoves = false

        static let perfect = Delivery()
    }

    private(set) var recorder: TouchRecorder<Int>
    private(set) var lines: [Data] = []
    var time = 5000.0
    private var nextKey = 1

    init(session: String = "aaaaaaaaaaaaaaaa") {
        recorder = TouchRecorder(session: session, interface: probeInterface)
        writeHeader(reason: "launch")
    }

    var session: String { recorder.session }

    mutating func relaunch(session: String) {
        recorder = TouchRecorder(session: session, interface: probeInterface)
        lines = []
        writeHeader(reason: "launch")
    }

    mutating func reset(session: String) {
        recorder.reset(session: session)
        lines = []
        writeHeader(reason: "reset")
    }

    private mutating func writeHeader(reason: String) {
        let header = SessionHeaderRecord(session: recorder.session, reason: reason, started: "2026-11-15T09:00:00Z",
                                         uptime: time, size: probeInterface, scale: 3)
        lines.append(ProbeJSON.encode(header))
    }

    mutating func play(_ touches: [Touch]) {
        let rank: [TouchPhase: Int] = [.ended: 0, .cancelled: 0, .moved: 1, .began: 2]
        let ordered = touches.enumerated().sorted {
            ($0.element.time, rank[$0.element.phase] ?? 0, $0.offset) < ($1.element.time, rank[$1.element.phase] ?? 0, $1.offset)
        }.map(\.element)
        for touch in ordered {
            let point = ProbePoint(x: touch.point.x * probeInterface.width, y: touch.point.y * probeInterface.height)
            if let event = recorder.record(key: touch.key, phase: touch.phase, point: point, timestamp: touch.time) {
                lines.append(ProbeJSON.encode(event))
            }
        }
    }

    /// Plays the action's expected contacts, distorted by `delivery`.
    mutating func deliver(_ action: TouchAction, _ delivery: Delivery = .perfect) {
        var touches: [Touch] = []
        var index = 0
        var serialTime = time
        for gesture in action.expectedGestures {
            for contact in gesture.contacts {
                defer { index += 1 }
                if delivery.drop.contains(index) { continue }
                let key = nextKey
                nextKey += 1
                let start = delivery.serialize ? serialTime : time + contact.startOffset
                let hold = contact.holdSeconds + delivery.holdDelta
                func shifted(_ p: NormalizedPoint) -> NormalizedPoint { NormalizedPoint(p.x + delivery.dx, p.y + delivery.dy) }
                touches.append(Touch(key: key, time: start, phase: .began, point: shifted(contact.start)))
                if contact.moves, !delivery.noMoves {
                    let mid = NormalizedPoint((contact.start.x + contact.end.x) / 2, (contact.start.y + contact.end.y) / 2)
                    touches.append(Touch(key: key, time: start + hold / 2, phase: .moved, point: shifted(mid)))
                    touches.append(Touch(key: key, time: start + hold * 0.9, phase: .moved, point: shifted(contact.end)))
                }
                if !delivery.keepDown.contains(index) {
                    let phase: TouchPhase = delivery.cancel.contains(index) ? .cancelled : .ended
                    touches.append(Touch(key: key, time: start + hold, phase: phase, point: shifted(contact.end)))
                }
                serialTime = start + hold + 0.05
            }
        }
        play(touches)
        time += max(action.scheduledSeconds, serialTime - time) + 1
    }

    /// One stray tap, as if a person touched the screen.
    mutating func strayTap(_ point: NormalizedPoint) {
        deliver(.tap(point))
    }

    func readback() -> ProbeReadback {
        let bytes = lines.reduce(0) { $0 + $1.count + 1 }
        return ProbeReadback(summary: recorder.summary(log: LogStatus(lines: lines.count, bytes: bytes, dropped: 0)),
                             lastGesture: recorder.lastGesture, recentGestures: recorder.recentGestures)
    }

    func logData() -> Data {
        lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    }

    /// The probe's accessibility tree as `manzanero physical <UDID> tree` prints it (trimmed).
    /// `bundleID`, when given, is reported as `nativeAttributes["3003"]` on every node, as
    /// observed for Settings on one phone; nil leaves the attribute out.
    func treeJSON(bundleID: String? = nil, includeRecent: Bool = true) -> Data {
        let readback = readback()
        var nodes: [[String: Any]] = [
            ["id": "0", "parentId": NSNull(), "depth": 0, "children": ["0.0", "0.1", "0.2", "0.3"], "attributeSource": "native-snapshot", "label": "Probe"],
            ["id": "0.0", "parentId": "0", "depth": 1, "children": [], "attributeSource": "native-snapshot",
             "identifier": "probe.touch.summary", "label": "Probe summary", "value": ProbeJSON.string(readback.summary)],
            ["id": "0.1", "parentId": "0", "depth": 1, "children": [], "attributeSource": "native-snapshot",
             "identifier": "probe.touch.last-gesture", "label": "Probe last gesture", "value": ProbeJSON.string(recorder.lastGesture)],
            ["id": "0.2", "parentId": "0", "depth": 1, "children": [], "attributeSource": "native-snapshot",
             "identifier": "probe.touch.reset", "label": "Reset probe", "value": recorder.session, "traits": "button"],
        ]
        if includeRecent {
            nodes.append(["id": "0.3", "parentId": "0", "depth": 1, "children": [], "attributeSource": "native-snapshot",
                          "identifier": "probe.touch.recent-gestures", "label": "Probe recent gestures",
                          "value": ProbeJSON.string(recorder.recentGestures)])
        }
        if let bundleID {
            nodes = nodes.map { node in
                var node = node
                node["nativeAttributes"] = ["3003": bundleID, "5003": "UIAccessibilityElementMockView"]
                return node
            }
        }
        return treeDocument(nodes: nodes)
    }
}

func treeDocument(nodes: [[String: Any]], pid: Int = 4242) -> Data {
    let root: [String: Any] = ["format": "accessibility-tree", "schemaVersion": 1, "backend": "coredevice-direct",
                               "application": ["pid": pid, "selection": "centre-hit-test"], "nodes": nodes,
                               "nodeCount": nodes.count, "coordinateSpace": "device-logical-points"]
    return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
}

/// A Springboard-like tree: something is foreground, but not the probe.
let otherAppTree = treeDocument(nodes: [
    ["id": "0", "parentId": NSNull(), "depth": 0, "children": [], "attributeSource": "native-snapshot", "label": "Home screen"],
])

final class MemoryFileSystem: RunnerFileSystem {
    var files: [String: Data] = [:]
    var directories: Set<String> = []

    func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func createDirectory(_ path: String) throws {
        var current = ""
        for part in path.split(separator: "/") {
            current += current.isEmpty ? String(part) : "/" + part
            directories.insert(current)
        }
    }
    func write(_ data: Data, to path: String) throws { files[path] = data }
    func read(_ path: String) throws -> Data {
        guard let data = files[path] else { throw RunnerError("no file \(path)") }
        return data
    }
}

final class FakeClock: RunnerClock {
    var sleeps: [Double] = []
    private var ticks = 0.0
    func sleep(seconds: Double) { sleeps.append(seconds) }
    func now() -> Date { Date(timeIntervalSince1970: 1_794_000_000) }
    func uptime() -> Double { ticks += 0.25; return ticks }
}

/// A fake phone running the probe. It answers Manzanero argument vectors the way the CLI
/// would, applies each recognised action to the simulator, and records every invocation.
final class FakeDevice: ManzaneroInvoking {
    var simulator = ProbeSimulator()
    let fileSystem: MemoryFileSystem
    let device: String
    let actions: [TouchAction]
    var invocations: [[String]] = []
    var foreground = true
    var resetTakesEffect = true
    var sessions = ["bbbbbbbbbbbbbbbb", "cccccccccccccccc", "dddddddddddddddd"]
    /// Per sent-action index (0-based): how the device distorts it.
    var deliveries: [Int: ProbeSimulator.Delivery] = [:]
    var actionExitCodes: [Int: Int32] = [:]
    var timedOutActions: Set<Int> = []
    /// Per tree call (1-based): run before answering, for example to relaunch the app.
    var beforeTree: [Int: (inout ProbeSimulator) -> Void] = [:]
    var failingTrees: Set<Int> = []
    /// Reported as `nativeAttributes["3003"]` on every tree node; nil leaves it out.
    var treeBundleID: String?
    /// Per tree call (1-based): a bundle identifier replacing `treeBundleID` for that call.
    var treeBundleIDOverrides: [Int: String] = [:]
    /// Leave the recent-gestures element out of the tree, as an older probe build would.
    var omitRecentGestures = false
    var pullExitCode: Int32 = 0
    var pullCreatesDirectory = false
    /// Replaces the pulled log bytes.
    var pulledLog: ((ProbeSimulator) -> Data)?
    var rejectDryRun: (([String]) -> Bool)?
    private(set) var treeCalls = 0
    private(set) var sentActions = 0

    init(fileSystem: MemoryFileSystem, device: String = "00008000-TESTDEVICE", actions: [TouchAction]) {
        self.fileSystem = fileSystem
        self.device = device
        self.actions = actions
    }

    func invoke(executable: String, arguments: [String], timeout: Double) throws -> InvocationResult {
        invocations.append(arguments)
        if arguments.first == "--dry-run" {
            let rejected = rejectDryRun?(arguments) ?? false
            let stdout = rejected ? "" : #"{"operation":"plan"}"#
            let stderr = rejected ? "Physical input coordinates must be normalized numbers from 0 to 1.\n" : ""
            return InvocationResult(exitCode: rejected ? 1 : 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
        guard arguments.count >= 3, arguments[0] == "physical", arguments[1] == device else {
            return InvocationResult(exitCode: 1, stderr: Data("Unsupported command\n".utf8))
        }
        switch arguments[2] {
        case "tree":
            treeCalls += 1
            beforeTree[treeCalls]?(&simulator)
            if failingTrees.contains(treeCalls) {
                return InvocationResult(exitCode: 1, stderr: Data("Direct physical tree failed: test.\n".utf8))
            }
            let tree = simulator.treeJSON(bundleID: treeBundleIDOverrides[treeCalls] ?? treeBundleID,
                                          includeRecent: !omitRecentGestures)
            return InvocationResult(exitCode: 0, stdout: foreground ? tree : otherAppTree)
        case "press-id":
            guard arguments == ["physical", device, "press-id", "probe.touch.reset"] else {
                return InvocationResult(exitCode: 1, stderr: Data("unexpected press\n".utf8))
            }
            if resetTakesEffect { simulator.reset(session: sessions.removeFirst()) }
            return InvocationResult(exitCode: 0, stdout: Data(#"{"operation":"press","status":"accepted","verified":false}"#.utf8))
        case "pull":
            guard arguments.count == 6, arguments[4] == "Documents/touch-log.jsonl" else {
                return InvocationResult(exitCode: 1, stderr: Data("bad pull\n".utf8))
            }
            if pullExitCode != 0 { return InvocationResult(exitCode: pullExitCode, stderr: Data("devicectl failed\n".utf8)) }
            let data = pulledLog?(simulator) ?? simulator.logData()
            if pullCreatesDirectory {
                try fileSystem.createDirectory(arguments[5])
                try fileSystem.write(data, to: arguments[5] + "/touch-log.jsonl")
            } else {
                try fileSystem.write(data, to: arguments[5])
            }
            return InvocationResult(exitCode: 0, stdout: Data(#"{"info":{"outcome":"success"}}"#.utf8))
        default:
            let tail = Array(arguments.dropFirst(2))
            guard let action = actions.first(where: { $0.cliArguments == tail }) else {
                return InvocationResult(exitCode: 1, stderr: Data("unknown action \(tail)\n".utf8))
            }
            let index = sentActions
            sentActions += 1
            let exitCode = actionExitCodes[index] ?? 0
            if timedOutActions.contains(index) {
                simulator.deliver(action, deliveries[index] ?? .perfect)
                return InvocationResult(exitCode: 130, timedOut: true)
            }
            if exitCode != 0 {
                if let delivery = deliveries[index] { simulator.deliver(action, delivery) }
                return InvocationResult(exitCode: exitCode, stderr: Data("Primary display is off.\n".utf8))
            }
            simulator.deliver(action, deliveries[index] ?? .perfect)
            return InvocationResult(exitCode: 0, stdout: Data(#"{"operation":"\#(action.kind)","status":"dispatched","verified":false,"releaseVerified":false}"#.utf8))
        }
    }
}

/// Builds comparison input for a plan replayed on a simulator, with a readback after every action.
func simulatedRun(_ actions: [TouchAction], deliveries: [Int: ProbeSimulator.Delivery] = [:],
                  beforeAction: [Int: (inout ProbeSimulator) -> Void] = [:],
                  afterAction: [Int: (inout ProbeSimulator) -> Void] = [:])
    -> (baseline: ProbeReadback, attempts: [ActionAttempt], simulator: ProbeSimulator) {
    var simulator = ProbeSimulator()
    simulator.reset(session: "bbbbbbbbbbbbbbbb")
    let baseline = simulator.readback()
    var attempts: [ActionAttempt] = []
    for (index, action) in actions.enumerated() {
        beforeAction[index]?(&simulator)
        simulator.deliver(action, deliveries[index] ?? .perfect)
        afterAction[index]?(&simulator)
        attempts.append(ActionAttempt(sequence: index + 1, round: 1, planned: PlannedAction(id: "a\(index + 1)", action: action),
                                      dispatch: DispatchOutcome(state: .dispatched, exitCode: 0, receiptStatus: "dispatched"),
                                      readback: simulator.readback()))
    }
    return (baseline, attempts, simulator)
}

let defaultTolerances = Tolerances(position: TouchPlan.defaultPositionTolerance, duration: TouchPlan.defaultDurationTolerance)
