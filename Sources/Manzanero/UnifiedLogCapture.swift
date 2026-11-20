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
    /// A device's stream may run longer: it is read off the command queue.
    static let physicalSecondsRange = 1...600
    /// At most this many `--bundle`/`--process` targets, and this many values
    /// of each repeatable filter.
    static let maximumRepeats = 16
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
    /// One `--pid`, or `--bundle` and `--process` values (a group); empty
    /// for every process (`--all`).
    let targets: [Target]
    /// An entry is kept when its subsystem is one of these (any, if empty),
    /// its category one of `categories` (any, if empty) and its message
    /// contains `match`.
    let subsystems: [String]
    let categories: [String]
    let match: String?
    let level: Level
    let maxEntries: Int
    let maxBytes: Int
    let output: String?
    /// A physical device, read through its log relay (`PhysicalLogCapture`):
    /// a stream from now only.
    let physical: Bool

    init(device: String, mode: Mode, targets: [Target], subsystems: [String] = [], categories: [String] = [], match: String? = nil,
         level: Level = .default, maxEntries: Int = defaultMaxEntries, maxBytes: Int = defaultMaxBytes, output: String? = nil,
         physical: Bool = false) {
        self.device = device; self.mode = mode; self.targets = targets; self.subsystems = subsystems; self.categories = categories
        self.match = match; self.level = level; self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.output = output
        self.physical = physical
    }

    /// Every process.
    var all: Bool { targets.isEmpty }

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
        if let seconds = try options.integer("--seconds", in: physical ? Self.physicalSecondsRange : Self.secondsRange) {
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
        let bundles = options.list("--bundle"), processes = options.list("--process")
        let kinds = [options.values["--pid"] != nil, !bundles.isEmpty || !processes.isEmpty, options.flags.contains("--all")]
        guard kinds.filter({ $0 }).count == 1 else {
            throw CommandFailure.usage("logs needs exactly one of --pid, --bundle and --process (each repeatable, together a group) or --all.")
        }
        func repeats(_ values: [String], _ name: String) throws -> [String] {
            guard values.count <= Self.maximumRepeats else { throw CommandFailure.usage("\(name) may be given at most \(Self.maximumRepeats) times.") }
            return Array(NSOrderedSet(array: values)) as? [String] ?? values
        }
        var targets: [Target] = []
        if let pid = try options.integer("--pid", in: 1...Int(Int32.max)) {
            targets = [.pid(Int32(pid))]
        } else {
            targets = try repeats(bundles, "--bundle").map { .bundle(try DiagnosticNames.bundleIdentifier($0)) }
                + repeats(processes, "--process").map { .process(try DiagnosticNames.processName($0)) }
        }
        let subsystems = try repeats(options.list("--subsystem"), "--subsystem").map(DiagnosticNames.subsystem)
        let categories = try repeats(options.list("--category"), "--category").map(DiagnosticNames.category)
        if !categories.isEmpty, subsystems.isEmpty { throw CommandFailure.usage("--category needs --subsystem.") }
        let match = try options.values["--match"].map(DiagnosticNames.match)
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
        self.init(device: device, mode: mode, targets: targets, subsystems: subsystems, categories: categories, match: match, level: level,
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

    var bundles: [String] { targets.compactMap { if case .bundle(let bundle) = $0 { bundle } else { nil } } }
    var processes: [String] { targets.compactMap { if case .process(let name) = $0 { name } else { nil } } }

    /// The query that resolves one `--bundle` to its installed `.app` (read-only).
    func appPathQuery(_ bundle: String) -> [String] {
        ["simctl", "get_app_container", device, bundle, "app"]
    }

    /// An NSPredicate string literal. Inputs are validated first; escaping is
    /// the second line of defence.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `appPaths` are the resolved `.app` directories, by bundle. Empty for
    /// `--all` with no filter.
    func predicate(appPaths: [String: String]) -> String {
        func any(_ clauses: [String]) -> [String] {
            clauses.count > 1 ? ["(" + clauses.joined(separator: " OR ") + ")"] : clauses
        }
        let who = any(targets.map { target -> String in
            switch target {
            case .pid(let pid): return "processID == \(pid)"
            case .process(let name): return "process == \(Self.quote(name))"
            case .bundle(let bundle):
                return "processImagePath BEGINSWITH \(Self.quote(Self.directoryPrefix(appPaths[bundle] ?? "<installed app path of \(bundle)>")))"
            }
        })
        let what = any(subsystems.map { "subsystem == \(Self.quote($0))" }) + any(categories.map { "category == \(Self.quote($0))" })
            + (match.map { ["eventMessage CONTAINS \(Self.quote($0))"] } ?? [])
        return (who + what).joined(separator: " AND ")
    }

    static func directoryPrefix(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    func arguments(predicate: String) -> [String] {
        let base = ["simctl", "spawn", device, "log"]
        let filter = predicate.isEmpty ? [] : ["--predicate", predicate]
        switch mode {
        case .stream(let seconds):
            return base + ["stream", "--style", "ndjson", "--level", level.rawValue, "--timeout", "\(seconds)"] + filter
        case .last(let seconds):
            return base + ["show", "--style", "ndjson"] + showLevel + ["--last", "\(seconds)s"] + filter
        case .range(let start, let end):
            return base + ["show", "--style", "ndjson"] + showLevel + ["--start", DiagnosticTime.logArgument(start)]
                + (end.map { ["--end", DiagnosticTime.logArgument($0)] } ?? []) + filter
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
            "executable": "/usr/bin/xcrun", "arguments": arguments(predicate: predicate(appPaths: [:])),
            "predicate": predicate(appPaths: [:]), "level": level.rawValue, "source": source, "all": all,
            "bounds": ["maxEntries": maxEntries, "maxBytes": maxBytes, "hardDeadlineSeconds": hardDeadlineSeconds,
                       "receivedBytesCeiling": Self.receivedBytesCeiling],
            "execution": "Requires a booted simulator. Runs Apple's log tool inside the simulator; stops at the duration, the entry limit or the byte limit and reaps the child. No raw predicate; entries the predicate does not select are dropped on the host as well.",
        ]
        if !bundles.isEmpty {
            plan["targetResolution"] = bundles.map { bundle in
                ["query": ["executable": "/usr/bin/xcrun", "arguments": appPathQuery(bundle)],
                 "placeholder": "<installed app path of \(bundle)>", "match": "processImagePath BEGINSWITH the .app directory"] as [String: Any]
            }
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

    /// The predicate again, on the host. An entry is from a selected process
    /// when it matches any of the PIDs, names or image prefixes, or when
    /// none is given (every process).
    struct Filter: Sendable {
        var pids: Set<Int32> = []
        var processes: Set<String> = []
        var imagePrefixes: [String] = []
        var subsystems: Set<String> = []
        var categories: Set<String> = []
        var match: String?

        func accepts(_ object: [String: Any]) -> Bool {
            let image = object["processImagePath"] as? String ?? ""
            if !(pids.isEmpty && processes.isEmpty && imagePrefixes.isEmpty) {
                let pid = (object["processID"] as? NSNumber)?.int32Value
                guard pid.map(pids.contains) == true || processes.contains(URL(fileURLWithPath: image).lastPathComponent)
                        || imagePrefixes.contains(where: image.hasPrefix) else { return false }
            }
            if !subsystems.isEmpty, !subsystems.contains(object["subsystem"] as? String ?? "") { return false }
            if !categories.isEmpty, !categories.contains(object["category"] as? String ?? "") { return false }
            if let match, !(object["eventMessage"] as? String ?? "").contains(match) { return false }
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
        var appPaths: [String: String] = [:]
        for bundle in capture.bundles {
            let data: Data
            do { data = try run(capture.appPathQuery(bundle)) } catch {
                throw CommandFailure(.targetUnresolved, "\(bundle) is not installed on this simulator (simctl get_app_container failed); nothing was captured.", inputSent: .none)
            }
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\"") else {
                throw CommandFailure(.toolFailed, "simctl returned an unusable app path for \(bundle).", inputSent: .none)
            }
            appPaths[bundle] = path
        }
        let predicate = capture.predicate(appPaths: appPaths)
        var filter = UnifiedLogReader.Filter(subsystems: Set(capture.subsystems), categories: Set(capture.categories), match: capture.match)
        for target in capture.targets {
            switch target {
            case .pid(let pid): filter.pids.insert(pid)
            case .process(let name): filter.processes.insert(name)
            case .bundle(let bundle): filter.imagePrefixes.append(LogCapture.directoryPrefix(appPaths[bundle] ?? "/"))
            }
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
