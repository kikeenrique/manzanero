import Darwin
import Foundation
import Synchronization

/// `console`: launch (or relaunch) an app and return bounded tails of its
/// stdout and stderr.
///
/// - Simulator: `simctl launch --terminate-running-process --stdout=<file>
///   --stderr=<file>`, which returns at once. The tool waits until the app
///   exits or the duration passes, then reads the tails. The app keeps running
///   (and writing to the files) unless `--terminate` is given.
/// - Physical: `devicectl device process launch --console --terminate-existing`.
///   devicectl stays attached; at the duration the tool sends it SIGINT, which
///   devicectl forwards to the app, so the app always ends then. Unverified on
///   hardware: whether stderr and `os_log` mirroring reach the host is open.
struct ConsoleCapture: Sendable, Equatable {
    static let secondsRange = 1...60
    static let defaultMaxBytes = 64 * 1024
    static let maxBytesCeiling = 1024 * 1024
    /// Combined raw bytes after which the tool stops waiting (`byteLimit`).
    static let rawBytesCeiling = 8 * 1024 * 1024
    /// devicectl must be gone this long after the soft stop.
    static let physicalGraceSeconds = 20
    static let dtModeVariable = "OS_ACTIVITY_DT_MODE"
    /// Lines devicectl itself prints around `--console`, seen on iOS 27.2.1 with devicectl 651.32.
    static let launchedPrefix = "Launched application with"
    static let devicectlStatusPrefixes = [launchedPrefix, "Waiting for the application to terminate",
                                          "App terminated due to", "App exited"]

    let physical: Bool
    let device: String
    let bundle: String
    let seconds: Int
    let maxBytes: Int
    let osLog: Bool
    let terminate: Bool
    let appArguments: [String]

    init(physical: Bool, device: String, bundle: String, seconds: Int, maxBytes: Int = defaultMaxBytes,
         osLog: Bool = false, terminate: Bool = false, appArguments: [String] = []) {
        self.physical = physical; self.device = device; self.bundle = bundle; self.seconds = seconds; self.maxBytes = maxBytes
        self.osLog = osLog; self.terminate = terminate; self.appArguments = appArguments
    }

    init(physical: Bool, device: String, options: DiagnosticOptions) throws {
        guard options.positional.count == 1 else {
            throw CommandFailure.usage("Usage: console <bundle-id> --seconds <1...60> [--max-bytes N] [--os-log] [--terminate] [-- app-args…]")
        }
        guard let seconds = try options.integer("--seconds", in: Self.secondsRange) else {
            throw CommandFailure.usage("console needs --seconds <1...60>.")
        }
        guard options.trailing.allSatisfy({ !$0.contains("\0") }) else { throw CommandFailure.usage("App arguments cannot contain NUL.") }
        self.init(physical: physical, device: device, bundle: try DiagnosticNames.bundleIdentifier(options.positional[0]), seconds: seconds,
                  maxBytes: try options.integer("--max-bytes", in: 1024...Self.maxBytesCeiling) ?? Self.defaultMaxBytes,
                  osLog: options.flags.contains("--os-log"), terminate: options.flags.contains("--terminate"),
                  appArguments: options.trailing)
    }

    /// `SIMCTL_CHILD_`/`DEVICECTL_CHILD_` pass a variable to the launched app.
    var environment: [String: String] {
        osLog ? [(physical ? "DEVICECTL_CHILD_" : "SIMCTL_CHILD_") + Self.dtModeVariable: "enable"] : [:]
    }

    func simulatorArguments(stdout: String, stderr: String) -> [String] {
        ["simctl", "launch", "--terminate-running-process", "--stdout=\(stdout)", "--stderr=\(stderr)", device, bundle] + appArguments
    }

    func physicalArguments(json: String) -> [String] {
        // Options before the bundle, and `--` before it when the app has
        // arguments: devicectl reads one such as -ProbeList as its own short options.
        ["devicectl", "device", "process", "launch", "--device", device, "--console", "--terminate-existing",
         "--timeout", "\(seconds + 60)", "--json-output", json] + (appArguments.isEmpty ? [] : ["--"]) + [bundle] + appArguments
    }

    var hardDeadlineSeconds: Double { Double(seconds + Self.physicalGraceSeconds) }

    func plan(directory: URL) -> [String: Any] {
        var plan: [String: Any] = [
            "operation": "console", "platform": physical ? "physical" : "simulator", "device": device, "bundleId": bundle,
            "executable": "/usr/bin/xcrun", "environment": environment, "readOnly": false,
            "bounds": ["seconds": seconds, "maxBytesPerStream": maxBytes, "rawBytesCeiling": Self.rawBytesCeiling],
            "osLog": osLog, "terminate": terminate,
        ]
        if physical {
            plan["arguments"] = physicalArguments(json: directory.appendingPathComponent("launch.json").path)
            plan["backend"] = "devicectl"
            plan["hardDeadlineSeconds"] = hardDeadlineSeconds
            plan["liveVerification"] = "one iPhone 13 mini"
            plan["execution"] = "Relaunches the app attached to devicectl's console. At the duration devicectl receives SIGINT, which it forwards to the app, so the app always ends then (--terminate changes nothing). On the one phone checked, stdout, stderr and (with --os-log) mirrored log lines at info and above reached the host, and an app that aborted was reported with its output and signal."
        } else {
            plan["arguments"] = simulatorArguments(stdout: directory.appendingPathComponent("stdout.txt").path,
                                                   stderr: directory.appendingPathComponent("stderr.txt").path)
            plan["backend"] = "simctl"
            plan["execution"] = "Requires a booted simulator. Relaunches the app with stdout and stderr redirected to host files, waits until it exits or the duration passes, and returns byte-bounded tails. The app keeps running unless --terminate is given (then simctl terminate). simctl does not report how the app ended; use last-crash."
        }
        return plan
    }
}

/// Byte-bounded tails of what a console capture read.
struct ConsoleTail: Sendable {
    let limit: Int
    private(set) var data = Data()
    private(set) var total = 0

    init(limit: Int) { self.limit = limit }

    mutating func append(_ bytes: Data) {
        total += bytes.count
        data.append(bytes)
        if data.count > limit * 2 { data = Data(data.suffix(limit)) }
    }

    var truncated: Bool { total > limit }
    var text: String { Self.decode(Data(data.suffix(limit))) }

    /// Lossy UTF-8 without a broken leading character from the cut.
    static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        while text.unicodeScalars.first == "\u{FFFD}" { text.unicodeScalars.removeFirst() }
        return text
    }

    /// The last `limit` bytes of a file and its size.
    static func read(_ url: URL, limit: Int) -> (text: String, bytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", 0) }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: UInt64(max(0, size - limit)))
        let data = (try? handle.readToEnd()) ?? Data()
        return (decode(data), size)
    }
}

/// Injected effects for the simulator console, so tests need no simulator.
struct ConsoleEnvironment: Sendable {
    var lookup: @Sendable (String) throws -> SimulatorDeviceInfo
    var run: @Sendable ([String], [String: String]) throws -> Data
    var isAlive: @Sendable (Int32) -> Bool = { pid in Darwin.kill(pid, 0) == 0 || errno == EPERM }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    var pollInterval: Duration = .milliseconds(100)
}

enum AppConsole {
    /// `com.example.app: 1234`
    static func launchedPID(_ output: Data, bundle: String) -> Int32? {
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == bundle,
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    static func executeSimulator(_ capture: ConsoleCapture, directory: URL, environment: ConsoleEnvironment) async throws -> Data {
        _ = try SimulatorDevice.requireBooted(capture.device, operation: "console", lookup: environment.lookup)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw CommandFailure(.hostRequirement, "Cannot create the console capture directory \(directory.path).", inputSent: .none)
        }
        let stdoutURL = directory.appendingPathComponent("stdout.txt"), stderrURL = directory.appendingPathComponent("stderr.txt")
        let launch = try environment.run(capture.simulatorArguments(stdout: stdoutURL.path, stderr: stderrURL.path), capture.environment)
        guard let pid = launchedPID(launch, bundle: capture.bundle) else {
            throw CommandFailure(.toolFailed, "simctl launch did not report the app's process ID; inspect the simulator.", inputSent: .possible)
        }
        let start = environment.now()
        var stopReason = "duration"
        while true {
            if Task.isCancelled {
                throw CommandFailure(.cancelled, "Console capture cancelled; the app (pid \(pid)) was launched and left running.", inputSent: .possible)
            }
            if !environment.isAlive(pid) { stopReason = "exited"; break }
            if environment.now() - start >= .seconds(capture.seconds) { break }
            if fileSize(stdoutURL) + fileSize(stderrURL) > ConsoleCapture.rawBytesCeiling { stopReason = "byteLimit"; break }
            do { try await environment.sleep(environment.pollInterval) } catch {
                throw CommandFailure(.cancelled, "Console capture cancelled; the app (pid \(pid)) was launched and left running.", inputSent: .possible)
            }
        }
        var terminatedByTool = false
        var terminateError: String?
        if capture.terminate, stopReason != "exited" {
            do {
                _ = try environment.run(["simctl", "terminate", capture.device, capture.bundle], [:])
                terminatedByTool = true
                // Let the app's last writes land before reading the tails.
                for _ in 0..<20 where environment.isAlive(pid) { try? await environment.sleep(.milliseconds(100)) }
            } catch {
                terminateError = "\(error)"
            }
        }
        let out = ConsoleTail.read(stdoutURL, limit: capture.maxBytes), err = ConsoleTail.read(stderrURL, limit: capture.maxBytes)
        var result: [String: Any] = [
            "platform": "simulator", "device": capture.device, "operation": "console", "source": "simctl-launch-files",
            "bundleId": capture.bundle, "pid": pid, "stdoutTail": out.text, "stderrTail": err.text,
            "stdoutBytes": out.bytes, "stderrBytes": err.bytes, "stdoutPath": stdoutURL.path, "stderrPath": stderrURL.path,
            "truncated": out.bytes > capture.maxBytes || err.bytes > capture.maxBytes || stopReason == "byteLimit",
            "stopReason": stopReason, "terminatedByTool": terminatedByTool, "stillRunning": environment.isAlive(pid),
            "exitStatus": NSNull(), "osLog": capture.osLog, "seconds": capture.seconds,
            "note": "simctl does not report how the app ended (exitStatus is null); use last-crash. While the app runs it keeps writing to the files.",
        ]
        if let terminateError { result["terminateError"] = terminateError }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Lines that are not devicectl's own status lines.
    static func appLines(stdout: String, stderr: String) -> Int {
        let out = stdout.split(whereSeparator: \.isNewline).filter { line in
            !ConsoleCapture.devicectlStatusPrefixes.contains { line.hasPrefix($0) }
        }
        return out.count + stderr.split(whereSeparator: \.isNewline).count
    }

    static func executePhysical(_ capture: ConsoleCapture, directory: URL,
                                runner: StreamingToolRunner = StreamingToolRunner(),
                                launch: @Sendable ([String]) -> (executable: String, arguments: [String]) = { ("/usr/bin/xcrun", $0) }) async throws -> Data {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw CommandFailure(.hostRequirement, "Cannot create the console capture directory \(directory.path).", inputSent: .none)
        }
        let json = directory.appendingPathComponent("launch.json")
        let tails = Mutex((ConsoleTail(limit: capture.maxBytes), ConsoleTail(limit: capture.maxBytes)))
        let end: StreamingToolRunner.CaptureEnd
        do {
            let command = launch(capture.physicalArguments(json: json.path))
            end = try await runner.capture(executable: command.executable, arguments: command.arguments,
                environment: capture.environment, softDeadline: Double(capture.seconds), softSignal: SIGINT,
                hardDeadline: capture.hardDeadlineSeconds) { stream, data in
                tails.withLock { tails in
                    if stream == .output { tails.0.append(data) } else { tails.1.append(data) }
                    return tails.0.total + tails.1.total <= ConsoleCapture.rawBytesCeiling
                }
            }
        } catch let failure as CommandFailure {
            throw failure.inputPossiblySent()
        }
        let (out, err) = tails.withLock { $0 }
        var pid: Any = NSNull(), exitStatus: Any = NSNull(), outcome: Any = NSNull()
        if let data = try? Data(contentsOf: json), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            outcome = (object["info"] as? [String: Any])?["outcome"] ?? NSNull()
            let result = object["result"] as? [String: Any]
            pid = ((result?["process"] as? [String: Any])?["processIdentifier"]) ?? NSNull()
            if let termination = result?["terminationResult"] as? [String: Any] { exitStatus = termination }
        }
        let stopReason: String
        var toolExit: String?
        switch end {
        case .consumerStopped: stopReason = "byteLimit"
        case .softDeadline: stopReason = "duration"
        case .exited(let status):
            if !status.isSuccess {
                // devicectl also exits non-zero when the app it launched ends
                // abnormally, which is exactly the run a caller wants to read.
                // Only a launch that never happened is a tool failure.
                let launched = !(pid is NSNull) || out.text.contains(ConsoleCapture.launchedPrefix)
                guard launched else {
                    throw CommandFailure(.toolFailed, "devicectl failed (\(status)): \(err.text.isEmpty ? out.text : err.text)", inputSent: .unknown)
                }
                toolExit = "\(status)"
            }
            stopReason = "exited"
        }
        let observed = appLines(stdout: out.text, stderr: err.text) > 0
        var result: [String: Any] = [
            "platform": "physical", "device": capture.device, "operation": "console", "source": "devicectl-console",
            "bundleId": capture.bundle, "pid": pid, "stdoutTail": out.text, "stderrTail": err.text,
            "stdoutBytes": out.total, "stderrBytes": err.total, "truncated": out.truncated || err.truncated || stopReason == "byteLimit",
            "stopReason": stopReason, "terminatedByTool": stopReason != "exited", "exitStatus": exitStatus,
            "devicectlOutcome": outcome, "osLog": capture.osLog, "seconds": capture.seconds,
            "appOutputObserved": observed, "liveVerification": "one iPhone 13 mini", "launchJSON": json.path,
            "note": observed
                ? "stdout includes devicectl's own status lines. On the one phone checked, stdout, stderr and (with --os-log) mirrored log lines at info and above were bridged."
                : "No app output was captured: only devicectl's own status lines (if any) arrived. The app may simply have printed nothing in this window.",
        ]
        if !observed { result["captured"] = false }
        if let toolExit {
            result["devicectlExit"] = toolExit
            result["appEndedAbnormally"] = true
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
