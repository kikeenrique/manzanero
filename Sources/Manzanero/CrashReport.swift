import Foundation

/// `last-crash`: the newest crash report for one app, as a parsed summary.
///
/// - Simulator: the report the simulator left on the Mac in
///   `~/Library/Logs/DiagnosticReports` (top level only), filtered by
///   `platform` 7 (iOS simulator), bug type 309, bundle or process name, time,
///   and the simulator's device directory when the report's `procPath` shows it.
/// - Physical: the device's `systemCrashLogs` listing (the existing `reports`
///   route), filtered by name and time; the newest candidates are downloaded
///   (the existing `report` route) until one's header matches.
///
/// The directory is never listed to the caller: only the matching report is
/// returned. Frames are not symbolicated beyond what the report carries.
struct LastCrashQuery: Sendable, Equatable {
    static let maxDownloads = 5
    static let maxHeaderReads = 500
    static let maxFrames = 12
    static let crashBugType = "309"
    static let simulatorPlatform = 7
    static let devicePlatform = 2

    let physical: Bool
    let device: String
    let bundle: String?
    let process: String?
    let since: Date?
    let download: String?

    init(physical: Bool, device: String, bundle: String? = nil, process: String? = nil, since: Date? = nil, download: String? = nil) {
        self.physical = physical; self.device = device; self.bundle = bundle; self.process = process
        self.since = since; self.download = download
    }

    init(physical: Bool, device: String, operands: [String]) throws {
        let options = try DiagnosticOptions(operands, operation: "last-crash", values: ["--bundle", "--process", "--since", "--download"])
        guard options.positional.isEmpty,
              [options.values["--bundle"], options.values["--process"]].compactMap({ $0 }).count == 1 else {
            throw CommandFailure.usage("Usage: last-crash (--bundle <id> | --process <name>) [--since <ISO-8601>] [--download <existing-dir>]")
        }
        if let download = options.values["--download"], download.hasPrefix("-") {
            throw CommandFailure.usage("--download needs an existing host directory.")
        }
        self.init(physical: physical, device: device,
                  bundle: try options.values["--bundle"].map(DiagnosticNames.bundleIdentifier),
                  process: try options.values["--process"].map(DiagnosticNames.processName),
                  since: try options.date("--since"), download: options.values["--download"])
    }

    var listingPlan: DeviceCommand? { try? DeviceCommand.parse(["physical", device, "reports", "."]) }

    func plan() -> [String: Any] {
        let sinceValue: Any = since.map { DiagnosticTime.iso8601($0) } ?? NSNull()
        var plan: [String: Any] = [
            "operation": "last-crash", "platform": physical ? "physical" : "simulator", "device": device, "readOnly": true,
            "match": ["bundleId": bundle ?? NSNull(), "process": process ?? NSNull(),
                      "since": sinceValue, "bugType": Self.crashBugType] as [String: Any],
            "maxFrames": Self.maxFrames, "symbolicated": false,
        ]
        if let download { plan["download"] = download }
        if physical {
            plan["backend"] = "devicectl"
            plan["listing"] = ["executable": "/usr/bin/xcrun", "arguments": listingPlan?.arguments ?? []]
            plan["download"] = ["executable": "/usr/bin/xcrun", "arguments": (try? DeviceCommand.parse(["physical", device, "report", "<report.ips>", "<tmp/crash-…/report.ips>"]))?.arguments ?? [],
                                "maxDownloads": Self.maxDownloads]
            plan["execution"] = "Lists systemCrashLogs without recursion, keeps .ips names newer than --since (and starting with '<process>-' for --process), downloads the newest into tmp/ one at a time (at most \(Self.maxDownloads)) until a header matches the bundle or process, deletes non-matching downloads, and parses the match. The download route is not yet verified on hardware."
        } else {
            plan["backend"] = "host-files"
            plan["directory"] = "~/Library/Logs/DiagnosticReports"
            plan["execution"] = "Reads only the JSON headers of host .ips reports (platform 7, bug type 309, matching bundle or process, newer than --since), excludes reports whose procPath names another simulator, and parses the newest. Never lists the directory to the caller."
        }
        return plan
    }
}

/// A two-part `.ips` crash report: a one-line JSON header, then one JSON body.
struct IPSReport {
    let header: [String: Any]
    let body: [String: Any]

    init(_ data: Data) throws {
        let newline = data.firstIndex(of: 10) ?? data.endIndex
        guard let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) as? [String: Any] else {
            throw CommandFailure(.toolFailed, "Not a recognised .ips report: the first line is not a JSON header.", inputSent: .none)
        }
        let rest = newline < data.endIndex ? data[(newline + 1)...] : Data()
        guard let body = (try? JSONSerialization.jsonObject(with: rest)) as? [String: Any] else {
            throw CommandFailure(.toolFailed, "Not a recognised .ips report: the body after the header is not one JSON object.", inputSent: .none)
        }
        self.header = header
        self.body = body
    }

    /// Only the first line, for cheap filtering.
    static func header(_ data: Data) -> [String: Any]? {
        let newline = data.firstIndex(of: 10) ?? data.endIndex
        return (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) as? [String: Any]
    }

    static func bugType(_ header: [String: Any]) -> String? {
        if let text = header["bug_type"] as? String { return text }
        return (header["bug_type"] as? NSNumber)?.stringValue
    }

    static func platform(_ header: [String: Any]) -> Int? { (header["platform"] as? NSNumber)?.intValue }

    static func headerDate(_ header: [String: Any]) -> Date? {
        (header["timestamp"] as? String).flatMap(DiagnosticTime.parseApple)?.date
    }

    static func matches(_ header: [String: Any], bundle: String?, process: String?) -> Bool {
        if let bundle { return header["bundleID"] as? String == bundle }
        if let process { return header["app_name"] as? String == process || header["name"] as? String == process }
        return false
    }

    /// Whether `procPath` ties the report to one simulator: `true` for this
    /// one, `false` for another, `nil` when it does not say (system apps'
    /// paths are redacted).
    func simulatorMatch(_ uuid: String) -> Bool? {
        guard let path = body["procPath"] as? String, let range = path.range(of: "/Devices/") else { return nil }
        let rest = path[range.upperBound...]
        guard let end = rest.firstIndex(of: "/"), let found = UUID(uuidString: String(rest[..<end])) else { return nil }
        return found.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
    }

    func summary(maxFrames: Int = LastCrashQuery.maxFrames) -> [String: Any] {
        let images = body["usedImages"] as? [[String: Any]] ?? []
        func frames(_ list: [[String: Any]]) -> [[String: Any]] {
            list.prefix(maxFrames).map { frame in
                let index = (frame["imageIndex"] as? NSNumber)?.intValue
                var value: [String: Any] = [
                    "image": index.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? NSNull(),
                    "imageOffset": frame["imageOffset"] ?? NSNull(),
                ]
                if let symbol = frame["symbol"] { value["symbol"] = symbol }
                if let location = frame["symbolLocation"] { value["symbolLocation"] = location }
                return value
            }
        }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? NSNumber)?.intValue
        var thread: Any = NSNull()
        if let faulting, threads.indices.contains(faulting) {
            let entry = threads[faulting]
            thread = ["index": faulting, "queue": entry["queue"] ?? NSNull(), "name": entry["name"] ?? NSNull(),
                      "frameCount": (entry["frames"] as? [Any])?.count ?? 0,
                      "frames": frames(entry["frames"] as? [[String: Any]] ?? [])] as [String: Any]
        }
        var messages: [String] = []
        if let asi = body["asi"] as? [String: Any] {
            for key in asi.keys.sorted() {
                for message in asi[key] as? [String] ?? [] where messages.count < 5 { messages.append(String(message.prefix(1024))) }
            }
        }
        var reason = termination["indicator"] as? String
        if reason == nil, let namespace = termination["namespace"] {
            reason = "\(namespace) \(termination["code"].map { "\($0)" } ?? "")".trimmingCharacters(in: .whitespaces)
        }
        let timestamp = (header["timestamp"] as? String).map(DiagnosticTime.normalise)
        var summary: [String: Any] = [
            "found": true, "bugType": Self.bugType(header) ?? NSNull(), "platformCode": Self.platform(header) ?? NSNull(),
            "process": body["procName"] ?? header["name"] ?? NSNull(), "pid": body["pid"] ?? NSNull(),
            "bundleId": header["bundleID"] ?? (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] ?? NSNull(),
            "timestamp": timestamp ?? NSNull(),
            "captureTime": (body["captureTime"] as? String).map(DiagnosticTime.normalise) ?? NSNull(),
            "osVersion": header["os_version"] ?? NSNull(), "incident": header["incident_id"] ?? NSNull(),
            "exceptionType": exception["type"] ?? NSNull(), "signal": exception["signal"] ?? NSNull(),
            "exceptionCodes": exception["codes"] ?? NSNull(), "exceptionSubtype": exception["subtype"] ?? NSNull(),
            "terminationReason": reason ?? NSNull(),
            "termination": ["namespace": termination["namespace"] ?? NSNull(), "code": termination["code"] ?? NSNull(),
                            "indicator": termination["indicator"] ?? NSNull(), "byProc": termination["byProc"] ?? NSNull()],
            "faultingThread": thread, "crashMessages": messages, "symbolicated": false,
        ]
        if let backtrace = body["lastExceptionBacktrace"] as? [[String: Any]], !backtrace.isEmpty {
            summary["lastExceptionBacktrace"] = frames(backtrace)
        }
        return summary
    }
}

enum CrashReportSelection {
    struct Candidate: Sendable {
        let url: URL
        let modified: Date
    }

    /// Picks the newest simulator crash for the query among `.ips` files in
    /// `directory` (top level). Returns the report, its path and the device match.
    static func simulator(_ query: LastCrashQuery, directory: URL,
                          read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> (url: URL, report: IPSReport, deviceMatch: Bool?, considered: Int)? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var candidates: [Candidate] = []
        for url in urls where url.pathExtension == "ips" {
            if let process = query.process, !url.lastPathComponent.hasPrefix(process + "-") { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            // A report is written after the crash, so its file is never older than the crash.
            if let since = query.since, modified < since { continue }
            candidates.append(Candidate(url: url, modified: modified))
        }
        candidates.sort { $0.modified > $1.modified }
        var considered = 0
        var best: (url: URL, report: IPSReport, deviceMatch: Bool?, date: Date)?
        for candidate in candidates.prefix(LastCrashQuery.maxHeaderReads) {
            considered += 1
            guard let data = try? read(candidate.url), let header = IPSReport.header(data),
                  IPSReport.bugType(header) == LastCrashQuery.crashBugType,
                  IPSReport.platform(header) == LastCrashQuery.simulatorPlatform,
                  IPSReport.matches(header, bundle: query.bundle, process: query.process) else { continue }
            let date = IPSReport.headerDate(header) ?? candidate.modified
            if let since = query.since, date < since { continue }
            guard let report = try? IPSReport(data) else { continue }
            let match = report.simulatorMatch(query.device)
            if match == false { continue }
            if best == nil || date > best!.date { best = (candidate.url, report, match, date) }
        }
        return best.map { ($0.url, $0.report, $0.deviceMatch, considered) }
    }

    /// Physical listing candidates, newest first.
    static func deviceCandidates(_ listing: Data, query: LastCrashQuery) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let files = (object["result"] as? [String: Any])?["files"] as? [[String: Any]] else {
            throw CommandFailure(.toolFailed, "devicectl's report listing has no result.files array.", inputSent: .none)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var found: [(name: String, date: Date)] = []
        for file in files {
            guard let name = file["relativePath"] as? String ?? file["name"] as? String, name.hasSuffix(".ips"), !name.contains("/"),
                  (file["resources"] as? [String: Any])?["isDirectory"] as? Bool != true else { continue }
            if let process = query.process, !name.hasPrefix(process + "-") { continue }
            let metadata = file["metadata"] as? [String: Any] ?? [:]
            if let bugType = (metadata["extendedAttributes"] as? [String: Any])?["bug_type"] as? String, bugType != LastCrashQuery.crashBugType { continue }
            let text = metadata["lastModDate"] as? String ?? ""
            let date = formatter.date(from: text) ?? DiagnosticTime.parseISO8601(text) ?? .distantPast
            if let since = query.since, date < since { continue }
            found.append((name, date))
        }
        return found.sorted { $0.date > $1.date }.map(\.name)
    }

    static func notFound(_ query: LastCrashQuery, considered: Int) -> [String: Any] {
        let since: Any = query.since.map { DiagnosticTime.iso8601($0) } ?? NSNull()
        return ["found": false, "platform": query.physical ? "physical" : "simulator", "device": query.device,
                "bundleId": query.bundle ?? NSNull(), "process": query.process ?? NSNull(),
                "since": since, "candidatesConsidered": considered]
    }

    static func copy(_ url: URL, to directory: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandFailure.usage("--download needs an existing host directory: \(directory).")
        }
        let destination = URL(fileURLWithPath: directory).appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CommandFailure.usage("--download refuses to replace \(destination.path).")
        }
        do { try FileManager.default.copyItem(at: url, to: destination) } catch {
            throw CommandFailure(.hostRequirement, "Cannot copy the report to \(destination.path).", inputSent: .none)
        }
        return destination.path
    }

    static func executeSimulator(_ query: LastCrashQuery, environment: SimulatorEnvironment,
                                 directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")) throws -> Data {
        // The simulator need not be booted: a crash may have ended with it shut down.
        _ = try environment.lookup(query.device)
        guard let match = try simulator(query, directory: directory) else {
            return try encode(notFound(query, considered: 0))
        }
        var summary = match.report.summary()
        summary["platform"] = "simulator"
        summary["device"] = query.device
        summary["path"] = match.url.path
        summary["deviceMatch"] = match.deviceMatch.map { $0 ? "procPath" : "other" } ?? "unverified"
        summary["candidatesConsidered"] = match.considered
        if let download = query.download { summary["downloadedTo"] = try copy(match.url, to: download) }
        return try encode(summary)
    }

    static func executePhysical(_ query: LastCrashQuery, directory: URL, run: (DeviceCommand) throws -> Data) throws -> Data {
        guard let listing = query.listingPlan else { throw CommandFailure.usage("Invalid device.") }
        let names = try deviceCandidates(try run(listing), query: query)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var considered = 0
        for name in names.prefix(LastCrashQuery.maxDownloads) {
            considered += 1
            let local = directory.appendingPathComponent(name)
            guard let plan = try DeviceCommand.parse(["physical", query.device, "report", name, local.path]) else { continue }
            _ = try run(plan)
            guard let data = try? Data(contentsOf: local), let header = IPSReport.header(data),
                  IPSReport.bugType(header) == LastCrashQuery.crashBugType,
                  IPSReport.platform(header) != LastCrashQuery.simulatorPlatform,
                  IPSReport.matches(header, bundle: query.bundle, process: query.process),
                  let report = try? IPSReport(data) else {
                try? FileManager.default.removeItem(at: local)
                continue
            }
            var summary = report.summary()
            summary["platform"] = "physical"
            summary["device"] = query.device
            summary["path"] = local.path
            summary["remotePath"] = name
            summary["candidatesConsidered"] = considered
            if let download = query.download { summary["downloadedTo"] = try copy(local, to: download) }
            return try encode(summary)
        }
        var result = notFound(query, considered: considered)
        result["candidatesListed"] = names.count
        if names.count > LastCrashQuery.maxDownloads { result["note"] = "Only the newest \(LastCrashQuery.maxDownloads) candidates were downloaded; narrow with --since or --process." }
        return try encode(result)
    }

    static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
