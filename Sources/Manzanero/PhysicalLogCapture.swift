import Darwin
import Foundation
import Synchronization

/// `logs` on a physical device: one process's unified-log entries, streamed
/// from now through the device's log relay (`OSTraceRelay`), on the tool's
/// own tunnel when it reaches the device and over Apple's tunnel otherwise
/// (docs/app-logs.md#physical-devices).
///
/// The device is asked for one PID's entries at every level; level,
/// subsystem and category are filtered on the Mac, and so is the PID again,
/// so nothing of another process reaches the output. `--bundle` and
/// `--process` are resolved to one running process first: the stream follows
/// that PID, and a relaunch of the app is not followed.
enum PhysicalLogCapture {
    /// Bytes read from the relay before the capture stops, whatever is kept.
    static let receivedBytesCeiling = 64 * 1024 * 1024

    static func plan(_ capture: LogCapture) -> [String: Any] {
        var plan: [String: Any] = [
            "backend": "os-trace-relay", "operation": "logs", "platform": "physical", "device": capture.device, "readOnly": true,
            "service": OSTraceRelay.service, "level": capture.level.rawValue, "source": capture.source,
            "hostFilter": filterDescription(capture),
            "bounds": ["maxEntries": capture.maxEntries, "maxBytes": capture.maxBytes, "seconds": seconds(capture),
                       "receivedBytesCeiling": receivedBytesCeiling, "maximumRecordBytes": OSTraceRelay.maximumRecordBytes],
            "route": ["first": "the tool's own tunnel (MANZANERO_OWN_TUNNEL=0 turns it off)",
                      "fallback": "Apple's tunnel: a tunnel assertion, port discovery and the device's service directory"],
            "execution": "Requires a paired device with Developer Mode. Asks the device's log relay for one process's entries at every level and filters on the Mac; stops at the duration, the entry limit or the byte limit, or when the device closes the stream. A relaunch of the app is not followed. Sends the device no input.",
        ]
        switch capture.target {
        case .pid(let pid): plan["pid"] = Int(pid)
        case .bundle(let bundle):
            plan["targetResolution"] = ["bundle": bundle, "queries": ["devicectl device info apps", "devicectl device info processes"],
                                        "match": "the one running process whose executable is directly inside the app's bundle"]
        case .process(let name):
            plan["targetResolution"] = ["process": name, "queries": ["devicectl device info processes"],
                                        "match": "the one running process whose executable has this name"]
        }
        if let output = capture.output { plan["output"] = output; plan["inlineEntries"] = LogCapture.inlineEntriesWithOutput }
        return plan
    }

    static func seconds(_ capture: LogCapture) -> Int {
        if case .stream(let seconds) = capture.mode { return seconds }
        return 0
    }

    private static func filterDescription(_ capture: LogCapture) -> String {
        var clauses: [String]
        switch capture.target {
        case .pid(let pid): clauses = ["pid == \(pid)"]
        case .bundle(let bundle): clauses = ["pid == <the running process of \(bundle)>"]
        case .process(let name): clauses = ["pid == <the running process named \(name)>"]
        }
        if let subsystem = capture.subsystem { clauses.append("subsystem == \(subsystem)") }
        if let category = capture.category { clauses.append("category == \(category)") }
        clauses.append("level in \(PhysicalLogReader.levels(capture.level).sorted())")
        return clauses.joined(separator: " AND ")
    }

    // MARK: The process

    struct Resolved: Equatable {
        let pid: Int32
        let executable: String?
    }

    /// `--bundle` and `--process` to one running process; `apps` and
    /// `processes` are the outputs of `devicectl device info apps` and
    /// `processes` as JSON.
    static func resolve(_ target: LogCapture.Target, apps: () throws -> Data, processes: () throws -> Data) throws -> Resolved {
        if case .pid(let pid) = target { return Resolved(pid: pid, executable: nil) }
        let running = try runningProcesses(processes())
        let matches: [(pid: Int32, executable: String)]
        switch target {
        case .pid: fatalError("handled above")
        case .bundle(let bundle):
            guard let app = try appDirectory(apps(), bundle: bundle) else {
                throw CommandFailure(.targetUnresolved, "\(bundle) is not installed on the device; nothing was captured.", inputSent: .none)
            }
            // The main executable sits directly in the bundle; an extension's
            // sits deeper, under PlugIns or Extensions.
            matches = running.filter { URL(fileURLWithPath: $0.executable).deletingLastPathComponent().standardizedFileURL.path == app }
            guard !matches.isEmpty else {
                throw CommandFailure(.targetUnresolved, "\(bundle) is not running; launch it first (launch or console), then capture. Nothing was captured.", inputSent: .none)
            }
        case .process(let name):
            matches = running.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == name }
            guard !matches.isEmpty else {
                throw CommandFailure(.targetUnresolved, "No running process is named \(name); nothing was captured.", inputSent: .none)
            }
        }
        guard matches.count == 1 else {
            let pids = matches.map { String($0.pid) }.joined(separator: ", ")
            throw CommandFailure(.targetUnresolved, "\(matches.count) running processes match (PIDs \(pids)); give one with --pid. Nothing was captured.", inputSent: .none)
        }
        return Resolved(pid: matches[0].pid, executable: matches[0].executable)
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

    /// A socket to the device's log relay and what closes it.
    struct Connection: @unchecked Sendable {
        let descriptor: Int32
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
        }, open: { udid, address, details in try await open(udid: udid, address: address, details: details, ownTunnel: ownTunnel) })
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
                    let port = try tunnel.relay(to: directory.shimServicePort(OSTraceRelay.service))
                    let descriptor = try RSDDirectoryConnection.connectStream(address: "::1", port: port, relayed: true)
                    let owned = UncheckedBox(directory)
                    return Connection(descriptor: descriptor, route: ["serviceDirectory": "own-tunnel", "ownTunnelLink": tunnel.info.link], close: {
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
        func quiet(_ operation: String) throws -> DeviceCommand {
            var plan = try DeviceCommand.plan(physical: true, device: device, operation: operation)
            plan.arguments.append("--quiet")
            return plan
        }
        let resolved = try resolve(capture.target, apps: { try environment.query(quiet("apps")) },
                                   processes: { try environment.query(quiet("processes")) })
        let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: udid)
        let connection = try await environment.open(udid, address, details)
        let reader = try await stream(connection, pid: resolved.pid, capture: capture)
        return try result(capture, reader: reader, resolved: resolved, route: connection.route)
    }

    /// Reads on a thread of its own, so the command service's queue is free
    /// for other calls meanwhile; cancellation stops it within 100 ms.
    static func stream(_ connection: Connection, pid: Int32, capture: LogCapture,
                       clock: ContinuousClock = ContinuousClock()) async throws -> PhysicalLogReader {
        let flag = CancelFlag()
        let start = PhysicalLogReader(capture: capture, pid: pid, receivedBytesCeiling: receivedBytesCeiling)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhysicalLogReader, any Error>) in
                Thread.detachNewThread {
                    defer { connection.close() }
                    var reader = start
                    let isCancelled: @Sendable () -> Bool = { flag.isSet }
                    do {
                        try OSTraceRelay.start(OSTraceRelay.Stream(descriptor: connection.descriptor, deadline: .now + .seconds(8),
                                                                   cancelled: isCancelled), pid: pid)
                        let reading = OSTraceRelay.Stream(descriptor: connection.descriptor, deadline: .now + .seconds(seconds(capture)),
                                                          cancelled: isCancelled)
                        reading: while true {
                            let packet: Data
                            do { packet = try reading.packet() } catch let failure as CommandFailure where failure.code == .timeout {
                                reader.stop(.duration); break reading
                            } catch is OSTraceRelay.Closed {
                                reader.stop(.closed); break reading
                            }
                            guard reader.feed(packet) else { break reading }
                        }
                        continuation.resume(returning: reader)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.value.store(true, ordering: .relaxed)
        }
    }

    static func result(_ capture: LogCapture, reader: PhysicalLogReader, resolved: Resolved, route: [String: String]) throws -> Data {
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
            "pid": Int(resolved.pid),
            "entries": try inline.map { try JSONSerialization.jsonObject(with: $0) },
            "entryCount": reader.entries.count, "entryBytes": reader.entryBytes, "receivedBytes": reader.receivedBytes,
            "receivedRecords": reader.receivedRecords, "filteredOut": reader.filteredOut, "parseFailures": reader.parseFailures,
            "stopReason": (reader.stopReason ?? .duration).rawValue, "truncated": reader.truncated, "level": capture.level.rawValue,
            "limitations": ["The stream follows one PID: a relaunch of the app is not followed.",
                            "Entries are filtered by level, subsystem and category on the Mac; the device sends every level of the process."],
        ]
        if let executable = resolved.executable { result["executable"] = executable }
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

/// Set when the command is cancelled; the reading thread checks it.
final class CancelFlag: Sendable {
    let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
}

/// Keeps or drops each record of the relay and enforces the bounds, as
/// `UnifiedLogReader` does for a simulator. Entries have the same fields.
struct PhysicalLogReader: Sendable {
    enum StopReason: String, Sendable { case duration, closed, entryLimit, byteLimit }

    let pid: Int32
    let subsystem: String?
    let category: String?
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

    init(capture: LogCapture, pid: Int32, receivedBytesCeiling: Int) {
        self.pid = pid; subsystem = capture.subsystem; category = capture.category
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
        guard Int32(bitPattern: record.pid) == pid, levels.contains(level) || level.hasPrefix("unknown"),
              subsystem.map({ record.subsystem == $0 }) ?? true, category.map({ record.category == $0 }) ?? true else {
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
