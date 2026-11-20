import Foundation
import Synchronization

/// `simulator <UUID> logs`: a finite capture of the simulator's unified log
/// through Apple's own `log` tool run inside the simulator
/// (`simctl spawn <UUID> log stream|show --style ndjson`). The tool builds the
/// predicate itself from validated fields; there is no raw predicate option.
struct LogCapture: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        /// `log stream` from now for this many seconds.
        case stream(seconds: Int)
        /// `log show --last <n>s`.
        case last(seconds: Int)
        /// `log show --start [--end]`.
        case range(start: Date, end: Date?)
    }

    enum Target: Sendable, Equatable {
        case pid(Int32)
        /// Resolved to the installed `.app` path, matched with `processImagePath BEGINSWITH`.
        case bundle(String)
        case process(String)
    }

    enum Level: String, Sendable, CaseIterable { case `default`, info, debug }

    static let secondsRange = 1...60
    static let lastRange = 1...3600
    static let defaultMaxEntries = 2000
    static let maxEntriesCeiling = 10000
    static let defaultMaxBytes = 1024 * 1024
    static let maxBytesCeiling = 8 * 1024 * 1024
    /// With `--output`, the entries returned inline are the newest this many.
    static let inlineEntriesWithOutput = 50
    /// `log stream --timeout` is the soft stop; the child must be gone this
    /// many seconds after it.
    static let streamGraceSeconds = 5
    static let showDeadlineSeconds = 60.0
    /// Raw stdout bytes read before the capture stops, whatever is kept.
    static let receivedBytesCeiling = 64 * 1024 * 1024

    let device: String
    let mode: Mode
    let target: Target
    let subsystem: String?
    let category: String?
    let level: Level
    let maxEntries: Int
    let maxBytes: Int
    let output: String?
    /// A physical device, read through its log relay (`PhysicalLogCapture`):
    /// a stream from now only.
    let physical: Bool

    init(device: String, mode: Mode, target: Target, subsystem: String? = nil, category: String? = nil, level: Level = .default,
         maxEntries: Int = defaultMaxEntries, maxBytes: Int = defaultMaxBytes, output: String? = nil, physical: Bool = false) {
        self.device = device; self.mode = mode; self.target = target; self.subsystem = subsystem; self.category = category
        self.level = level; self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.output = output; self.physical = physical
    }

    init(device: String, options: DiagnosticOptions, physical: Bool = false) throws {
        guard options.positional.isEmpty else { throw CommandFailure.usage("logs takes options only; see --help.") }
        let modes = ["--seconds", "--last", "--start"].filter { options.values[$0] != nil }
        guard modes.count == 1 else {
            throw CommandFailure.usage("logs needs exactly one of --seconds (stream from now), --last (seconds back) or --start [--end].")
        }
        if physical, modes != ["--seconds"] {
            throw CommandFailure.usage("On a physical device logs streams from now only: use --seconds. A device's stored log is not read.")
        }
        let mode: Mode
        if let seconds = try options.integer("--seconds", in: Self.secondsRange) {
            mode = .stream(seconds: seconds)
        } else if let seconds = try options.integer("--last", in: Self.lastRange) {
            mode = .last(seconds: seconds)
        } else {
            let start = try options.date("--start")!
            let end = try options.date("--end")
            if let end, end <= start { throw CommandFailure.usage("--end must be after --start.") }
            mode = .range(start: start, end: end)
        }
        if options.values["--end"] != nil, options.values["--start"] == nil {
            throw CommandFailure.usage("--end needs --start.")
        }
        let targets = ["--pid", "--bundle", "--process"].filter { options.values[$0] != nil }
        guard targets.count == 1 else {
            throw CommandFailure.usage("logs needs exactly one of --pid, --bundle or --process; captures are always limited to one app.")
        }
        let target: Target
        if let pid = try options.integer("--pid", in: 1...Int(Int32.max)) {
            target = .pid(Int32(pid))
        } else if let bundle = options.values["--bundle"] {
            target = .bundle(try DiagnosticNames.bundleIdentifier(bundle))
        } else {
            target = .process(try DiagnosticNames.processName(options.values["--process"]!))
        }
        let subsystem = try options.values["--subsystem"].map(DiagnosticNames.subsystem)
        let category = try options.values["--category"].map(DiagnosticNames.category)
        if category != nil, subsystem == nil { throw CommandFailure.usage("--category needs --subsystem.") }
        var level = Level.default
        if let text = options.values["--level"] {
            guard let value = Level(rawValue: text) else { throw CommandFailure.usage("--level must be default, info or debug.") }
            level = value
        }
        var output: String?
        if let path = options.values["--output"] {
            guard !path.hasPrefix("-") else { throw CommandFailure.usage("--output needs a host file path.") }
            output = path
        }
        self.init(device: device, mode: mode, target: target, subsystem: subsystem, category: category, level: level,
                  maxEntries: try options.integer("--max-entries", in: 1...Self.maxEntriesCeiling) ?? Self.defaultMaxEntries,
                  maxBytes: try options.integer("--max-bytes", in: 1024...Self.maxBytesCeiling) ?? Self.defaultMaxBytes,
                  output: output, physical: physical)
    }

    var isStream: Bool { if case .stream = mode { true } else { false } }

    var hardDeadlineSeconds: Double {
        if case .stream(let seconds) = mode { return Double(seconds + Self.streamGraceSeconds) }
        return Self.showDeadlineSeconds
    }

    var source: String { physical ? "os-trace-relay" : isStream ? "simctl-log-stream" : "simctl-log-show" }

    /// The query that resolves `--bundle` to its installed `.app` (read-only).
    var appPathQuery: [String]? {
        guard case .bundle(let bundle) = target else { return nil }
        return ["simctl", "get_app_container", device, bundle, "app"]
    }

    /// An NSPredicate string literal. Inputs are validated first; escaping is
    /// the second line of defence.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `appPath` is the resolved `.app` directory for `--bundle`.
    func predicate(appPath: String?) -> String {
        var clauses: [String]
        switch target {
        case .pid(let pid): clauses = ["processID == \(pid)"]
        case .process(let name): clauses = ["process == \(Self.quote(name))"]
        case .bundle: clauses = ["processImagePath BEGINSWITH \(Self.quote(Self.directoryPrefix(appPath ?? "<installed app path>")))"]
        }
        if let subsystem { clauses.append("subsystem == \(Self.quote(subsystem))") }
        if let category { clauses.append("category == \(Self.quote(category))") }
        return clauses.joined(separator: " AND ")
    }

    static func directoryPrefix(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    func arguments(predicate: String) -> [String] {
        let base = ["simctl", "spawn", device, "log"]
        switch mode {
        case .stream(let seconds):
            return base + ["stream", "--style", "ndjson", "--level", level.rawValue, "--timeout", "\(seconds)", "--predicate", predicate]
        case .last(let seconds):
            return base + ["show", "--style", "ndjson"] + showLevel + ["--last", "\(seconds)s", "--predicate", predicate]
        case .range(let start, let end):
            return base + ["show", "--style", "ndjson"] + showLevel + ["--start", DiagnosticTime.logArgument(start)]
                + (end.map { ["--end", DiagnosticTime.logArgument($0)] } ?? []) + ["--predicate", predicate]
        }
    }

    private var showLevel: [String] {
        switch level {
        case .default: []
        case .info: ["--info"]
        case .debug: ["--info", "--debug"]
        }
    }

    func plan() -> [String: Any] {
        if physical { return PhysicalLogCapture.plan(self) }
        var plan: [String: Any] = [
            "backend": "simctl", "operation": "logs", "platform": "simulator", "device": device, "readOnly": true,
            "executable": "/usr/bin/xcrun", "arguments": arguments(predicate: predicate(appPath: nil)),
            "predicate": predicate(appPath: nil), "level": level.rawValue, "source": source,
            "bounds": ["maxEntries": maxEntries, "maxBytes": maxBytes, "hardDeadlineSeconds": hardDeadlineSeconds,
                       "receivedBytesCeiling": Self.receivedBytesCeiling],
            "execution": "Requires a booted simulator. Runs Apple's log tool inside the simulator; stops at the duration, the entry limit or the byte limit and reaps the child. No raw predicate; entries from other processes are dropped on the host as well.",
        ]
        if let query = appPathQuery {
            plan["targetResolution"] = ["query": ["executable": "/usr/bin/xcrun", "arguments": query],
                                        "placeholder": "<installed app path>", "match": "processImagePath BEGINSWITH the .app directory"]
        }
        if let output { plan["output"] = output; plan["inlineEntries"] = Self.inlineEntriesWithOutput }
        return plan
    }
}

/// Line-based reader for `log … --style ndjson`: skips the non-JSON banner,
/// notes the final `{"count":N,"finished":1}` record, normalises entries and
/// enforces the entry and byte limits. An entry that would cross a limit is
/// not kept, and the capture stops there.
struct UnifiedLogReader: Sendable {
    enum StopReason: String, Sendable { case duration, complete, entryLimit, byteLimit }

    struct Filter: Sendable {
        var pid: Int32?
        var process: String?
        var imagePrefix: String?
        var subsystem: String?
        var category: String?

        func accepts(_ object: [String: Any]) -> Bool {
            if let pid, (object["processID"] as? NSNumber)?.int32Value != pid { return false }
            let image = object["processImagePath"] as? String ?? ""
            if let process, URL(fileURLWithPath: image).lastPathComponent != process { return false }
            if let imagePrefix, !image.hasPrefix(imagePrefix) { return false }
            if let subsystem, object["subsystem"] as? String != subsystem { return false }
            if let category, object["category"] as? String != category { return false }
            return true
        }
    }

    let maxEntries: Int
    let maxBytes: Int
    let filter: Filter
    var receivedBytesCeiling = LogCapture.receivedBytesCeiling
    /// A line longer than this without a newline stops the capture.
    var maximumLineBytes = LogCapture.maxBytesCeiling + 64 * 1024

    private(set) var entries: [Data] = []
    private(set) var entryBytes = 0
    private(set) var receivedBytes = 0
    private(set) var filteredOut = 0
    private(set) var skippedLines = 0
    private(set) var finished = false
    private(set) var reportedCount: Int?
    private(set) var stopReason: StopReason?
    private var pending = Data()

    init(maxEntries: Int, maxBytes: Int, filter: Filter) {
        self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.filter = filter
    }

    var truncated: Bool { stopReason == .entryLimit || stopReason == .byteLimit }

    /// Returns false once a limit stops the capture.
    mutating func feed(_ data: Data) -> Bool {
        guard stopReason == nil else { return false }
        receivedBytes += data.count
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex..<newline]
            let keep = consume(Data(line))
            pending = Data(pending[(newline + 1)...])
            guard keep else { return false }
        }
        if pending.count > maximumLineBytes || receivedBytes > receivedBytesCeiling {
            stopReason = .byteLimit
            return false
        }
        return true
    }

    /// Processes a final line without a trailing newline.
    mutating func finish() {
        guard stopReason == nil, !pending.isEmpty else { return }
        let line = pending
        pending = Data()
        _ = consume(line)
    }

    private mutating func consume(_ line: Data) -> Bool {
        let trimmed = line.drop { $0 == 32 || $0 == 9 || $0 == 13 }
        guard let first = trimmed.first else { return true }
        guard first == UInt8(ascii: "{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(trimmed))) as? [String: Any] else {
            skippedLines += 1
            return true
        }
        if object["finished"] != nil {
            finished = true
            reportedCount = (object["count"] as? NSNumber)?.intValue
            return true
        }
        guard object["eventType"] as? String == "logEvent", filter.accepts(object) else {
            filteredOut += 1
            return true
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: Self.normalise(object), options: [.sortedKeys, .withoutEscapingSlashes]) else {
            skippedLines += 1
            return true
        }
        if entries.count + 1 > maxEntries { stopReason = .entryLimit; return false }
        if entryBytes + encoded.count + 1 > maxBytes { stopReason = .byteLimit; return false }
        entries.append(encoded)
        entryBytes += encoded.count + 1
        return true
    }

    static func normalise(_ object: [String: Any]) -> [String: Any] {
        func name(_ key: String) -> String {
            URL(fileURLWithPath: object[key] as? String ?? "").lastPathComponent
        }
        let level: String = switch (object["messageType"] as? String ?? "").lowercased() {
        case "default", "": "default"
        case let other: other
        }
        return [
            "timestamp": DiagnosticTime.normalise(object["timestamp"] as? String ?? ""),
            "level": level,
            "pid": (object["processID"] as? NSNumber)?.intValue ?? 0,
            "process": name("processImagePath"),
            "subsystem": object["subsystem"] as? String ?? "",
            "category": object["category"] as? String ?? "",
            "sender": name("senderImagePath"),
            "message": object["eventMessage"] as? String ?? "",
        ]
    }
}

enum UnifiedLogExecution {
    /// The simulator's `log` always reports that the host user is unknown
    /// inside the simulator; that line is not a failure signal.
    static func diagnostics(_ stderr: Data) -> String {
        String(decoding: stderr, as: UTF8.self).split(separator: "\n")
            .filter { !$0.contains("getpwuid_r did not find a match") }
            .joined(separator: "\n")
    }

    static func execute(_ capture: LogCapture, environment: SimulatorEnvironment,
                        run: @Sendable ([String]) throws -> Data,
                        runner: StreamingToolRunner = StreamingToolRunner(),
                        launch: @Sendable ([String]) -> (executable: String, arguments: [String]) = { ("/usr/bin/xcrun", $0) }) async throws -> Data {
        _ = try SimulatorDevice.requireBooted(capture.device, operation: "logs", lookup: environment.lookup)
        if let output = capture.output, FileManager.default.fileExists(atPath: output) {
            throw CommandFailure.usage("--output refuses an existing file: \(output).")
        }
        var appPath: String?
        if let query = capture.appPathQuery {
            let data: Data
            do { data = try run(query) } catch {
                throw CommandFailure(.targetUnresolved, "The bundle is not installed on this simulator (simctl get_app_container failed); nothing was captured.", inputSent: .none)
            }
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\"") else {
                throw CommandFailure(.toolFailed, "simctl returned an unusable app path for the bundle.", inputSent: .none)
            }
            appPath = path
        }
        let predicate = capture.predicate(appPath: appPath)
        var filter = UnifiedLogReader.Filter(subsystem: capture.subsystem, category: capture.category)
        switch capture.target {
        case .pid(let pid): filter.pid = pid
        case .process(let name): filter.process = name
        case .bundle: filter.imagePrefix = appPath.map(LogCapture.directoryPrefix)
        }
        let state = Mutex(UnifiedLogReader(maxEntries: capture.maxEntries, maxBytes: capture.maxBytes, filter: filter))
        let errors = Mutex(Data())
        let command = launch(capture.arguments(predicate: predicate))
        let end = try await runner.capture(executable: command.executable, arguments: command.arguments,
                                           hardDeadline: capture.hardDeadlineSeconds) { stream, data in
            switch stream {
            case .output:
                return state.withLock { $0.feed(data) }
            case .error:
                errors.withLock { if $0.count < 65536 { $0.append(data.prefix(65536 - $0.count)) } }
                return true
            }
        }
        var reader = state.withLock { $0 }
        let stopReason: UnifiedLogReader.StopReason
        switch end {
        case .consumerStopped:
            stopReason = reader.stopReason ?? .byteLimit
        case .exited(let status) where status.isSuccess:
            reader.finish()
            if let reason = reader.stopReason {
                stopReason = reason
            } else {
                guard reader.finished else {
                    throw CommandFailure(.toolFailed, "log ended without its final record; the capture may be incomplete and is not reported as complete.", inputSent: .none)
                }
                stopReason = capture.isStream ? .duration : .complete
            }
        case .exited(let status), .softDeadline(let status):
            throw CommandFailure(.toolFailed, "log failed (\(status)): \(diagnostics(errors.withLock { $0 }))", inputSent: .none)
        }
        var inline = reader.entries
        if let output = capture.output {
            var file = Data()
            for entry in reader.entries { file.append(entry); file.append(10) }
            do {
                guard FileManager.default.createFile(atPath: output, contents: file, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } catch {
                throw CommandFailure(.hostRequirement, "Cannot write --output \(output); the parent directory must exist.", inputSent: .none)
            }
            inline = Array(inline.suffix(LogCapture.inlineEntriesWithOutput))
        }
        var result: [String: Any] = [
            "platform": "simulator", "device": capture.device, "operation": "logs", "source": capture.source,
            "entries": try inline.map { try JSONSerialization.jsonObject(with: $0) },
            "entryCount": reader.entries.count, "entryBytes": reader.entryBytes, "receivedBytes": reader.receivedBytes,
            "filteredOut": reader.filteredOut, "stopReason": stopReason.rawValue, "truncated": reader.truncated,
            "level": capture.level.rawValue, "predicate": predicate,
        ]
        if let count = reader.reportedCount { result["toolReportedCount"] = count }
        if let output = capture.output { result["output"] = output; result["inlineEntryCount"] = inline.count }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
