import Foundation

/// A normalised `0...1` position, origin top left: the space of Manzanero's
/// physical touch commands and of the probe's `nx`/`ny`. Encoded as `[x, y]`.
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a point is exactly [x, y]")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    func distance(to other: NormalizedPoint) -> Double { hypot(other.x - x, other.y - y) }
}

/// One straight path of a `multi-drag`, encoded as `[start-x, start-y, end-x, end-y]`.
public struct TouchPath: Codable, Sendable, Equatable {
    public var from: NormalizedPoint
    public var to: NormalizedPoint

    public init(from: NormalizedPoint, to: NormalizedPoint) {
        self.from = from
        self.to = to
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        from = NormalizedPoint(try container.decode(Double.self), try container.decode(Double.self))
        to = NormalizedPoint(try container.decode(Double.self), try container.decode(Double.self))
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a path is exactly [x1, y1, x2, y2]")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [from.x, from.y, to.x, to.y] { try container.encode(value) }
    }
}

/// One contact of a gesture-sequence frame, as Manzanero's `gesture` command takes it.
public struct SequenceTouch: Codable, Sendable, Equatable {
    public var id: Int
    public var x: Double
    public var y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// One complete-state frame of a gesture sequence.
public struct SequenceFrame: Codable, Sendable, Equatable {
    public var ms: Int
    public var touches: [SequenceTouch]

    public init(ms: Int, touches: [SequenceTouch]) {
        self.ms = ms
        self.touches = touches
    }
}

/// The touch actions the runner can send, one per Manzanero physical command.
public enum TouchAction: Sendable, Equatable {
    case tap(NormalizedPoint)
    case longPress(NormalizedPoint, seconds: Double)
    case swipe(from: NormalizedPoint, to: NormalizedPoint, seconds: Double)
    case drag(from: NormalizedPoint, to: NormalizedPoint, seconds: Double)
    case multiTap([NormalizedPoint])
    case multiDrag(seconds: Double, paths: [TouchPath])
    case pinch(center: NormalizedPoint, startSpan: Double, endSpan: Double, seconds: Double)
    case sequence([SequenceFrame])

    /// The Manzanero operation name, also the plan file's `kind`.
    public var kind: String {
        switch self {
        case .tap: "tap"
        case .longPress: "long-press"
        case .swipe: "swipe"
        case .drag: "drag"
        case .multiTap: "multi-tap"
        case .multiDrag: "multi-drag"
        case .pinch: "pinch"
        case .sequence: "gesture"
        }
    }
}

/// One planned action. JSON: `{"id": "...", "kind": "tap", ...kind-specific fields}`.
public struct PlannedAction: Codable, Sendable, Equatable {
    public var id: String
    public var action: TouchAction

    public init(id: String, action: TouchAction) {
        self.id = id
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, seconds, from, to, points, paths, center, startSpan, endSpan, frames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let kind = try c.decode(String.self, forKey: .kind)
        func point() throws -> NormalizedPoint {
            NormalizedPoint(try c.decode(Double.self, forKey: .x), try c.decode(Double.self, forKey: .y))
        }
        switch kind {
        case "tap": action = .tap(try point())
        case "long-press": action = .longPress(try point(), seconds: try c.decode(Double.self, forKey: .seconds))
        case "swipe", "drag":
            let from = try c.decode(NormalizedPoint.self, forKey: .from)
            let to = try c.decode(NormalizedPoint.self, forKey: .to)
            let seconds = try c.decode(Double.self, forKey: .seconds)
            action = kind == "swipe" ? .swipe(from: from, to: to, seconds: seconds) : .drag(from: from, to: to, seconds: seconds)
        case "multi-tap": action = .multiTap(try c.decode([NormalizedPoint].self, forKey: .points))
        case "multi-drag":
            action = .multiDrag(seconds: try c.decode(Double.self, forKey: .seconds),
                                paths: try c.decode([TouchPath].self, forKey: .paths))
        case "pinch":
            action = .pinch(center: try c.decode(NormalizedPoint.self, forKey: .center),
                            startSpan: try c.decode(Double.self, forKey: .startSpan),
                            endSpan: try c.decode(Double.self, forKey: .endSpan),
                            seconds: try c.decode(Double.self, forKey: .seconds))
        case "gesture": action = .sequence(try c.decode([SequenceFrame].self, forKey: .frames))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown action kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(action.kind, forKey: .kind)
        switch action {
        case .tap(let p):
            try c.encode(p.x, forKey: .x)
            try c.encode(p.y, forKey: .y)
        case .longPress(let p, let seconds):
            try c.encode(p.x, forKey: .x)
            try c.encode(p.y, forKey: .y)
            try c.encode(seconds, forKey: .seconds)
        case .swipe(let from, let to, let seconds), .drag(let from, let to, let seconds):
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(seconds, forKey: .seconds)
        case .multiTap(let points): try c.encode(points, forKey: .points)
        case .multiDrag(let seconds, let paths):
            try c.encode(seconds, forKey: .seconds)
            try c.encode(paths, forKey: .paths)
        case .pinch(let center, let startSpan, let endSpan, let seconds):
            try c.encode(center, forKey: .center)
            try c.encode(startSpan, forKey: .startSpan)
            try c.encode(endSpan, forKey: .endSpan)
            try c.encode(seconds, forKey: .seconds)
        case .sequence(let frames): try c.encode(frames, forKey: .frames)
        }
    }
}

/// A measurement plan: the actions to send, in order, and the comparison tolerances.
public struct TouchPlan: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public static let defaultSettleSeconds = 0.5
    public static let defaultPositionTolerance = 0.03
    public static let defaultDurationTolerance = 0.15

    public var v: Int
    public var name: String
    /// Pause after each command returns, before the readback (seconds, 0...5).
    public var settleSeconds: Double?
    /// Normalised distance above which a start or end position is flagged.
    public var positionTolerance: Double?
    /// Seconds of hold-duration error above which a contact is flagged.
    public var durationTolerance: Double?
    public var actions: [PlannedAction]

    public init(name: String, settleSeconds: Double? = nil, positionTolerance: Double? = nil,
                durationTolerance: Double? = nil, actions: [PlannedAction]) {
        v = Self.formatVersion
        self.name = name
        self.settleSeconds = settleSeconds
        self.positionTolerance = positionTolerance
        self.durationTolerance = durationTolerance
        self.actions = actions
    }

    public var settle: Double { settleSeconds ?? Self.defaultSettleSeconds }
    public var tolerances: Tolerances {
        Tolerances(position: positionTolerance ?? Self.defaultPositionTolerance,
                   duration: durationTolerance ?? Self.defaultDurationTolerance)
    }

    public static func decode(_ data: Data) throws -> TouchPlan {
        try JSONDecoder().decode(TouchPlan.self, from: data)
    }
}

public struct Tolerances: Codable, Sendable, Equatable {
    public var position: Double
    public var duration: Double

    public init(position: Double, duration: Double) {
        self.position = position
        self.duration = duration
    }
}

// MARK: - Validation

public struct PlanValidation: Sendable, Equatable {
    /// Problems that Manzanero would reject or that make the plan unusable. A plan with errors is not run.
    public var errors: [String] = []
    /// Legal but risky choices, such as points close to a screen edge.
    public var warnings: [String] = []
    public var isValid: Bool { errors.isEmpty }
}

extension TouchPlan {
    /// Checks the plan against Manzanero's documented input limits (docs/native-input.md,
    /// docs/multitouch.md, docs/gesture-sequences.md) and the probe's layout, before any device contact.
    public func validate() -> PlanValidation {
        var result = PlanValidation()
        if v != Self.formatVersion { result.errors.append("plan format v\(v) is not supported; expected v\(Self.formatVersion)") }
        if actions.isEmpty { result.errors.append("plan has no actions") }
        if actions.count > 200 { result.errors.append("plan has \(actions.count) actions; at most 200") }
        if let settleSeconds, !(settleSeconds.isFinite && (0...5).contains(settleSeconds)) {
            result.errors.append("settleSeconds must be 0...5")
        }
        if let positionTolerance, !(positionTolerance.isFinite && positionTolerance > 0) {
            result.errors.append("positionTolerance must be positive")
        }
        if let durationTolerance, !(durationTolerance.isFinite && durationTolerance > 0) {
            result.errors.append("durationTolerance must be positive")
        }
        var ids = Set<String>()
        for (index, planned) in actions.enumerated() {
            let label = "action \(index + 1) (\(planned.id))"
            if planned.id.isEmpty || planned.id.utf8.count > 64
                || !planned.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) {
                result.errors.append("\(label): id must be 1...64 ASCII letters, digits, '-', '_' or '.'")
            }
            if !ids.insert(planned.id).inserted { result.errors.append("\(label): duplicate id") }
            for message in planned.action.validationErrors() { result.errors.append("\(label): \(message)") }
            for message in planned.action.validationWarnings() { result.warnings.append("\(label): \(message)") }
        }
        return result
    }
}

extension TouchAction {
    private static func validCoordinate(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }

    func validationErrors() -> [String] {
        var errors: [String] = []
        func points(_ list: [NormalizedPoint]) {
            if !list.allSatisfy({ Self.validCoordinate($0.x) && Self.validCoordinate($0.y) }) {
                errors.append("coordinates must be finite and within 0...1")
            }
        }
        func movement(_ seconds: Double) {
            if !(seconds.isFinite && (0.03...10).contains(seconds)) { errors.append("movement seconds must be 0.03...10") }
        }
        switch self {
        case .tap(let p): points([p])
        case .longPress(let p, let seconds):
            points([p])
            if !(seconds.isFinite && (0.1...10).contains(seconds)) { errors.append("long-press seconds must be 0.1...10") }
        case .swipe(let from, let to, let seconds), .drag(let from, let to, let seconds):
            points([from, to])
            movement(seconds)
        case .multiTap(let list):
            points(list)
            if !(2...5).contains(list.count) { errors.append("multi-tap takes 2...5 points") }
            if Set(list.map { "\($0.x),\($0.y)" }).count != list.count { errors.append("multi-tap points must be distinct") }
        case .multiDrag(let seconds, let paths):
            points(paths.flatMap { [$0.from, $0.to] })
            movement(seconds)
            if !(2...5).contains(paths.count) { errors.append("multi-drag takes 2...5 paths") }
        case .pinch(let center, let startSpan, let endSpan, let seconds):
            points([center])
            movement(seconds)
            let spans = [startSpan, endSpan]
            if !spans.allSatisfy({ $0.isFinite && $0 > 0 }) || startSpan == endSpan {
                errors.append("pinch spans must be positive and different")
            } else if !spans.allSatisfy({ Self.validCoordinate(center.x - $0 / 2) && Self.validCoordinate(center.x + $0 / 2) }) {
                errors.append("pinch contacts must stay on screen around the centre")
            }
        case .sequence(let frames):
            errors += Self.sequenceErrors(frames)
        }
        return errors
    }

    private static func sequenceErrors(_ frames: [SequenceFrame]) -> [String] {
        var errors: [String] = []
        if !(2...512).contains(frames.count) { errors.append("gesture takes 2...512 frames") }
        guard let first = frames.first, let last = frames.last else { return errors }
        if first.ms != 0 { errors.append("first frame must be at 0 ms") }
        if zip(frames, frames.dropFirst()).contains(where: { $0.ms >= $1.ms }) { errors.append("frame ms must strictly increase") }
        if last.ms > 10_000 { errors.append("last frame must be at or before 10000 ms") }
        if first.touches.isEmpty { errors.append("first frame needs at least one touch") }
        if !last.touches.isEmpty { errors.append("last frame must have no touches") }
        var used = Set<Int>()
        for frame in frames {
            let ids = frame.touches.map(\.id)
            if Set(ids).count != ids.count { errors.append("ids must be unique within a frame (\(frame.ms) ms)") }
            if !ids.allSatisfy({ (0...4).contains($0) }) { errors.append("ids must be 0...4 (\(frame.ms) ms)") }
            if !frame.touches.allSatisfy({ validCoordinate($0.x) && validCoordinate($0.y) }) {
                errors.append("coordinates must be finite and within 0...1 (\(frame.ms) ms)")
            }
            used.formUnion(ids)
        }
        if !used.isEmpty, used != Set(0..<used.count) { errors.append("used ids must be contiguous from 0") }
        if sequenceJSON(frames).utf8.count > 65_536 { errors.append("gesture JSON exceeds 65536 bytes") }
        return errors
    }

    /// Probe-specific advice: the edges invite system gestures and the reset box sits near the bottom centre.
    func validationWarnings() -> [String] {
        var warnings: [String] = []
        let all = allPoints
        if all.contains(where: { $0.x < 0.05 || $0.x > 0.95 || $0.y < 0.05 || $0.y > 0.95 }) {
            warnings.append("a point lies within 0.05 of a screen edge, where system gestures can take the touch")
        }
        // Reset box: 180 x 52 points, 80...132 points above the bottom, centred; about
        // x 0.27...0.73, y 0.84...0.91 on a 390 x 844 iPhone. Touching it records, it does not reset.
        if all.contains(where: { (0.25...0.75).contains($0.x) && (0.82...0.93).contains($0.y) }) {
            warnings.append("a point lies on or near the probe's reset box; it records like any touch but is outlined on screen")
        }
        return warnings
    }

    var allPoints: [NormalizedPoint] {
        switch self {
        case .tap(let p), .longPress(let p, _): [p]
        case .swipe(let from, let to, _), .drag(let from, let to, _): [from, to]
        case .multiTap(let list): list
        case .multiDrag(_, let paths): paths.flatMap { [$0.from, $0.to] }
        case .pinch(let center, let a, let b, _):
            [NormalizedPoint(center.x - a / 2, center.y), NormalizedPoint(center.x + a / 2, center.y),
             NormalizedPoint(center.x - b / 2, center.y), NormalizedPoint(center.x + b / 2, center.y)]
        case .sequence(let frames): frames.flatMap { $0.touches.map { NormalizedPoint($0.x, $0.y) } }
        }
    }
}

// MARK: - Commands

extension TouchAction {
    /// The Manzanero operation and its operands, as an argument array (no shell);
    /// the runner appends the target (`--device <UDID>` or `--simulator <UUID>`).
    public var cliArguments: [String] {
        let n = formatCLINumber
        switch self {
        case .tap(let p): return ["tap", n(p.x), n(p.y)]
        case .longPress(let p, let seconds): return ["long-press", n(p.x), n(p.y), n(seconds)]
        case .swipe(let from, let to, let seconds): return ["swipe", n(from.x), n(from.y), n(to.x), n(to.y), n(seconds)]
        case .drag(let from, let to, let seconds): return ["drag", n(from.x), n(from.y), n(to.x), n(to.y), n(seconds)]
        case .multiTap(let list): return ["multi-tap"] + list.flatMap { [n($0.x), n($0.y)] }
        case .multiDrag(let seconds, let paths):
            return ["multi-drag", n(seconds)] + paths.flatMap { [n($0.from.x), n($0.from.y), n($0.to.x), n($0.to.y)] }
        case .pinch(let center, let a, let b, let seconds): return ["pinch", n(center.x), n(center.y), n(a), n(b), n(seconds)]
        case .sequence(let frames): return ["gesture", Self.sequenceJSON(frames)]
        }
    }

    static func sequenceJSON(_ frames: [SequenceFrame]) -> String {
        struct Sequence: Encodable { let frames: [SequenceFrame] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Sequence(frames: frames))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Seconds from first contact down to last release, as Manzanero schedules it.
    public var scheduledSeconds: Double {
        expectedGestures.flatMap(\.contacts).map { $0.startOffset + $0.holdSeconds }.max() ?? 0
    }
}

/// Up to six decimals without trailing zeros, in the POSIX locale (`0.5`, `0.123457`, `1`).
public func formatCLINumber(_ value: Double) -> String {
    var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

// MARK: - Expected effect

/// One contact the probe should see if the action is delivered as scheduled.
public struct ExpectedContact: Codable, Sendable, Equatable {
    public var start: NormalizedPoint
    public var end: NormalizedPoint
    /// Scheduled seconds from this contact's down to its release.
    public var holdSeconds: Double
    /// Scheduled seconds from the action's first down to this contact's down.
    public var startOffset: Double
    /// Whether the scheduled path moves, so `moved` events are expected.
    public var moves: Bool
}

/// One gesture in the probe's sense: from a first contact down until no contact remains down.
public struct ExpectedGesture: Codable, Sendable, Equatable {
    public var contacts: [ExpectedContact]
    /// Most contacts scheduled down at once.
    public var maxActive: Int
}

extension TouchAction {
    /// Hold timings follow Manzanero's schedules: tap and multi-tap hold 80 ms; generated
    /// movement releases 1 ms after the requested movement duration; a long press holds
    /// for its seconds; gesture sequences release a contact at the first frame that omits it.
    public var expectedGestures: [ExpectedGesture] {
        func contact(_ a: NormalizedPoint, _ b: NormalizedPoint, _ hold: Double, offset: Double = 0) -> ExpectedContact {
            ExpectedContact(start: a, end: b, holdSeconds: hold, startOffset: offset, moves: a != b)
        }
        switch self {
        case .tap(let p): return [ExpectedGesture(contacts: [contact(p, p, 0.08)], maxActive: 1)]
        case .longPress(let p, let seconds): return [ExpectedGesture(contacts: [contact(p, p, seconds)], maxActive: 1)]
        case .swipe(let from, let to, let seconds), .drag(let from, let to, let seconds):
            return [ExpectedGesture(contacts: [contact(from, to, seconds + 0.001)], maxActive: 1)]
        case .multiTap(let list):
            return [ExpectedGesture(contacts: list.map { contact($0, $0, 0.08) }, maxActive: list.count)]
        case .multiDrag(let seconds, let paths):
            return [ExpectedGesture(contacts: paths.map { contact($0.from, $0.to, seconds + 0.001) }, maxActive: paths.count)]
        case .pinch(let center, let a, let b, let seconds):
            let left = contact(NormalizedPoint(center.x - a / 2, center.y), NormalizedPoint(center.x - b / 2, center.y), seconds + 0.001)
            let right = contact(NormalizedPoint(center.x + a / 2, center.y), NormalizedPoint(center.x + b / 2, center.y), seconds + 0.001)
            return [ExpectedGesture(contacts: [left, right], maxActive: 2)]
        case .sequence(let frames): return Self.sequenceGestures(frames)
        }
    }

    private static func sequenceGestures(_ frames: [SequenceFrame]) -> [ExpectedGesture] {
        struct Open { var start: NormalizedPoint; var last: NormalizedPoint; var startMS: Int; var moved: Bool }
        var gestures: [ExpectedGesture] = []
        var open: [Int: Open] = [:]
        var finished: [(Open, Int)] = []
        var maxActive = 0
        for frame in frames {
            let present = Dictionary(frame.touches.map { ($0.id, NormalizedPoint($0.x, $0.y)) }, uniquingKeysWith: { a, _ in a })
            for (id, contact) in open where present[id] == nil {
                finished.append((contact, frame.ms))
                open[id] = nil
            }
            for (id, point) in present {
                if var contact = open[id] {
                    if contact.last != point { contact.moved = true }
                    contact.last = point
                    open[id] = contact
                } else {
                    open[id] = Open(start: point, last: point, startMS: frame.ms, moved: false)
                }
            }
            maxActive = max(maxActive, open.count)
            if open.isEmpty, !finished.isEmpty {
                let contacts = finished.sorted { ($0.0.startMS, $0.0.start.x) < ($1.0.startMS, $1.0.start.x) }.map { contact, endMS in
                    ExpectedContact(start: contact.start, end: contact.last, holdSeconds: Double(endMS - contact.startMS) / 1000,
                                    startOffset: Double(contact.startMS) / 1000, moves: contact.moved)
                }
                gestures.append(ExpectedGesture(contacts: contacts, maxActive: maxActive))
                finished = []
                maxActive = 0
            }
        }
        return gestures
    }
}

// MARK: - Default plan

extension TouchPlan {
    /// A modest plan of 14 actions with about 5 seconds of scheduled contact time. Every
    /// point stays within x 0.25...0.75 and y 0.3...0.65: away from the edges, where system
    /// gestures start, and from the reset box near the bottom. No action is a three-finger
    /// double tap (the iOS Zoom shortcut) or an edge swipe.
    public static let builtIn = TouchPlan(name: "default", actions: [
        PlannedAction(id: "tap-centre", action: .tap(NormalizedPoint(0.5, 0.45))),
        PlannedAction(id: "tap-upper-left", action: .tap(NormalizedPoint(0.3, 0.3))),
        PlannedAction(id: "tap-lower-right", action: .tap(NormalizedPoint(0.7, 0.65))),
        PlannedAction(id: "long-press-0.8s", action: .longPress(NormalizedPoint(0.5, 0.5), seconds: 0.8)),
        PlannedAction(id: "swipe-up", action: .swipe(from: NormalizedPoint(0.5, 0.65), to: NormalizedPoint(0.5, 0.35), seconds: 0.5)),
        PlannedAction(id: "drag-right", action: .drag(from: NormalizedPoint(0.3, 0.55), to: NormalizedPoint(0.7, 0.55), seconds: 0.8)),
        PlannedAction(id: "multi-tap-2", action: .multiTap([NormalizedPoint(0.35, 0.45), NormalizedPoint(0.65, 0.45)])),
        PlannedAction(id: "pinch-spread", action: .pinch(center: NormalizedPoint(0.5, 0.5), startSpan: 0.2, endSpan: 0.5, seconds: 0.6)),
        PlannedAction(id: "multi-tap-3", action: .multiTap([NormalizedPoint(0.3, 0.4), NormalizedPoint(0.5, 0.55), NormalizedPoint(0.7, 0.4)])),
        PlannedAction(id: "multi-drag-3", action: .multiDrag(seconds: 0.6, paths: [
            TouchPath(from: NormalizedPoint(0.3, 0.6), to: NormalizedPoint(0.3, 0.4)),
            TouchPath(from: NormalizedPoint(0.5, 0.6), to: NormalizedPoint(0.5, 0.4)),
            TouchPath(from: NormalizedPoint(0.7, 0.6), to: NormalizedPoint(0.7, 0.4)),
        ])),
        PlannedAction(id: "multi-tap-4", action: .multiTap([
            NormalizedPoint(0.3, 0.4), NormalizedPoint(0.7, 0.4), NormalizedPoint(0.3, 0.6), NormalizedPoint(0.7, 0.6),
        ])),
        PlannedAction(id: "multi-tap-5", action: .multiTap([
            NormalizedPoint(0.25, 0.4), NormalizedPoint(0.5, 0.35), NormalizedPoint(0.75, 0.4),
            NormalizedPoint(0.35, 0.6), NormalizedPoint(0.65, 0.6),
        ])),
        PlannedAction(id: "sequence-double-tap", action: .sequence([
            SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.45)]),
            SequenceFrame(ms: 60, touches: []),
            SequenceFrame(ms: 260, touches: [SequenceTouch(id: 0, x: 0.5, y: 0.45)]),
            SequenceFrame(ms: 320, touches: []),
        ])),
        PlannedAction(id: "sequence-staggered-2", action: .sequence([
            SequenceFrame(ms: 0, touches: [SequenceTouch(id: 0, x: 0.35, y: 0.5)]),
            SequenceFrame(ms: 150, touches: [SequenceTouch(id: 0, x: 0.35, y: 0.5), SequenceTouch(id: 1, x: 0.65, y: 0.5)]),
            SequenceFrame(ms: 450, touches: [SequenceTouch(id: 1, x: 0.65, y: 0.5)]),
            SequenceFrame(ms: 600, touches: []),
        ])),
    ])
}
