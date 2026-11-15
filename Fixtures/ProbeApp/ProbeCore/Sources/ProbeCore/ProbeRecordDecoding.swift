import Foundation

// Decoding of the probe's own JSON shapes, so host-side tools (the touch
// measurement runner) read the log and readouts with the same types the app
// writes. The encoded formats are unchanged. Each decoder checks the constant
// `type` or `v` field instead of silently accepting another shape.

private func requireConstant<Key: CodingKey, Value: Decodable & Equatable>(
    _ container: KeyedDecodingContainer<Key>, _ key: Key, equals expected: Value
) throws {
    let value = try container.decode(Value.self, forKey: key)
    guard value == expected else {
        throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                               debugDescription: "expected \(expected), found \(value)")
    }
}

extension TouchEventRecord: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try requireConstant(c, .type, equals: "event")
        self.init(session: try c.decode(String.self, forKey: .session),
                  seq: try c.decode(Int.self, forKey: .seq),
                  contact: try c.decode(Int.self, forKey: .contact),
                  phase: try c.decode(TouchPhase.self, forKey: .phase),
                  x: try c.decode(Double.self, forKey: .x),
                  y: try c.decode(Double.self, forKey: .y),
                  nx: try c.decode(Double.self, forKey: .nx),
                  ny: try c.decode(Double.self, forKey: .ny),
                  t: try c.decode(Double.self, forKey: .t),
                  active: try c.decode(Int.self, forKey: .active),
                  kind: try c.decode(String.self, forKey: .kind),
                  radius: try c.decode(Double.self, forKey: .radius))
    }
}

extension SessionHeaderRecord: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try requireConstant(c, .type, equals: "session")
        try requireConstant(c, .v, equals: probeFormatVersion)
        session = try c.decode(String.self, forKey: .session)
        reason = try c.decode(String.self, forKey: .reason)
        started = try c.decode(String.self, forKey: .started)
        uptime = try c.decode(Double.self, forKey: .uptime)
        size = try c.decode([Double].self, forKey: .size)
        scale = try c.decode(Double.self, forKey: .scale)
    }
}

extension TruncationRecord: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try requireConstant(c, .type, equals: "truncated")
        self.init(session: try c.decode(String.self, forKey: .session),
                  firstDroppedSeq: try c.decode(Int.self, forKey: .firstDroppedSeq),
                  limitBytes: try c.decode(Int.self, forKey: .limitBytes))
    }
}

extension LastGestureReadout: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try requireConstant(c, .v, equals: probeFormatVersion)
        self.init(session: try c.decode(String.self, forKey: .session),
                  gesture: try c.decode(Int.self, forKey: .gesture),
                  maxActive: try c.decode(Int.self, forKey: .maxActive),
                  duration: try c.decode(Double.self, forKey: .duration),
                  contacts: try c.decode([GestureContact].self, forKey: .contacts))
    }
}

extension SummaryReadout: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try requireConstant(c, .v, equals: probeFormatVersion)
        self.init(session: try c.decode(String.self, forKey: .session),
                  size: try c.decode([Double].self, forKey: .size),
                  events: try c.decode(Int.self, forKey: .events),
                  began: try c.decode(Int.self, forKey: .began),
                  moved: try c.decode(Int.self, forKey: .moved),
                  ended: try c.decode(Int.self, forKey: .ended),
                  cancelled: try c.decode(Int.self, forKey: .cancelled),
                  unmatched: try c.decode(Int.self, forKey: .unmatched),
                  active: try c.decode(Int.self, forKey: .active),
                  maxActive: try c.decode(Int.self, forKey: .maxActive),
                  gestures: try c.decode(Int.self, forKey: .gestures),
                  log: try c.decode(LogStatus.self, forKey: .log))
    }
}
