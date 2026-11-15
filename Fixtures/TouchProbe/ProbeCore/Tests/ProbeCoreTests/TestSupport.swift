import Testing
@testable import ProbeCore

extension TouchRecorder {
    /// Record a callback that must produce an event. `#require` cannot wrap a mutating call directly.
    mutating func expectRecord(key: Key, phase: TouchPhase, point: ProbePoint, timestamp: Double,
                               kind: String = "direct", radius: Double = 0,
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> TouchEventRecord {
        let record = record(key: key, phase: phase, point: point, timestamp: timestamp, kind: kind, radius: radius)
        return try #require(record, sourceLocation: sourceLocation)
    }
}
