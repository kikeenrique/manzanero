import Foundation

/// A finite schedule of complete contact states. An omitted contact is released
/// at its last position; IDs can be reused after release for repeated taps.
struct NativeGestureSequence {
    private struct Sequence: Decodable {
        let frames: [Frame]
    }
    private struct Frame: Decodable {
        let ms: Int
        let touches: [Touch]
    }
    private struct Touch: Decodable {
        let id: Int
        let x: Double
        let y: Double
    }
    let times: [Int]
    let reports: [[UInt8]]
    let contactCount: Int

    init(json: String) throws {
        guard (1...65536).contains(json.utf8.count) else {
            throw CommandFailure(description: "Gesture JSON must contain 1...65536 UTF-8 bytes.")
        }
        let frames: [Frame]
        do { frames = try JSONDecoder().decode(Sequence.self, from: Data(json.utf8)).frames }
        catch { throw CommandFailure(description: "Invalid gesture JSON; expected {frames:[{ms:integer,touches:[{id:integer,x:number,y:number}]}]}. \(error)") }
        guard (2...512).contains(frames.count), frames.first?.ms == 0,
              frames.first?.touches.isEmpty == false, frames.last?.touches.isEmpty == true else {
            throw CommandFailure(description: "Gesture requires 2...512 frames, starting at ms=0 with a touch and ending with touches:[].")
        }
        var previous = -1
        var identities: Set<Int> = []
        for frame in frames {
            guard frame.ms > previous, (0...10000).contains(frame.ms), frame.touches.count <= 5,
                  Set(frame.touches.map(\.id)).count == frame.touches.count else {
                throw CommandFailure(description: "Gesture frame times must strictly increase within 0...10000 ms; at most five distinct contacts per frame.")
            }
            previous = frame.ms
            for touch in frame.touches {
                guard (0...4).contains(touch.id), touch.x.isFinite, touch.y.isFinite,
                      (0...1).contains(touch.x), (0...1).contains(touch.y) else {
                    throw CommandFailure(description: "Gesture IDs must be 0...4 and x/y finite normalized coordinates in 0...1.")
                }
                identities.insert(touch.id)
            }
        }
        guard identities == Set(0..<identities.count) else {
            throw CommandFailure(description: "Gesture contact IDs must form a contiguous set starting at zero across the sequence.")
        }
        contactCount = identities.count
        times = frames.map(\.ms)
        var positions = Array(repeating: [0, 0], count: contactCount)
        reports = frames.map { frame in
            for touch in frame.touches {
                positions[touch.id] = [touch.x, touch.y].map { Int(($0 * 65535).rounded()) }
            }
            return NativeTouchFrames.report(positions: positions, active: Set(frame.touches.map(\.id)))
        }
    }

    var arguments: [String] {
        zip(times, reports).flatMap { time, report in
            [String(time), report.map { String(format: "%02x", $0) }.joined()]
        }
    }
}
