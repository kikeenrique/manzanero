import Foundation
import ImageIO

/// `frames`: save a run of a physical device's live screen as numbered JPEG
/// files and a JSON index, from one native video session. Its use is fast
/// repeated screenshots: the stream is negotiated once, so each further frame
/// costs no new `devicectl` process. See docs/recording.md.
struct FramesCommand: Sendable, Equatable {
    static let countRange = 1...1000
    static let secondsRange = 0.5...300.0
    static let intervalRange = 0...60_000
    /// Frames saved when neither --count nor --seconds is given.
    static let defaultCount = 10
    /// With --seconds alone, the run still stops at the largest count.
    static var maximumCount: Int { countRange.upperBound }
    /// Saved frames are at least this far apart: at most 30 per second.
    static let minimumSpacingMilliseconds = 33
    /// Total JPEG bytes one run may write.
    static let byteLimit = 1024 * 1024 * 1024
    /// One encoded frame may not exceed this.
    static let frameByteLimit = 8 * 1024 * 1024
    /// The stream must deliver its first frame within this many seconds.
    static let firstFrameBudgetSeconds = 12
    static let indexName = "frames.json"
    static let usageText = "Usage: frames <directory> [--count 1...1000] [--seconds 0.5...300] [--interval 0...60000] [--overwrite] --device <UDID>"

    let device: String
    let directory: URL
    /// Stop after this many saved frames.
    let count: Int
    /// Stop this long after the first frame; nil for no time limit.
    let seconds: Double?
    /// One frame is saved per this many milliseconds from the first (0: every
    /// delivered frame); `minimumSpacingMilliseconds` always applies.
    let intervalMilliseconds: Int
    /// Allow a non-empty directory; same-named frames and the index are replaced.
    let overwrite: Bool

    init(device: String, directory: String, count: String?, seconds: String?, interval: String?, overwrite: Bool) throws {
        guard !device.isEmpty, !device.hasPrefix("-"), !directory.isEmpty, !directory.hasPrefix("-") else {
            throw CommandFailure.usage(Self.usageText)
        }
        var limit = seconds == nil ? Self.defaultCount : Self.maximumCount
        if let count {
            guard let value = Int(count), Self.countRange.contains(value) else {
                throw CommandFailure.usage("--count must be an integer in 1...1000.")
            }
            limit = value
        }
        var duration: Double?
        if let seconds {
            guard let value = Double(seconds), value.isFinite, Self.secondsRange.contains(value) else {
                throw CommandFailure.usage("--seconds must be a number in 0.5...300.")
            }
            duration = value
        }
        var spacing = 0
        if let interval {
            guard let value = Int(interval), Self.intervalRange.contains(value) else {
                throw CommandFailure.usage("--interval must be whole milliseconds in 0...60000.")
            }
            spacing = value
        }
        self.init(device: device, directory: URL(fileURLWithPath: directory), count: limit, seconds: duration,
                  intervalMilliseconds: spacing, overwrite: overwrite)
    }

    init(device: String, directory: URL, count: Int, seconds: Double?, intervalMilliseconds: Int, overwrite: Bool) {
        self.device = device; self.directory = directory; self.count = count; self.seconds = seconds
        self.intervalMilliseconds = intervalMilliseconds; self.overwrite = overwrite
    }

    /// The display's bounds (pixels, the size `screenshot` saves) when the
    /// negotiated stream holds them: the stream pads the screen on the right
    /// and bottom. A display larger than the stream keeps the whole picture.
    static func visibleSize(display: DirectTouchDisplay, stream: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let width = Int(display.width.rounded()), height = Int(display.height.rounded())
        // An Apple TV's 3840 x 2160 display comes scaled into the stream's
        // width: 3168 x 1782 of a 3168 x 1792 frame, the rest black rows.
        if display.external, width > stream.width, height > 0 {
            let fitted = Int((Double(stream.width) * display.height / display.width).rounded())
            return (1...stream.height).contains(fitted) ? (stream.width, fitted) : stream
        }
        guard (1...stream.width).contains(width), (1...stream.height).contains(height) else { return stream }
        return (width, height)
    }

    /// `frame-0001.jpg` for the first frame.
    static func fileName(_ number: Int) -> String { String(format: "frame-%04d.jpg", number) }

    /// The `--dry-run` plan; it reads nothing and contacts no device.
    func plan() -> [String: Any] {
        ["backend": "coredevice-videotoolbox", "operation": "frames", "device": device, "directory": directory.path,
         "count": count, "seconds": seconds.map { $0 as Any } ?? NSNull(), "intervalMilliseconds": intervalMilliseconds,
         "minimumSpacingMilliseconds": Self.minimumSpacingMilliseconds, "overwrite": overwrite,
         "files": Self.fileName(1) + "…, " + Self.indexName,
         "limits": ["frames": Self.maximumCount, "seconds": Self.secondsRange.upperBound, "totalBytes": Self.byteLimit,
                    "frameBytes": Self.frameByteLimit, "firstFrameSeconds": Self.firstFrameBudgetSeconds] as [String: Any],
         "execution": "In process: Apple tunnel assertion and device lease, one owned AVConference screen-sharing stream in standard-RTP mode, HEVC decoded with VideoToolbox, each saved frame encoded as JPEG (quality 0.85); owned stream stop, fresh absence check and tunnel release. Sends no input; no devicectl per frame."]
    }

    /// Creates the directory, or checks that an existing one may be written.
    /// The parent must exist, as for a recording destination.
    func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CommandFailure.usage("\(directory.path) exists and is not a directory.") }
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard overwrite || contents.isEmpty else {
                throw CommandFailure.usage("\(directory.path) is not empty; choose a new or empty directory, or pass --overwrite to replace same-named frames and \(Self.indexName).")
            }
            return
        }
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandFailure.usage("The frames directory's parent must exist: \(parent.path).")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }
}

/// The saved frames of one run, their timing and the stop rules. Times are
/// host nanoseconds from any monotonic origin; offsets count from the first frame.
struct FrameRun: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let file: String
        let offsetMilliseconds: Double
        let width: Int
        let height: Int
        let bytes: Int
    }

    enum StopReason: String, Sendable {
        case count, duration
        case byteLimit = "byte-limit"
        case interrupted
        /// Pictures stopped and no restart was left (docs/recording-recovery.md).
        case streamStalled = "stream-stalled"
    }

    let command: FramesCommand
    let started: UInt64
    /// Total JPEG bytes this run may write.
    let byteLimit: Int
    private(set) var entries: [Entry] = []
    private(set) var totalBytes = 0
    private(set) var first: UInt64?
    private var lastSaved: UInt64?

    init(command: FramesCommand, started: UInt64, byteLimit: Int = FramesCommand.byteLimit) {
        self.command = command
        self.started = started
        self.byteLimit = byteLimit
    }

    /// Whether a frame delivered now should be saved: the first one always;
    /// then frame k is due k intervals after the first (a grid, so late
    /// deliveries do not push later frames back), and never sooner than the
    /// minimum spacing after the previous one.
    func wants(at now: UInt64) -> Bool {
        guard let first, let lastSaved else { return true }
        let interval = UInt64(command.intervalMilliseconds) * 1_000_000
        let due = max(lastSaved + UInt64(FramesCommand.minimumSpacingMilliseconds) * 1_000_000, first + UInt64(entries.count) * interval)
        return now >= due
    }

    /// Why the run is complete before the next frame, if it is.
    func stopReason(at now: UInt64) -> StopReason? {
        if entries.count >= command.count { return .count }
        if let seconds = command.seconds, let first, now >= first, now - first >= UInt64(seconds * 1_000_000_000) { return .duration }
        return nil
    }

    /// Writes one frame. Returns `.byteLimit` instead, writing nothing, when
    /// it would take the run past its byte budget.
    mutating func save(_ jpeg: Data, at now: UInt64) throws -> StopReason? {
        guard !jpeg.isEmpty, jpeg.count <= FramesCommand.frameByteLimit else {
            throw CommandFailure(.transportFailed, "A decoded frame encoded to \(jpeg.count) bytes, outside 1...\(FramesCommand.frameByteLimit).", inputSent: .none)
        }
        guard totalBytes + jpeg.count <= byteLimit else { return .byteLimit }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw CommandFailure(.transportFailed, "A decoded frame is not a readable JPEG.", inputSent: .none)
        }
        let name = FramesCommand.fileName(entries.count + 1)
        try jpeg.write(to: command.directory.appendingPathComponent(name))
        if first == nil { first = now }
        let offset = Double(now - (first ?? now)) / 1_000_000
        entries.append(Entry(file: name, offsetMilliseconds: (offset * 10).rounded() / 10, width: width, height: height, bytes: jpeg.count))
        totalBytes += jpeg.count
        lastSaved = now
        return nil
    }

    var firstFrameDelayMilliseconds: Double? {
        first.map { (Double($0 - started) / 100_000).rounded() / 10 }
    }

    /// Mean milliseconds between consecutive saved frames.
    var meanSpacingMilliseconds: Double? {
        guard entries.count > 1, let last = entries.last else { return nil }
        return (last.offsetMilliseconds / Double(entries.count - 1) * 10).rounded() / 10
    }

    /// The index file's content and the receipt's common fields.
    func summary(status: String, stopReason: StopReason?, recovery: RecordingRecovery? = nil) -> [String: Any] {
        var value: [String: Any] = ["status": status, "directory": command.directory.path, "index": command.directory.appendingPathComponent(FramesCommand.indexName).path,
            "frameCount": entries.count, "totalBytes": totalBytes, "stopReason": stopReason?.rawValue ?? NSNull(),
            "requested": ["count": command.count, "seconds": command.seconds.map { $0 as Any } ?? NSNull(),
                          "intervalMilliseconds": command.intervalMilliseconds] as [String: Any],
            "frames": entries.map { ["file": $0.file, "offsetMilliseconds": Self.decimal($0.offsetMilliseconds), "width": $0.width, "height": $0.height, "bytes": $0.bytes] as [String: Any] }]
        if let delay = firstFrameDelayMilliseconds { value["firstFrameDelayMilliseconds"] = Self.decimal(delay) }
        if let spacing = meanSpacingMilliseconds { value["meanSpacingMilliseconds"] = Self.decimal(spacing) }
        if let last = entries.last { value["lastFrame"] = command.directory.appendingPathComponent(last.file).path }
        // Restarts and gaps: a gap shows in the frames' offsets as a jump.
        if let recovery { value["recovery"] = recovery.json }
        return value
    }

    /// Milliseconds with one decimal, printed as written (no binary noise).
    static func decimal(_ milliseconds: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", milliseconds))
    }

    /// Writes `frames.json`; best effort when the run is being abandoned.
    func writeIndex(status: String, stopReason: StopReason?, recovery: RecordingRecovery? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: summary(status: status, stopReason: stopReason, recovery: recovery), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: command.directory.appendingPathComponent(FramesCommand.indexName))
    }
}
