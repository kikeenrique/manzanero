import Darwin
import Foundation
import Synchronization

/// `logs` on a physical device: unified-log entries streamed from now through
/// the device's log relay (`OSTraceRelay`), on the tool's own tunnel when it
/// reaches the device and over Apple's tunnel otherwise
/// (docs/app-logs.md#physical-devices).
///
/// One process (`--pid`, or a single `--bundle` or `--process` that matches
/// one running process): the device is asked for that PID, and the capture
/// ends when the process ends. A group or `--all`: the device is asked for
/// every process and the Mac keeps the selected ones, by PID, by process name
/// or by the app's folder, so an app that launches meanwhile is included.
/// Level, subsystem, category and `--match` are always filtered on the Mac.
enum PhysicalLogCapture {
    /// Bytes read from the relay before the capture stops, whatever is kept.
    static let receivedBytesCeiling = 256 * 1024 * 1024
    /// How often the process of a one-process capture is looked for.
    static let watchInterval = Duration.seconds(2)

    static func plan(_ capture: LogCapture) -> [String: Any] {
        var plan: [String: Any] = [
            "backend": "os-trace-relay", "operation": "logs", "platform": "physical", "device": capture.device, "readOnly": true,
            "service": OSTraceRelay.service, "level": capture.level.rawValue, "source": capture.source, "all": capture.all,
            "hostFilter": filterDescription(capture),
            "deviceStream": deviceStreamDescription(capture),
            "bounds": ["maxEntries": capture.maxEntries, "maxBytes": capture.maxBytes, "seconds": seconds(capture),
                       "receivedBytesCeiling": receivedBytesCeiling, "maximumRecordBytes": OSTraceRelay.maximumRecordBytes],
            "route": ["first": "the tool's own tunnel (MANZANERO_OWN_TUNNEL=0 turns it off)",
                      "fallback": "Apple's tunnel: a tunnel assertion, port discovery and the device's service directory"],
            "execution": "Requires a paired device with Developer Mode. Streams from the device's log relay and filters on the Mac; stops at the duration, the entry limit or the byte limit, when the device closes the stream, or, for one process, when that process ends. Sends the device no input.",
        ]
        if !capture.bundles.isEmpty || !capture.processes.isEmpty {
            plan["targetResolution"] = ["bundles": capture.bundles, "processes": capture.processes,
                                        "queries": ["devicectl device info apps", "devicectl device info processes"],
                                        "match": "a bundle by its installed .app folder, a process by its executable's name"]
        }
        if case .pid(let pid) = capture.targets.first, capture.targets.count == 1 { plan["pid"] = Int(pid) }
        if let output = capture.output { plan["output"] = output; plan["inlineEntries"] = LogCapture.inlineEntriesWithOutput }
        return plan
    }

    static func seconds(_ capture: LogCapture) -> Int {
        if case .stream(let seconds) = capture.mode { return seconds }
        return 0
    }

    private static func deviceStreamDescription(_ capture: LogCapture) -> String {
        if capture.all || capture.targets.count > 1 { return "every process" }
        if case .pid(let pid) = capture.targets[0] { return "PID \(pid), until it ends" }
        return "the one running process that matches, until it ends; every process when several match"
    }

    private static func filterDescription(_ capture: LogCapture) -> String {
        var clauses: [String] = []
        if !capture.all {
            clauses.append("(" + capture.targets.map { target -> String in
                switch target {
                case .pid(let pid): "pid == \(pid)"
                case .bundle(let bundle): "path inside the .app of \(bundle)"
                case .process(let name): "process == \(name)"
                }
            }.joined(separator: " OR ") + ")")
        }
        if !capture.subsystems.isEmpty { clauses.append("subsystem in \(capture.subsystems)") }
        if !capture.categories.isEmpty { clauses.append("category in \(capture.categories)") }
        if let match = capture.match { clauses.append("message contains \(LogCapture.quote(match))") }
        clauses.append("level in \(PhysicalLogReader.levels(capture.level).sorted())")
        return clauses.joined(separator: " AND ")
    }

    // MARK: Which processes

    /// What the device is asked for and what the Mac keeps.
    struct Selection: Equatable, Sendable {
        /// The one process the device streams, which ends the capture when it
        /// ends; nil: every process.
        var pid: Int32?
        var pids: Set<Int32> = []
        var names: Set<String> = []
        /// `.app` folders, with a trailing slash and without `/private`.
        var folders: [String] = []
        /// The executable of the one process, when it was looked up.
        var executable: String?

        var everyProcess: Bool { pids.isEmpty && names.isEmpty && folders.isEmpty }

        func accepts(pid: Int32, path: String) -> Bool {
            if everyProcess { return true }
            let path = PhysicalLogCapture.normalized(path)
            return pids.contains(pid) || names.contains(URL(fileURLWithPath: path).lastPathComponent)
                || folders.contains(where: path.hasPrefix)
        }
    }

    /// `apps` and `processes` are the outputs of `devicectl device info apps`
    /// and `processes` as JSON, read only when a bundle or a name needs them.
    static func select(_ capture: LogCapture, apps: () throws -> Data, processes: () throws -> Data) throws -> Selection {
        if capture.all { return Selection() }
        if case .pid(let pid) = capture.targets[0], capture.targets.count == 1 { return Selection(pid: pid, pids: [pid]) }
        var folders: [String: String] = [:]
        if !capture.bundles.isEmpty {
            let installed = try apps()
            for bundle in capture.bundles {
                guard let folder = try appDirectory(installed, bundle: bundle) else {
                    throw CommandFailure(.targetUnresolved, "\(bundle) is not installed on the device; nothing was captured.", inputSent: .none)
                }
                folders[bundle] = normalized(folder) + "/"
            }
        }
        let selection = Selection(names: Set(capture.processes), folders: capture.bundles.compactMap { folders[$0] })
        guard capture.targets.count == 1 else { return selection }
        // One bundle or one name: the one running process, by its main
        // executable (an extension's sits deeper in the bundle).
        let running = try runningProcesses(processes())
        let matches = running.filter { process in
            switch capture.targets[0] {
            case .bundle(let bundle): normalized(URL(fileURLWithPath: process.executable).deletingLastPathComponent().path) + "/" == folders[bundle]
            case .process(let name): URL(fileURLWithPath: process.executable).lastPathComponent == name
            case .pid: false
            }
        }
        switch matches.count {
        case 0:
            let what = capture.bundles.first ?? "A process named \(capture.processes[0])"
            throw CommandFailure(.targetUnresolved, "\(what) is not running; launch it first, or capture with --all and a filter to see it start. Nothing was captured.", inputSent: .none)
        case 1:
            return Selection(pid: matches[0].pid, pids: [matches[0].pid], executable: matches[0].executable)
        default:
            // Several processes of that name: every process, kept by name.
            return selection
        }
    }

    /// `/private/var/…` as `/var/…`: devicectl and the relay do not agree on it.
    static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    static func runningProcesses(_ data: Data) throws -> [(pid: Int32, executable: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let running = (root["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]] else {
            throw CommandFailure(.toolFailed, "devicectl's process list could not be read; nothing was captured.", inputSent: .none)
        }
        return running.compactMap { process in
            guard let pid = (process["processIdentifier"] as? NSNumber).flatMap({ Int32(exactly: $0.intValue) }), pid > 0,
                  let executable = process["executable"] as? String else { return nil }
            return (pid, path(executable))
        }
    }

    /// The installed `.app` directory of a bundle, without a trailing slash.
    static func appDirectory(_ data: Data, bundle: String) throws -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else {
            throw CommandFailure(.toolFailed, "devicectl's app list could not be read; nothing was captured.", inputSent: .none)
        }
        guard let url = apps.first(where: { $0["bundleIdentifier"] as? String == bundle })?["url"] as? String else { return nil }
        return URL(fileURLWithPath: path(url)).standardizedFileURL.path
    }

    /// A `file://` URL's path, or the text itself.
    private static func path(_ text: String) -> String {
        if text.hasPrefix("file:"), let url = URL(string: text) { return url.path }
        return text
    }

    // MARK: The stream

    /// Sockets to the device's log relay and what closes them.
    struct Connection: @unchecked Sendable {
        let descriptor: Int32
        /// Opens another socket to the relay, until `close`: on the tool's
        /// own tunnel only, where it is one more relayed connection. The
        /// relay answers one `PidList` per socket, so each look at the
        /// process list takes a new one.
        var another: (@Sendable () throws -> Int32)? = nil
        /// `serviceDirectory`, `ownTunnelLink`, `ownTunnelUnavailable`: the
        /// route, in the words accessibility results use.
        let route: [String: String]
        let close: @Sendable () -> Void
    }

    struct Environment: Sendable {
        /// `devicectl device info details`.
        var details: @Sendable () throws -> Data
        /// A read-only `devicectl` query (apps, processes).
        var query: @Sendable (DeviceCommand) throws -> Data
        /// Opens the relay for a hardware UDID at the device's tunnel address.
        var open: @Sendable (_ udid: String, _ address: String, _ details: Data) async throws -> Connection
    }

    static func live(device: String, details: @escaping @Sendable () throws -> Data, ownTunnel: OwnTunnelSource = .pooled) -> Environment {
        Environment(details: details, query: { plan in
            try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 60)
        }, open: { udid, address, details in
            try await open(udid: udid, address: address, details: details, ownTunnel: ownTunnel)
        })
    }

    /// The tool's own tunnel when it can be had, where reading the directory
    /// disturbs nobody; otherwise Apple's tunnel, where it makes the device
    /// reset the Mac's connection once.
    static func open(udid: String, address: String, details: Data, ownTunnel: OwnTunnelSource) async throws -> Connection {
        var note: String?
        switch ownTunnel.acquire(udid, address) {
        case .success(let tunnel):
            do {
                let directory = try RSDDirectoryConnection(tunnelAddress: "::1", port: try tunnel.relay(to: tunnel.info.serviceDirectoryPort),
                                                           expectedUDID: udid, relayed: true)
                do {
                    let port = try directory.shimServicePort(OSTraceRelay.service)
                    let descriptor = try RSDDirectoryConnection.connectStream(address: "::1", port: try tunnel.relay(to: port), relayed: true)
                    let owned = UncheckedBox(directory)
                    return Connection(descriptor: descriptor, another: {
                        try RSDDirectoryConnection.connectStream(address: "::1", port: try tunnel.relay(to: port), relayed: true)
                    }, route: ["serviceDirectory": "own-tunnel", "ownTunnelLink": tunnel.info.link], close: {
                        Darwin.close(descriptor)
                        owned.value.close()
                        ownTunnel.release(tunnel, tunnel.isAlive)
                    })
                } catch {
                    directory.close()
                    throw error
                }
            } catch {
                ownTunnel.release(tunnel, false)
                note = String("\(error)".prefix(500))
            }
        case .failure(let failure):
            note = failure.description
        case nil:
            break
        }
        try StaleDeviceConnection.refuseIfStale(device: udid, operation: "logs")
        let assertion = try NativeTunnelAssertion(device: udid, details: details)
        do {
            let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
            let directory = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: udid)
            do {
                let descriptor = try directory.openShimService(OSTraceRelay.service)
                var route = ["serviceDirectory": "opened"]
                route["ownTunnelUnavailable"] = note
                let owned = UncheckedBox((directory, assertion))
                return Connection(descriptor: descriptor, route: route, close: {
                    Darwin.close(descriptor)
                    owned.value.0.close()
                    owned.value.1.close()
                })
            } catch {
                directory.close()
                throw error
            }
        } catch {
            assertion.close()
            throw error
        }
    }

    static func execute(_ capture: LogCapture, environment: Environment) async throws -> Data {
        if let output = capture.output, FileManager.default.fileExists(atPath: output) {
            throw CommandFailure.usage("--output refuses an existing file: \(output).")
        }
        let details = try environment.details()
        guard let root = (try? JSONSerialization.jsonObject(with: details)) as? [String: Any],
              let properties = (root["result"] as? [String: Any])?["properties"] as? [String: Any],
              let udid = (properties["hardware"] as? [String: Any])?["udid"] as? String else {
            throw CommandFailure(.deviceNotReady, "The device's details name no hardware identifier; nothing was captured.", inputSent: .none)
        }
        let device = capture.device
        // --quiet keeps devicectl's human-readable table off stderr.
        @Sendable func quiet(_ operation: String) throws -> DeviceCommand {
            var plan = try DeviceCommand.plan(physical: true, device: device, operation: operation)
            plan.arguments.append("--quiet")
            return plan
        }
        let selection = try select(capture, apps: { try environment.query(quiet("apps")) },
                                   processes: { try environment.query(quiet("processes")) })
        let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid)
        let connection = try await environment.open(udid, address, details)
        var watch: ProcessWatch?
        if let pid = selection.pid {
            if let another = connection.another {
                watch = ProcessWatch(source: "relay", isRunning: { try relayLists(pid, another: another) })
            } else {
                let query = environment.query
                watch = ProcessWatch(source: "devicectl", isRunning: {
                    try runningProcesses(query(quiet("processes"))).contains { $0.pid == pid }
                })
            }
        }
        let outcome = try await stream(connection, selection: selection, capture: capture, watch: watch)
        return try result(capture, outcome: outcome, selection: selection, route: connection.route)
    }

    /// How a one-process capture learns that its process has ended.
    struct ProcessWatch: Sendable {
        /// `relay` (its process list, on a socket of its own each time) or
        /// `devicectl` (on Apple's tunnel, where no new socket can be had).
        var source: String
        var isRunning: @Sendable () throws -> Bool
    }

    /// Whether the relay lists `pid`, asked on a fresh socket: the relay
    /// answers one `PidList` per socket and closes it on a second.
    static func relayLists(_ pid: Int32, another: () throws -> Int32) throws -> Bool {
        let descriptor = try another()
        defer { Darwin.close(descriptor) }
        let stream = OSTraceRelay.Stream(descriptor: descriptor, deadline: .now + .seconds(8))
        try OSTraceRelay.checkIn(stream)
        return try OSTraceRelay.pidList(stream).contains(pid)
    }

    /// What a stream read, and what became of the process watch.
    struct Outcome: Sendable {
        var reader: PhysicalLogReader
        /// For one process: the watch's source while it worked to the end,
        /// or why it stopped working.
        var processWatch: String?
    }

    /// Reads on a thread of its own, so the command service's queue is free
    /// for other calls meanwhile; cancellation stops it within 100 ms. For
    /// one process, a second thread looks for it every `watchInterval` and
    /// ends the capture when it is gone.
    static func stream(_ connection: Connection, selection: Selection, capture: LogCapture, watch: ProcessWatch? = nil,
                       watchInterval: Duration = watchInterval) async throws -> Outcome {
        let cancelled = CancelFlag(), ended = CancelFlag(), stopWatch = CancelFlag()
        let watchNote = Mutex<String?>(nil)
        let start = PhysicalLogReader(capture: capture, selection: selection, receivedBytesCeiling: receivedBytesCeiling)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                Thread.detachNewThread {
                    let watcherDone = DispatchSemaphore(value: 0)
                    var watching = false
                    defer {
                        stopWatch.set()
                        if watching { watcherDone.wait() }
                        connection.close()
                    }
                    var reader = start
                    let isCancelled: @Sendable () -> Bool = { cancelled.isSet || ended.isSet }
                    do {
                        try OSTraceRelay.start(OSTraceRelay.Stream(descriptor: connection.descriptor, deadline: .now + .seconds(8),
                                                                   cancelled: isCancelled), pid: selection.pid ?? -1)
                        if selection.pid != nil, let watch {
                            watching = true
                            watchNote.withLock { $0 = watch.source }
                            Thread.detachNewThread {
                                defer { watcherDone.signal() }
                                if let failure = watchProcess(watch.isRunning, every: watchInterval, stop: stopWatch, ended: ended) {
                                    watchNote.withLock { $0 = "\(watch.source) \(failure)" }
                                }
                            }
                        }
                        let reading = OSTraceRelay.Stream(descriptor: connection.descriptor, deadline: .now + .seconds(seconds(capture)),
                                                          cancelled: isCancelled)
                        reading: while true {
                            let packet: Data
                            do { packet = try reading.packet() } catch let failure as CommandFailure where failure.code == .timeout {
                                reader.stop(.duration); break reading
                            } catch is OSTraceRelay.Closed {
                                reader.stop(.closed); break reading
                            } catch is CancellationError where ended.isSet && !cancelled.isSet {
                                reader.stop(.processEnded); break reading
                            }
                            guard reader.feed(packet) else { break reading }
                        }
                        // The watch's last word, before the result is made.
                        stopWatch.set()
                        if watching { watcherDone.wait(); watching = false }
                        continuation.resume(returning: Outcome(reader: reader, processWatch: watchNote.withLock { $0 }))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Looks for the process every `interval` until it is gone (then sets
    /// `ended`) or `stop` is set. Returns why it stopped looking, if a look
    /// failed; the capture then runs to its other limits.
    static func watchProcess(_ isRunning: () throws -> Bool, every interval: Duration, stop: CancelFlag, ended: CancelFlag) -> String? {
        while !stop.isSet {
            do {
                if try !isRunning() { ended.set(); return nil }
            } catch {
                return "unavailable: " + String("\(error)".prefix(300))
            }
            let next = ContinuousClock.now + interval
            while ContinuousClock.now < next, !stop.isSet { Thread.sleep(forTimeInterval: 0.05) }
        }
        return nil
    }

    static func result(_ capture: LogCapture, outcome: Outcome, selection: Selection, route: [String: String]) throws -> Data {
        let reader = outcome.reader
        var inline = reader.entries
        if let output = capture.output {
            var file = Data()
            for entry in reader.entries { file.append(entry); file.append(10) }
            guard FileManager.default.createFile(atPath: output, contents: file, attributes: [.posixPermissions: 0o600]) else {
                throw CommandFailure(.hostRequirement, "Cannot write --output \(output); the parent directory must exist.", inputSent: .none)
            }
            inline = Array(inline.suffix(LogCapture.inlineEntriesWithOutput))
        }
        var result: [String: Any] = [
            "platform": "physical", "device": capture.device, "operation": "logs", "source": capture.source,
            "deviceStream": selection.pid.map { "pid \($0)" } ?? "every process",
            "entries": try inline.map { try JSONSerialization.jsonObject(with: $0) },
            "entryCount": reader.entries.count, "entryBytes": reader.entryBytes, "receivedBytes": reader.receivedBytes,
            "receivedRecords": reader.receivedRecords, "filteredOut": reader.filteredOut, "parseFailures": reader.parseFailures,
            "stopReason": (reader.stopReason ?? .duration).rawValue, "truncated": reader.truncated, "level": capture.level.rawValue,
        ]
        if let pid = selection.pid { result["pid"] = Int(pid) }
        if let executable = selection.executable { result["executable"] = executable }
        if let watch = outcome.processWatch { result["processWatch"] = watch }
        if let failure = reader.firstParseFailure { result["firstParseFailure"] = failure }
        if let output = capture.output { result["output"] = output; result["inlineEntryCount"] = inline.count }
        result.merge(route) { $1 }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// Holds a non-Sendable owner (a directory connection, a tunnel assertion)
/// for the one closure that closes it, after the stream's thread is done.
final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Set once; the reading threads check it.
final class CancelFlag: Sendable {
    let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}

/// Keeps or drops each record of the relay and enforces the bounds, as
/// `UnifiedLogReader` does for a simulator. Entries have the same fields.
struct PhysicalLogReader: Sendable {
    enum StopReason: String, Sendable { case duration, closed, processEnded, entryLimit, byteLimit }

    let selection: PhysicalLogCapture.Selection
    let subsystems: Set<String>
    let categories: Set<String>
    let match: String?
    let levels: Set<String>
    let maxEntries: Int
    let maxBytes: Int
    let receivedBytesCeiling: Int

    private(set) var entries: [Data] = []
    private(set) var entryBytes = 0
    private(set) var receivedBytes = 0
    private(set) var receivedRecords = 0
    private(set) var filteredOut = 0
    private(set) var parseFailures = 0
    /// Why the first record that did not parse was refused.
    private(set) var firstParseFailure: String?
    private(set) var stopReason: StopReason?

    init(capture: LogCapture, selection: PhysicalLogCapture.Selection, receivedBytesCeiling: Int) {
        self.selection = selection
        subsystems = Set(capture.subsystems); categories = Set(capture.categories); match = capture.match
        levels = Self.levels(capture.level)
        maxEntries = capture.maxEntries; maxBytes = capture.maxBytes; self.receivedBytesCeiling = receivedBytesCeiling
    }

    /// The level names `--level` keeps: errors and faults always, as `log`
    /// shows them at its default level.
    static func levels(_ level: LogCapture.Level) -> Set<String> {
        switch level {
        case .default: ["default", "error", "fault"]
        case .info: ["default", "error", "fault", "info"]
        case .debug: ["default", "error", "fault", "info", "debug"]
        }
    }

    var truncated: Bool { stopReason == .entryLimit || stopReason == .byteLimit }

    mutating func stop(_ reason: StopReason) { if stopReason == nil { stopReason = reason } }

    /// Returns false once a limit stops the capture.
    mutating func feed(_ packet: Data) -> Bool {
        guard stopReason == nil else { return false }
        receivedBytes += packet.count + 5
        receivedRecords += 1
        if receivedBytes > receivedBytesCeiling { stopReason = .byteLimit; return false }
        let record: OSTraceRelay.Record
        do { record = try OSTraceRelay.parse(packet) } catch {
            parseFailures += 1
            if firstParseFailure == nil { firstParseFailure = "\(error) (\(packet.count) bytes)" }
            return true
        }
        let level = record.levelName
        guard selection.accepts(pid: Int32(bitPattern: record.pid), path: record.process),
              levels.contains(level) || level.hasPrefix("unknown"),
              subsystems.isEmpty || subsystems.contains(record.subsystem), categories.isEmpty || categories.contains(record.category),
              match.map(record.message.contains) ?? true else {
            filteredOut += 1
            return true
        }
        let entry: [String: Any] = [
            "timestamp": record.timestamp, "level": level, "pid": Int(record.pid),
            "process": URL(fileURLWithPath: record.process).lastPathComponent,
            "subsystem": record.subsystem, "category": record.category, "sender": record.image, "message": record.message,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            parseFailures += 1
            return true
        }
        if entries.count + 1 > maxEntries { stopReason = .entryLimit; return false }
        if entryBytes + encoded.count + 1 > maxBytes { stopReason = .byteLimit; return false }
        entries.append(encoded)
        entryBytes += encoded.count + 1
        return true
    }
}
