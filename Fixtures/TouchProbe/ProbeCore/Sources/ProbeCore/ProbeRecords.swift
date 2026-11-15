import Foundation

/// Version of every JSON shape the probe emits. Bump it when a field changes meaning.
public let probeFormatVersion = 1

/// The UIKit touch callback that produced an event.
public enum TouchPhase: String, Encodable, Sendable, CaseIterable {
    case began, moved, ended, cancelled
}

/// A position in interface points, origin at the top left of the window.
public struct ProbePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The size of the current interface (the window) in points.
public struct InterfaceSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Position normalised to 0...1 with the origin at the top left, the same
    /// space as Manzanero's `tap x y`. Values are not clamped: a reading outside
    /// 0...1 is reported as received. A zero dimension yields 0.
    public func normalize(_ point: ProbePoint) -> ProbePoint {
        ProbePoint(x: width > 0 ? point.x / width : 0, y: height > 0 ? point.y / height : 0)
    }
}

/// One line of `touch-log.jsonl` for one UITouch callback.
public struct TouchEventRecord: Encodable, Sendable, Equatable {
    public let type = "event"
    public let session: String
    /// 1-based, increasing by one per recorded event within a session.
    public let seq: Int
    /// 0-based contact index, assigned at `began` and stable until that contact ends or is cancelled.
    /// Indexes are never reused within a session.
    public let contact: Int
    public let phase: TouchPhase
    /// Position in points, origin top left of the window.
    public let x: Double
    public let y: Double
    /// Position normalised 0...1, origin top left.
    public let nx: Double
    public let ny: Double
    /// `UITouch.timestamp`: seconds of device uptime. Only differences are meaningful.
    public let t: Double
    /// Contacts down at this event, including the one it describes (an `ended` or
    /// `cancelled` contact is still counted on its own final event).
    public let active: Int
    /// `UITouch.TouchType` name (`direct`, `indirect`, `pencil`, `indirectPointer`, `unknown`).
    public let kind: String
    /// `UITouch.majorRadius` in points, as reported by UIKit.
    public let radius: Double

    enum CodingKeys: String, CodingKey {
        case type, session, seq, contact, phase, x, y, nx, ny, t, active, kind, radius
    }
}

/// First line of the log for each session.
public struct SessionHeaderRecord: Encodable, Sendable, Equatable {
    public let type = "session"
    public let v = probeFormatVersion
    public let session: String
    /// `launch` or `reset`.
    public let reason: String
    /// Wall-clock start time (ISO 8601, UTC). Informational only.
    public let started: String
    /// Device uptime in seconds when the session started, comparable with event `t`.
    public let uptime: Double
    /// Interface size in points, `[width, height]`.
    public let size: [Double]
    /// Screen scale (pixels per point).
    public let scale: Double

    enum CodingKeys: String, CodingKey { case type, v, session, reason, started, uptime, size, scale }

    public init(session: String, reason: String, started: String, uptime: Double, size: InterfaceSize, scale: Double) {
        self.session = session
        self.reason = reason
        self.started = started
        self.uptime = ProbeJSON.round(uptime, 6)
        self.size = [ProbeJSON.round(size.width, 2), ProbeJSON.round(size.height, 2)]
        self.scale = scale
    }
}

/// Written once, as the final line, when the log reaches its byte limit.
public struct TruncationRecord: Encodable, Sendable, Equatable {
    public let type = "truncated"
    public let session: String
    /// Sequence number of the first event that was not written.
    public let firstDroppedSeq: Int
    public let limitBytes: Int

    enum CodingKeys: String, CodingKey { case type, session, firstDroppedSeq, limitBytes }
}

/// One contact of a completed gesture.
public struct GestureContact: Encodable, Sendable, Equatable {
    public let c: Int
    /// Normalised `[x, y]` at `began`.
    public let from: [Double]
    /// Normalised `[x, y]` at `ended` or `cancelled`.
    public let to: [Double]
    /// `UITouch.timestamp` of `began` (device uptime).
    public let began: Double
    /// Seconds from `began` to `ended` (or to `cancelled`).
    public let duration: Double
    /// `ended` or `cancelled`.
    public let end: String
    /// Number of `moved` events for this contact.
    public let moves: Int
}

/// Value of the `probe.last-gesture` accessibility element.
/// A gesture runs from a `began` with no contacts down until no contacts remain down.
public struct LastGestureReadout: Encodable, Sendable, Equatable {
    public let v = probeFormatVersion
    public let session: String
    /// 1-based gesture number within the session; 0 when none has completed.
    public let gesture: Int
    public let maxActive: Int
    /// Seconds from the first `began` to the last `ended`/`cancelled`.
    public let duration: Double
    /// Ordered by contact index.
    public let contacts: [GestureContact]

    enum CodingKeys: String, CodingKey { case v, session, gesture, maxActive, duration, contacts }

    public static func none(session: String) -> Self {
        Self(session: session, gesture: 0, maxActive: 0, duration: 0, contacts: [])
    }
}

/// Log state as seen by the summary.
public struct LogStatus: Encodable, Sendable, Equatable {
    /// Lines written or buffered, including the session header.
    public var lines: Int
    public var bytes: Int
    /// Events not written because the byte limit was reached.
    public var dropped: Int
    /// Last write error, if any.
    public var error: String?

    public init(lines: Int = 0, bytes: Int = 0, dropped: Int = 0, error: String? = nil) {
        self.lines = lines
        self.bytes = bytes
        self.dropped = dropped
        self.error = error
    }
}

/// Value of the `probe.summary` accessibility element.
public struct SummaryReadout: Encodable, Sendable, Equatable {
    public let v = probeFormatVersion
    public let session: String
    /// Interface size in points, `[width, height]`.
    public let size: [Double]
    /// Events recorded (equals the last `seq`).
    public let events: Int
    public let began: Int
    public let moved: Int
    public let ended: Int
    public let cancelled: Int
    /// Moved/ended/cancelled callbacks for a touch not known to this session (for
    /// example a contact that was down across a reset). Not given a `seq`.
    public let unmatched: Int
    /// Contacts down now.
    public let active: Int
    /// Most contacts down at once in this session.
    public let maxActive: Int
    /// Completed gestures in this session.
    public let gestures: Int
    public let log: LogStatus

    enum CodingKeys: String, CodingKey {
        case v, session, size, events, began, moved, ended, cancelled, unmatched, active, maxActive, gestures, log
    }
}

public enum ProbeJSON {
    /// Compact, deterministic JSON (sorted keys, no whitespace, unescaped slashes).
    public static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All emitted values are finite after rounding; a failure here is a programming error.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func string(_ value: some Encodable) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }

    /// Round to `places` decimals; non-finite input becomes 0 so JSON stays valid.
    public static func round(_ value: Double, _ places: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
