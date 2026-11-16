import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

private let uuid = SimulatorDeviceTests.uuid

/// The diagnostics command a command line in the CLI's grammar builds.
private func diagnostics(_ command: [String]) throws -> AppDiagnosticsCommand {
    guard case .diagnostics(let diagnostics) = try request(command) else {
        throw CommandFailure(.internal, "not a diagnostics command", inputSent: .none)
    }
    return diagnostics
}

/// `logs` with these options on the fixture simulator.
private func logs(_ options: [String]) throws -> LogCapture {
    guard case .logs(let capture) = try diagnostics(["logs"] + options + ["--simulator", uuid]) else {
        throw CommandFailure(.internal, "not logs", inputSent: .none)
    }
    return capture
}

private func environment(_ state: String = "Booted") -> SimulatorEnvironment {
    SimulatorEnvironment(lookup: { _ in SimulatorDeviceTests.info(state) },
                         accessibility: { _, _ in throw CommandFailure(.internal, "no AX in these tests", inputSent: .none) })
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// One invented NDJSON log entry in `log --style ndjson` shape.
private func entry(_ message: String, level: String = "Default", pid: Int = 42, image: String = "/apps/Example.app/Example",
                   subsystem: String = "com.example.app", category: String = "network", eventType: String = "logEvent") -> String {
    let value: [String: Any] = ["timestamp": "2026-01-01 12:00:00.123456+0100", "messageType": level, "eventType": eventType,
                                "eventMessage": message, "subsystem": subsystem, "category": category, "processID": pid,
                                "processImagePath": image, "senderImagePath": "/apps/Example.app/Example", "threadID": 7]
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

struct LogCaptureParsingTests {
    @Test func streamDefaultsAndArguments() throws {
        let capture = try logs(["--seconds", "10", "--pid", "123"])
        #expect(capture.mode == .stream(seconds: 10) && capture.target == .pid(123))
        #expect(capture.level == .default && capture.maxEntries == 2000 && capture.maxBytes == 1024 * 1024)
        #expect(capture.hardDeadlineSeconds == 15)
        #expect(capture.arguments(predicate: capture.predicate(appPath: nil)) == ["simctl", "spawn", uuid, "log", "stream", "--style", "ndjson",
            "--level", "default", "--timeout", "10", "--predicate", "processID == 123"])
    }

    @Test func showModesUseLevelFlagsAndUTCWindows() throws {
        let last = try logs(["--last", "60", "--process", "Example", "--level", "debug"])
        #expect(last.arguments(predicate: "p") == ["simctl", "spawn", uuid, "log", "show", "--style", "ndjson", "--info", "--debug", "--last", "60s", "--predicate", "p"])
        #expect(last.hardDeadlineSeconds == 60)
        let range = try logs(["--start", "2026-01-01T12:00:00Z", "--end", "2026-01-01T13:05:00.5+01:00", "--bundle", "com.example.app", "--level", "info"])
        #expect(range.arguments(predicate: "p") == ["simctl", "spawn", uuid, "log", "show", "--style", "ndjson", "--info",
            "--start", "2026-01-01 12:00:00+0000", "--end", "2026-01-01 12:05:00+0000", "--predicate", "p"])
    }

    @Test(arguments: [
        [], ["--pid", "1"], ["--seconds", "5"], ["--seconds", "5", "--last", "5", "--pid", "1"], ["--seconds", "0", "--pid", "1"],
        ["--seconds", "61", "--pid", "1"], ["--last", "3601", "--pid", "1"], ["--seconds", "5", "--pid", "1", "--bundle", "a.b"],
        ["--seconds", "5", "--pid", "0"], ["--seconds", "5", "--pid", "1", "--category", "c"], ["--seconds", "5", "--pid", "1", "--level", "trace"],
        ["--seconds", "5", "--pid", "1", "--max-entries", "10001"], ["--seconds", "5", "--pid", "1", "--max-bytes", "100"],
        ["--seconds", "5", "--pid", "1", "--predicate", "TRUEPREDICATE"],
        ["--start", "yesterday", "--pid", "1"], ["--start", "2026-01-02T00:00:00Z", "--end", "2026-01-01T00:00:00Z", "--pid", "1"],
        ["--seconds", "5", "--end", "2026-01-01T00:00:00Z", "--pid", "1"], ["--seconds", "5", "--pid", "1", "extra"],
    ])
    func invalidCallsAreUsageErrors(_ operands: [String]) {
        #expect { try logs(operands) } throws: { ($0 as? CommandFailure)?.code == .usage }
    }

    @Test func physicalLogsAreUnsupportedAndSimulatorsNeedAUUID() throws {
        #expect { try diagnostics(["logs", "--seconds", "5", "--pid", "1", "--device", "phone"]) } throws: {
            ($0 as? CommandFailure)?.code == .unsupportedOperation && ($0 as? CommandFailure)?.inputSent == CommandFailure.InputSent.none
        }
        #expect { try diagnostics(["logs", "--seconds", "5", "--pid", "1", "--simulator", "booted"]) } throws: {
            ($0 as? CommandFailure)?.code == .usage
        }
        #expect(try simulatorInput(["tap", "0.5", "0.5", "--simulator", uuid])?.operation == "tap")
    }
}

struct LogPredicateTests {
    @Test func predicateCombinesValidatedFields() throws {
        let capture = try logs(["--seconds", "5", "--bundle", "com.example.app", "--subsystem", "com.example.app", "--category", "UI Events"])
        #expect(capture.predicate(appPath: "/sim/App.app") == #"processImagePath BEGINSWITH "/sim/App.app/" AND subsystem == "com.example.app" AND category == "UI Events""#)
        #expect(capture.predicate(appPath: nil).contains("<installed app path>/"))
        #expect(try logs(["--seconds", "5", "--process", "My App"]).predicate(appPath: nil) == #"process == "My App""#)
    }

    @Test(arguments: [
        ["--bundle", #"com.x" OR 1==1 OR "a"#], ["--bundle", "com.x\\"], ["--bundle", ".x"], ["--bundle", "com.exämple"],
        ["--process", #"a" OR "b"#], ["--process", "a\nb"], ["--process", "-a"],
        ["--subsystem", "a b"], ["--subsystem", #"a"OR"#],
    ])
    func injectionCharactersAreRefused(_ target: [String]) {
        let operands = ["--seconds", "5"] + (target[0] == "--subsystem" ? ["--pid", "1"] : []) + target
        #expect { try logs(operands) } throws: { ($0 as? CommandFailure)?.code == .usage }
    }

    @Test(arguments: [#"x" OR "1"#, "x\\", "x'y", "x\u{7}"])
    func categoryInjectionIsRefused(_ category: String) {
        #expect { try logs(["--seconds", "5", "--pid", "1", "--subsystem", "s", "--category", category]) } throws: {
            ($0 as? CommandFailure)?.code == .usage
        }
    }

    // Escaping is the second line of defence: a quoted value stays one literal.
    @Test func quotingKeepsAValueLiteral() {
        let value = #"a" OR subsystem == "b\"#
        let predicate = NSPredicate(format: "subsystem == \(LogCapture.quote(value))")
        #expect(predicate.evaluate(with: ["subsystem": value]))
        #expect(!predicate.evaluate(with: ["subsystem": "b"]))
    }
}

struct UnifiedLogReaderTests {
    private func reader(entries: Int = 100, bytes: Int = 1024 * 1024, filter: UnifiedLogReader.Filter = .init()) -> UnifiedLogReader {
        UnifiedLogReader(maxEntries: entries, maxBytes: bytes, filter: filter)
    }

    @Test func bannerIsSkippedEntriesNormalisedAndFinalRecordNoted() throws {
        var reader = reader()
        let text = "Filtering the log data using \"process == \"Example\"\"\n" + entry("hello", level: "Error") + "\n"
            + entry("act", eventType: "activityCreateEvent") + "\n{\"count\":2,\"finished\":1}\n"
        let kept = reader.feed(Data(text.utf8))
        #expect(kept)
        #expect(reader.entries.count == 1 && reader.finished && reader.reportedCount == 2)
        #expect(reader.skippedLines == 1 && reader.filteredOut == 1 && reader.receivedBytes == text.utf8.count)
        let first = try object(reader.entries[0])
        #expect(first["timestamp"] as? String == "2026-01-01T11:00:00.123456Z")
        #expect(first["level"] as? String == "error" && first["pid"] as? Int == 42 && first["process"] as? String == "Example")
        #expect(first["subsystem"] as? String == "com.example.app" && first["category"] as? String == "network")
        #expect(first["sender"] as? String == "Example" && first["message"] as? String == "hello")
        #expect(Set(first.keys) == ["timestamp", "level", "pid", "process", "subsystem", "category", "sender", "message"])
        #expect(reader.entryBytes == reader.entries[0].count + 1)
    }

    @Test func linesSplitAcrossChunksAndAFinalLineWithoutNewline() {
        var reader = reader()
        let line = entry("split")
        let half = line.utf8.count / 2
        let first = reader.feed(Data(line.utf8.prefix(half)))
        #expect(first && reader.entries.isEmpty)
        let second = reader.feed(Data(line.utf8.dropFirst(half)) + Data("\n".utf8) + Data(entry("tail").utf8))
        #expect(second)
        #expect(reader.entries.count == 1)
        reader.finish()
        #expect(reader.entries.count == 2 && reader.stopReason == nil)
    }

    @Test func entryLimitStopsAtTheEntryThatWouldExceedIt() {
        var reader = reader(entries: 3)
        let lines = (1...5).map { entry("m\($0)") }.joined(separator: "\n") + "\n"
        let kept = reader.feed(Data(lines.utf8))
        #expect(!kept && reader.entries.count == 3 && reader.stopReason == .entryLimit && reader.truncated)
        let late = reader.feed(Data((entry("late") + "\n").utf8))
        #expect(!late)
        #expect(reader.entries.count == 3)
    }

    @Test func exactlyTheLimitIsNotTruncated() {
        var reader = reader(entries: 2)
        let kept = reader.feed(Data((entry("a") + "\n" + entry("b") + "\n{\"count\":2,\"finished\":1}\n").utf8))
        #expect(kept && reader.entries.count == 2 && !reader.truncated && reader.finished)
    }

    @Test func byteLimitExcludesTheEntryThatWouldCrossIt() {
        var probe = reader()
        _ = probe.feed(Data((entry("x") + "\n").utf8))
        let one = probe.entryBytes
        var reader = reader(bytes: one * 2 + one / 2)
        let kept = reader.feed(Data((entry("x") + "\n" + entry("x") + "\n" + entry("x") + "\n").utf8))
        #expect(!kept && reader.entries.count == 2 && reader.entryBytes == one * 2 && reader.stopReason == .byteLimit)
    }

    @Test func anOversizedEntryAloneStopsTheCapture() {
        var reader = reader(bytes: 1024)
        let kept = reader.feed(Data((entry(String(repeating: "x", count: 4096)) + "\n").utf8))
        #expect(!kept && reader.entries.isEmpty && reader.stopReason == .byteLimit)
    }

    @Test func anEndlessLineIsBounded() {
        var reader = reader()
        reader.maximumLineBytes = 64
        let kept = reader.feed(Data(String(repeating: "{", count: 100).utf8))
        #expect(!kept && reader.stopReason == .byteLimit)
    }

    @Test func receivedBytesAreBoundedEvenWhenEverythingIsFilteredOut() {
        var reader = reader(filter: .init(pid: 1))
        reader.receivedBytesCeiling = 1000
        var more = true
        for _ in 0..<20 where more { more = reader.feed(Data((entry("other") + "\n").utf8)) }
        #expect(!more && reader.entries.isEmpty && reader.filteredOut > 0 && reader.stopReason == .byteLimit)
    }

    @Test func hostFilterDropsOtherProcessesSubsystemsAndCategories() {
        var reader = reader(filter: .init(imagePrefix: "/apps/Example.app/", subsystem: "com.example.app", category: "network"))
        let lines = [entry("keep"), entry("other app", image: "/apps/Other.app/Other"), entry("prefix trick", image: "/apps/Example.appX/E"),
                     entry("other subsystem", subsystem: "com.other"), entry("other category", category: "ui")].joined(separator: "\n") + "\n"
        let kept = reader.feed(Data(lines.utf8))
        #expect(kept && reader.entries.count == 1 && reader.filteredOut == 4)
        var byName = self.reader(filter: .init(pid: 42, process: "Example"))
        let keptByName = byName.feed(Data((entry("a") + "\n" + entry("b", pid: 7) + "\n" + entry("c", image: "/x/Other") + "\n").utf8))
        #expect(keptByName && byName.entries.count == 1)
    }

    @Test func noiseDiagnosticsAreNotFailures() {
        let text = "getpwuid_r did not find a match for uid 501\nlog: Bad predicate (x)\n"
        #expect(UnifiedLogExecution.diagnostics(Data(text.utf8)) == "log: Bad predicate (x)")
    }
}

/// Runs the real execution path with a shell script standing in for `log`.
@Suite(.timeLimit(.minutes(1)))
struct UnifiedLogExecutionTests {
    private func run(_ capture: LogCapture, script: String, appPath: String = "/apps/Example.app") async throws -> [String: Any] {
        try object(await UnifiedLogExecution.execute(capture, environment: environment(), run: { _ in Data((appPath + "\n").utf8) },
                                                    launch: { _ in ("/bin/sh", ["-c", script]) }))
    }

    private func quoted(_ lines: [String]) -> String {
        lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
    }

    @Test func aCompleteStreamReportsDuration() async throws {
        let capture = try logs(["--seconds", "5", "--bundle", "com.example.app"])
        let result = try await run(capture, script: quoted(["Filtering the log data", entry("one"), #"{"count":1,"finished":1}"#])
            + "; echo 'getpwuid_r did not find a match for uid 501' >&2")
        #expect(result["stopReason"] as? String == "duration" && result["truncated"] as? Bool == false)
        #expect(result["entryCount"] as? Int == 1 && result["toolReportedCount"] as? Int == 1 && result["source"] as? String == "simctl-log-stream")
        #expect(result["predicate"] as? String == #"processImagePath BEGINSWITH "/apps/Example.app/""#)
        #expect((result["entries"] as? [[String: Any]])?.first?["message"] as? String == "one")
    }

    @Test func showReportsComplete() async throws {
        let result = try await run(try logs(["--last", "60", "--pid", "42"]), script: quoted([entry("one"), #"{"count":1,"finished":1}"#]))
        #expect(result["stopReason"] as? String == "complete" && result["source"] as? String == "simctl-log-show")
    }

    @Test func badPredicateExitIsToolFailedWithNothingSent() async throws {
        await #expect {
            _ = try await run(try logs(["--seconds", "5", "--pid", "42"]), script: "echo 'log: Bad predicate (x)' >&2; exit 64")
        } throws: { error in
            guard let failure = error as? CommandFailure else { return false }
            return failure.code == .toolFailed && failure.inputSent == .none && failure.description.contains("Bad predicate")
        }
    }

    @Test func aStreamThatEndsWithoutItsFinalRecordIsNotASuccess() async throws {
        await #expect {
            _ = try await run(try logs(["--seconds", "5", "--pid", "42"]), script: quoted([entry("one")]))
        } throws: { ($0 as? CommandFailure)?.code == .toolFailed }
    }

    // An endless writer must be stopped by the entry limit, not by its deadline.
    @Test func aNoisyCaptureStopsAtTheEntryLimit() async throws {
        let start = ContinuousClock.now
        let line = entry("noise")
        let result = try await run(try logs(["--seconds", "60", "--pid", "42", "--max-entries", "3"]),
                                   script: "while :; do printf '%s\\n' '\(line)'; done")
        #expect(result["stopReason"] as? String == "entryLimit" && result["truncated"] as? Bool == true && result["entryCount"] as? Int == 3)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func outputFileGetsEveryEntryAndInlineKeepsTheNewest() async throws {
        let path = FileManager.default.currentDirectoryPath + "/tmp/logs-output-\(UUID().uuidString).ndjson"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = (1...60).map { entry("m\($0)") } + [#"{"count":60,"finished":1}"#]
        let result = try await run(try logs(["--seconds", "5", "--pid", "42", "--output", path]), script: quoted(lines))
        #expect(result["entryCount"] as? Int == 60 && result["inlineEntryCount"] as? Int == 50 && result["output"] as? String == path)
        #expect((result["entries"] as? [[String: Any]])?.first?["message"] as? String == "m11")
        let file = try String(contentsOfFile: path, encoding: .utf8)
        #expect(file.split(separator: "\n").count == 60)
        await #expect { _ = try await run(try logs(["--seconds", "5", "--pid", "42", "--output", path]), script: "true") } throws: {
            ($0 as? CommandFailure)?.code == .usage
        }
    }

    @Test func unbootedSimulatorAndMissingBundleAreRefusedBeforeCapture() async throws {
        await #expect {
            _ = try await UnifiedLogExecution.execute(try logs(["--seconds", "5", "--pid", "1"]), environment: environment("Shutdown"),
                run: { _ in Data() }, launch: { _ in Issue.record("captured"); return ("/usr/bin/true", []) })
        } throws: { ($0 as? CommandFailure)?.code == .deviceNotReady }
        await #expect {
            _ = try await UnifiedLogExecution.execute(try logs(["--seconds", "5", "--bundle", "com.example.missing"]), environment: environment(),
                run: { _ in throw CommandFailure(.toolFailed, "no", inputSent: .unknown) },
                launch: { _ in Issue.record("captured"); return ("/usr/bin/true", []) })
        } throws: { ($0 as? CommandFailure)?.code == .targetUnresolved && ($0 as? CommandFailure)?.inputSent == CommandFailure.InputSent.none }
    }
}

struct DiagnosticTimeTests {
    @Test func appleFormatsNormaliseToUTC() throws {
        #expect(DiagnosticTime.normalise("2026-11-15 21:18:02.202464+0100") == "2026-11-15T20:18:02.202464Z")
        #expect(DiagnosticTime.normalise("2026-11-15 21:21:29.00 +0100") == "2026-11-15T20:21:29.00Z")
        #expect(DiagnosticTime.normalise("2026-11-15 21:21:26.0887 -05:30") == "2026-11-16T02:51:26.0887Z")
        #expect(DiagnosticTime.normalise("not a date") == "not a date")
        let parsed = try #require(DiagnosticTime.parseApple("2026-01-01 00:00:00.5+0000"))
        #expect(parsed.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0.5)
        #expect(DiagnosticTime.logArgument(try #require(DiagnosticTime.parseISO8601("2026-01-01T01:02:03+02:00"))) == "2025-12-31 23:02:03+0000")
    }
}

// MARK: - Console

/// The console capture a `console` command line in the CLI's grammar builds.
private func console(_ command: [String]) throws -> ConsoleCapture {
    guard case .console(let capture) = try diagnostics(command) else { throw CommandFailure(.internal, "not console", inputSent: .none) }
    return capture
}

/// A fake simulator for the file-mode console: a launch that "writes" the
/// app's files and a process that lives for `aliveChecks` polls.
private final class FakeConsole: Sendable {
    struct State { var calls: [[String]] = []; var environments: [[String: String]] = []; var polls = 0; var terminated = false; var elapsed = 0.0 }
    let state = Mutex(State())
    let aliveChecks: Int
    let stdout: Data, stderr: Data

    init(aliveChecks: Int, stdout: String = "", stderr: String = "") {
        self.aliveChecks = aliveChecks; self.stdout = Data(stdout.utf8); self.stderr = Data(stderr.utf8)
    }

    func environment(state simulatorState: String = "Booted") -> ConsoleEnvironment {
        let base = ContinuousClock.now
        return ConsoleEnvironment(lookup: { _ in SimulatorDeviceTests.info(simulatorState) }, run: { args, env in
            self.state.withLock { $0.calls.append(args); $0.environments.append(env) }
            if args.dropFirst().first == "launch" {
                func path(_ prefix: String) -> String { String(args.first { $0.hasPrefix(prefix) }!.dropFirst(prefix.count)) }
                try self.stdout.write(to: URL(fileURLWithPath: path("--stdout=")))
                try self.stderr.write(to: URL(fileURLWithPath: path("--stderr=")))
                return Data("\(args[6]): 4242\n".utf8)
            }
            if args.dropFirst().first == "terminate" { self.state.withLock { $0.terminated = true } }
            return Data()
        }, isAlive: { _ in
            self.state.withLock { state in
                state.polls += 1
                return !state.terminated && state.polls <= self.aliveChecks
            }
        }, sleep: { duration in
            self.state.withLock { $0.elapsed += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        }, now: { base.advanced(by: .seconds(self.state.withLock { $0.elapsed })) })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConsoleCaptureTests {
    private let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/console-test-\(UUID().uuidString)")

    @Test func parsingKeepsAppArgumentsVerbatim() throws {
        let capture = try console(["console", "com.example.app", "--seconds", "5", "--os-log", "--simulator", uuid, "--", "-flag", "--seconds", "$(x)"])
        #expect(capture.bundle == "com.example.app" && capture.seconds == 5 && capture.osLog && !capture.terminate)
        #expect(capture.appArguments == ["-flag", "--seconds", "$(x)"])
        #expect(capture.environment == ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "enable"])
        #expect(capture.simulatorArguments(stdout: "/o", stderr: "/e") == ["simctl", "launch", "--terminate-running-process",
            "--stdout=/o", "--stderr=/e", uuid, "com.example.app", "-flag", "--seconds", "$(x)"])
        let physical = try console(["console", "com.example.app", "--seconds", "10", "--os-log", "--terminate", "--device", "phone"])
        #expect(physical.environment == ["DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE": "enable"])
        #expect(physical.physicalArguments(json: "/j") == ["devicectl", "device", "process", "launch", "--device", "phone", "--console",
            "--terminate-existing", "--timeout", "70", "--json-output", "/j", "com.example.app"])
        #expect(physical.hardDeadlineSeconds == 30)
        #expect(try console(["console", "a.b", "--seconds", "1", "--simulator", uuid]).environment.isEmpty)
    }

    @Test(arguments: [["com.example.app"], ["com.example.app", "--seconds", "0"], ["com.example.app", "--seconds", "61"], ["--seconds", "5"],
                      ["a\"b", "--seconds", "5"], ["a.b", "c.d", "--seconds", "5"], ["a.b", "--seconds", "5", "--max-bytes", "10"],
                      ["a.b", "--seconds", "5", "--follow"]])
    func invalidConsoleCallsAreUsageErrors(_ operands: [String]) {
        #expect { try console(["console"] + operands + ["--simulator", uuid]) } throws: { ($0 as? CommandFailure)?.code == .usage }
    }

    @Test func launchOutputGivesThePID() {
        #expect(AppConsole.launchedPID(Data("com.example.app: 4242\n".utf8), bundle: "com.example.app") == 4242)
        #expect(AppConsole.launchedPID(Data("other.app: 1\n".utf8), bundle: "com.example.app") == nil)
        #expect(AppConsole.launchedPID(Data("com.example.app: x\n".utf8), bundle: "com.example.app") == nil)
    }

    @Test func tailsKeepTheNewestBytesAndDropABrokenLeadingCharacter() throws {
        var tail = ConsoleTail(limit: 4)
        for chunk in ["ab", "cdé", "fgh"] { tail.append(Data(chunk.utf8)) }
        #expect(tail.text == "fgh" && tail.total == 9 && tail.truncated)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f")
        try Data("0123456789".utf8).write(to: file)
        #expect(ConsoleTail.read(file, limit: 4) == ("6789", 10))
        #expect(ConsoleTail.read(directory.appendingPathComponent("missing"), limit: 4) == ("", 0))
    }

    @Test func appExitEndsTheWaitAndTheResultIsHonestAboutExitStatus() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeConsole(aliveChecks: 2, stdout: "out line\n", stderr: "err line\n")
        let capture = try console(["console", "com.example.app", "--seconds", "5", "--os-log", "--simulator", uuid])
        let result = try object(await AppConsole.executeSimulator(capture, directory: directory, environment: fake.environment()))
        #expect(result["stopReason"] as? String == "exited" && result["pid"] as? Int == 4242 && result["exitStatus"] is NSNull)
        #expect(result["stdoutTail"] as? String == "out line\n" && result["stderrTail"] as? String == "err line\n")
        #expect(result["terminatedByTool"] as? Bool == false && result["truncated"] as? Bool == false)
        #expect(fake.state.withLock { $0.environments.first } == ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "enable"])
    }

    @Test func durationLeavesTheAppRunningUnlessTerminateIsGiven() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = FakeConsole(aliveChecks: 1000, stdout: String(repeating: "x", count: 2000))
        let kept = try object(await AppConsole.executeSimulator(try console(["console", "a.b", "--seconds", "2", "--max-bytes", "1024", "--simulator", uuid]),
                                                                directory: directory, environment: keep.environment()))
        #expect(kept["stopReason"] as? String == "duration" && kept["stillRunning"] as? Bool == true && kept["terminatedByTool"] as? Bool == false)
        #expect(kept["truncated"] as? Bool == true && kept["stdoutBytes"] as? Int == 2000 && (kept["stdoutTail"] as? String)?.count == 1024)
        #expect(!keep.state.withLock { $0.calls.contains { $0.contains("terminate") } })
        let stop = FakeConsole(aliveChecks: 1000)
        let stopped = try object(await AppConsole.executeSimulator(try console(["console", "a.b", "--seconds", "1", "--terminate", "--simulator", uuid]),
                                                                   directory: directory, environment: stop.environment()))
        #expect(stopped["terminatedByTool"] as? Bool == true && stopped["stillRunning"] as? Bool == false)
        #expect(stop.state.withLock { $0.calls.last } == ["simctl", "terminate", uuid, "a.b"])
    }

    @Test func unbootedSimulatorIsRefusedBeforeLaunch() async throws {
        let fake = FakeConsole(aliveChecks: 0)
        await #expect {
            _ = try await AppConsole.executeSimulator(try console(["console", "a.b", "--seconds", "1", "--simulator", uuid]),
                                                      directory: directory, environment: fake.environment(state: "Shutdown"))
        } throws: { ($0 as? CommandFailure)?.code == .deviceNotReady }
        #expect(fake.state.withLock { $0.calls.isEmpty })
    }

    @Test func devicectlStatusLinesAreNotAppOutput() {
        let status = "Launched application with a.b bundle identifier.\nWaiting for the application to terminate…\nApp terminated due to signal 2.\n"
        #expect(AppConsole.appLines(stdout: status, stderr: "") == 0)
        #expect(AppConsole.appLines(stdout: status + "hello\n", stderr: "") == 1)
        #expect(AppConsole.appLines(stdout: status, stderr: "e\n") == 1)
    }

    // A stand-in for devicectl that prints only its own status lines and
    // exits when interrupted, as the one phone run did.
    @Test func physicalConsoleIsHonestWhenOnlyStatusLinesArrive() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try console(["console", "a.b", "--seconds", "1", "--device", "phone"])
        let script = "trap 'echo \"App terminated due to signal 2.\"; exit 0' INT; echo 'Launched application with a.b bundle identifier.'; while :; do /bin/sleep 0.05; done"
        let result = try object(await AppConsole.executePhysical(capture, directory: directory, launch: { _ in ("/bin/sh", ["-c", script]) }))
        #expect(result["stopReason"] as? String == "duration" && result["terminatedByTool"] as? Bool == true)
        #expect(result["appOutputObserved"] as? Bool == false && result["captured"] as? Bool == false)
        #expect((result["note"] as? String)?.contains("No app output was captured") == true)
        #expect(result["pid"] is NSNull && result["exitStatus"] is NSNull)
        #expect(result["appEndedAbnormally"] == nil)
    }

    // Observed on a phone: when the launched app aborts, devicectl exits 1.
    // That run's output is the answer, not a tool failure.
    @Test func physicalConsoleReturnsTheOutputOfAnAppThatCrashed() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try console(["console", "a.b", "--seconds", "5", "--device", "phone"])
        let script = "echo 'Launched application with a.b bundle identifier.'; echo 'stdout K1'; echo 'stderr K1' >&2; exit 1"
        let result = try object(await AppConsole.executePhysical(capture, directory: directory, launch: { _ in ("/bin/sh", ["-c", script]) }))
        #expect(result["stopReason"] as? String == "exited" && result["terminatedByTool"] as? Bool == false)
        #expect(result["appEndedAbnormally"] as? Bool == true && (result["devicectlExit"] as? String)?.isEmpty == false)
        #expect((result["stdoutTail"] as? String)?.contains("stdout K1") == true && (result["stderrTail"] as? String)?.contains("stderr K1") == true)
        #expect(result["appOutputObserved"] as? Bool == true)
    }

    // A launch that never happened is still a failure of the tool.
    @Test func physicalConsoleFailsWhenNothingWasLaunched() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try console(["console", "a.b", "--seconds", "5", "--device", "phone"])
        await #expect(throws: CommandFailure.self) {
            _ = try await AppConsole.executePhysical(capture, directory: directory, launch: { _ in ("/bin/sh", ["-c", "echo 'no such device' >&2; exit 1"]) })
        }
    }

    @Test func physicalConsoleReportsAppOutputAndAFailedLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try console(["console", "a.b", "--seconds", "5", "--device", "phone"])
        let result = try object(await AppConsole.executePhysical(capture, directory: directory,
            launch: { _ in ("/bin/sh", ["-c", "echo 'Launched application with a.b bundle identifier.'; echo app-line; echo app-err >&2"]) }))
        #expect(result["stopReason"] as? String == "exited" && result["appOutputObserved"] as? Bool == true && result["captured"] == nil)
        #expect(result["stderrTail"] as? String == "app-err\n")
        await #expect {
            _ = try await AppConsole.executePhysical(capture, directory: directory, launch: { _ in ("/bin/sh", ["-c", "echo 'not installed' >&2; exit 1"]) })
        } throws: { ($0 as? CommandFailure)?.code == .toolFailed && ($0 as? CommandFailure)?.inputSent == .unknown }
    }
}

// MARK: - Crash reports

/// An invented two-part `.ips` report; no real report is stored in the repository.
func fixtureReport(bundle: String = "com.example.app", name: String = "Example", platform: Int = 7, bugType: String = "309",
                   timestamp: String = "2026-01-01 12:00:00.00 +0000",
                   procPath: String = "/Sim/Devices/11111111-2222-3333-4444-555555555555/data/Containers/Bundle/Application/X/Example.app/Example") -> Data {
    let header: [String: Any] = ["app_name": name, "name": name, "bundleID": bundle, "bug_type": bugType, "platform": platform,
                                 "os_version": "macOS 99.0 (00A000)", "timestamp": timestamp, "incident_id": "00000000-0000-0000-0000-000000000001"]
    let body: [String: Any] = [
        "procName": name, "pid": 4242, "procPath": procPath, "captureTime": "2026-01-01 11:59:59.5000 +0000",
        "exception": ["type": "EXC_CRASH", "signal": "SIGABRT", "codes": "0x0, 0x0"],
        "termination": ["namespace": "SIGNAL", "code": 6, "indicator": "Abort trap: 6", "byProc": name],
        "faultingThread": 1,
        "asi": ["libswiftCore.dylib": ["Fatal error: invented message"]],
        "threads": [["frames": [["imageIndex": 0, "imageOffset": 1]]],
                    ["queue": "com.apple.main-thread", "frames": (0..<20).map { ["imageIndex": $0 % 2, "imageOffset": 100 + $0, "symbol": "f\($0)", "symbolLocation": 4] }
                        + [["imageIndex": 9, "imageOffset": 7]]]],
        "usedImages": [["name": "libsystem_kernel.dylib"], ["name": name]],
        "lastExceptionBacktrace": [["imageIndex": 1, "imageOffset": 55]],
    ]
    var data = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    data.append(10)
    data.append(try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]))
    return data
}

/// `last-crash` with these options on a physical `device`, or else on the fixture simulator.
private func crashQuery(_ options: [String], device: String? = nil) throws -> LastCrashQuery {
    let target = device.map { ["--device", $0] } ?? ["--simulator", uuid]
    guard case .lastCrash(let query) = try diagnostics(["last-crash"] + options + target) else {
        throw CommandFailure(.internal, "not last-crash", inputSent: .none)
    }
    return query
}

@Suite(.dedicatedThread)
struct CrashReportTests {
    @Test func summaryCarriesExceptionTerminationMessagesAndTopFrames() throws {
        let summary = try IPSReport(fixtureReport()).summary()
        #expect(summary["found"] as? Bool == true && summary["bundleId"] as? String == "com.example.app" && summary["pid"] as? Int == 4242)
        #expect(summary["exceptionType"] as? String == "EXC_CRASH" && summary["signal"] as? String == "SIGABRT")
        #expect(summary["terminationReason"] as? String == "Abort trap: 6" && summary["platformCode"] as? Int == 7)
        #expect(summary["timestamp"] as? String == "2026-01-01T12:00:00.00Z" && summary["captureTime"] as? String == "2026-01-01T11:59:59.5000Z")
        #expect(summary["crashMessages"] as? [String] == ["Fatal error: invented message"] && summary["symbolicated"] as? Bool == false)
        let thread = try #require(summary["faultingThread"] as? [String: Any])
        let frames = try #require(thread["frames"] as? [[String: Any]])
        #expect(thread["index"] as? Int == 1 && thread["queue"] as? String == "com.apple.main-thread" && thread["frameCount"] as? Int == 21)
        #expect(frames.count == LastCrashQuery.maxFrames)
        #expect(frames[1]["image"] as? String == "Example" && frames[1]["symbol"] as? String == "f1" && frames[1]["imageOffset"] as? Int == 101)
        #expect((summary["lastExceptionBacktrace"] as? [[String: Any]])?.first?["image"] as? String == "Example")
        let unknownImage = try IPSReport(fixtureReport()).summary(maxFrames: 30)
        #expect(((unknownImage["faultingThread"] as? [String: Any])?["frames"] as? [[String: Any]])?.last?["image"] is NSNull)
    }

    @Test func malformedReportsAreRejected() {
        #expect(throws: CommandFailure.self) { try IPSReport(Data("not json\n{}".utf8)) }
        #expect(throws: CommandFailure.self) { try IPSReport(Data("{\"bug_type\":\"309\"}\n[1]".utf8)) }
        #expect(throws: CommandFailure.self) { try IPSReport(Data("{\"bug_type\":\"309\"}".utf8)) }
    }

    @Test func procPathTiesAReportToOneSimulator() throws {
        #expect(try IPSReport(fixtureReport()).simulatorMatch(uuid) == true)
        #expect(try IPSReport(fixtureReport(procPath: "/Sim/Devices/AAAAAAAA-2222-3333-4444-555555555555/data/X")).simulatorMatch(uuid) == false)
        #expect(try IPSReport(fixtureReport(procPath: "/Volumes/VOLUME/*/Example.app/Example")).simulatorMatch(uuid) == nil)
    }

    @Test func parsingNeedsExactlyOneTarget() throws {
        let query = try crashQuery(["--bundle", "com.example.app", "--since", "2026-01-01T00:00:00Z"])
        #expect(query.bundle == "com.example.app" && query.process == nil && query.since != nil && !query.physical)
        for bad in [[], ["--bundle", "a.b", "--process", "A"], ["--since", "2026-01-01T00:00:00Z"], ["--bundle", "a\"b"], ["--bundle", "a.b", "--since", "now"]] {
            #expect { try crashQuery(bad) } throws: { ($0 as? CommandFailure)?.code == .usage }
        }
    }

    @Test func simulatorSelectionFiltersByPlatformBundleDeviceAndTime() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/crash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files: [(String, Data)] = [
            ("Example-old.ips", fixtureReport(timestamp: "2026-01-01 09:00:00.00 +0000")),
            ("Example-new.ips", fixtureReport(timestamp: "2026-01-01 12:00:00.00 +0000")),
            ("Example-phone.ips", fixtureReport(platform: 2, timestamp: "2026-01-01 13:00:00.00 +0000")),
            ("Example-other-sim.ips", fixtureReport(timestamp: "2026-01-01 14:00:00.00 +0000", procPath: "/Sim/Devices/AAAAAAAA-2222-3333-4444-555555555555/data/E")),
            ("Example-hang.ips", fixtureReport(bugType: "288", timestamp: "2026-01-01 15:00:00.00 +0000")),
            ("Other-app.ips", fixtureReport(bundle: "com.other.app", name: "Other", timestamp: "2026-01-01 16:00:00.00 +0000")),
            ("Example-notes.txt", fixtureReport(timestamp: "2026-01-01 17:00:00.00 +0000")),
        ]
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        let byBundle = try #require(try CrashReportSelection.simulator(try crashQuery(["--bundle", "com.example.app"]), directory: directory))
        #expect(byBundle.url.lastPathComponent == "Example-new.ips" && byBundle.deviceMatch == true)
        let byProcess = try #require(try CrashReportSelection.simulator(try crashQuery(["--process", "Example"]), directory: directory))
        #expect(byProcess.url.lastPathComponent == "Example-new.ips")
        let since = try crashQuery(["--bundle", "com.example.app", "--since", "2026-01-01T12:30:00Z"])
        #expect(try CrashReportSelection.simulator(since, directory: directory) == nil)
        #expect(try CrashReportSelection.simulator(try crashQuery(["--bundle", "com.none"]), directory: directory) == nil)
    }

    @Test func deviceListingCandidatesAreFilteredAndNewestFirst() throws {
        func file(_ name: String, _ date: String, directory: Bool = false, bugType: String? = nil) -> [String: Any] {
            ["name": name, "relativePath": name, "metadata": ["lastModDate": date, "extendedAttributes": bugType.map { ["bug_type": $0] } ?? [:]],
             "resources": ["isDirectory": directory]]
        }
        let listing = try JSONSerialization.data(withJSONObject: ["result": ["files": [
            file("Example-2026-01-01-100000.ips", "2026-01-01T10:00:00.000Z"),
            file("Example-2026-01-01-120000.ips", "2026-01-01T12:00:00.000Z", bugType: "309"),
            file("Example-2026-01-01-130000.ips", "2026-01-01T13:00:00.000Z", bugType: "288"),
            file("Example-dir.ips", "2026-01-01T14:00:00.000Z", directory: true),
            file("Analytics-2026-01-01.ips.ca.synced", "2026-01-01T15:00:00.000Z"),
            file("Other-2026-01-01-110000.ips", "2026-01-01T11:00:00.000Z"),
        ]]])
        let all = try CrashReportSelection.deviceCandidates(listing, query: try crashQuery(["--bundle", "com.example.app"], device: "phone"))
        #expect(all == ["Example-2026-01-01-120000.ips", "Other-2026-01-01-110000.ips", "Example-2026-01-01-100000.ips"])
        let named = try CrashReportSelection.deviceCandidates(listing, query: try crashQuery(["--process", "Example", "--since", "2026-01-01T11:00:00Z"],
                                                                                            device: "phone"))
        #expect(named == ["Example-2026-01-01-120000.ips"])
        #expect(throws: CommandFailure.self) { try CrashReportSelection.deviceCandidates(Data("{}".utf8), query: try crashQuery(["--process", "E"], device: "phone")) }
    }

    @Test func physicalSelectionDownloadsUntilAHeaderMatchesAndDeletesTheRest() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/crash-phone-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let listing = try JSONSerialization.data(withJSONObject: ["result": ["files": [
            ["name": "Other-1.ips", "metadata": ["lastModDate": "2026-01-01T12:00:00.000Z"]],
            ["name": "Example-1.ips", "metadata": ["lastModDate": "2026-01-01T11:00:00.000Z"]],
        ]]])
        let reports = ["Other-1.ips": fixtureReport(bundle: "com.other.app", name: "Other", platform: 2),
                       "Example-1.ips": fixtureReport(platform: 2, procPath: "/private/var/containers/Bundle/Application/X/Example.app/Example")]
        let calls = Mutex<[[String]]>([])
        let query = try crashQuery(["--bundle", "com.example.app"], device: "phone")
        let result = try object(try CrashReportSelection.executePhysical(query, directory: directory) { plan in
            calls.withLock { $0.append(plan.arguments) }
            if plan.arguments.contains("info") { return listing }
            let source = plan.arguments[plan.arguments.firstIndex(of: "--source")! + 1]
            let destination = plan.arguments[plan.arguments.firstIndex(of: "--destination")! + 1]
            try reports[source]!.write(to: URL(fileURLWithPath: destination))
            return Data("{}".utf8)
        })
        #expect(result["found"] as? Bool == true && result["remotePath"] as? String == "Example-1.ips" && result["platform"] as? String == "physical")
        #expect(result["candidatesConsidered"] as? Int == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Other-1.ips").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Example-1.ips").path))
        #expect(calls.withLock { $0.count } == 3)
        let none = try object(try CrashReportSelection.executePhysical(try crashQuery(["--process", "Nothing"], device: "phone"),
                                                                       directory: directory) { _ in listing })
        #expect(none["found"] as? Bool == false && none["candidatesListed"] as? Int == 0)
    }
}

// MARK: - Service and MCP

struct AppDiagnosticsServiceTests {
    private func service() throws -> CommandService {
        CommandService(leases: try SimulatorAccessibilityTests.unusableLeases(), simulator: SimulatorEnvironment(
            lookup: { _ in Issue.record("Dry run looked the simulator up"); return SimulatorDeviceTests.info() },
            accessibility: { _, _ in throw CommandFailure(.internal, "no", inputSent: .none) }),
            readinessQuery: { _ in Issue.record("Dry run queried CoreDevice"); return Data() })
    }

    @Test func dryRunsPlanWithoutContactingAnything() async throws {
        let logsPlan = try object(await service().run(["logs", "--seconds", "10", "--bundle", "com.example.app", "--simulator", uuid], dryRun: true).data)
        #expect(logsPlan["readOnly"] as? Bool == true && logsPlan["source"] as? String == "simctl-log-stream")
        #expect((logsPlan["bounds"] as? [String: Any])?["hardDeadlineSeconds"] as? Double == 15)
        #expect(((logsPlan["targetResolution"] as? [String: Any])?["query"] as? [String: Any])?["arguments"] as? [String] == ["simctl", "get_app_container", uuid, "com.example.app", "app"])
        let consolePlan = try object(await service().run(["console", "com.example.app", "--seconds", "5", "--device", "phone"], dryRun: true).data)
        #expect(consolePlan["liveVerification"] as? String == "one iPhone 13 mini" && consolePlan["readOnly"] as? Bool == false && (consolePlan["execution"] as? String)?.contains("forwards to the app") == true)
        let simConsole = try object(await service().run(["console", "com.example.app", "--seconds", "5", "--simulator", uuid], dryRun: true).data)
        #expect((simConsole["arguments"] as? [String])?.prefix(3) == ["simctl", "launch", "--terminate-running-process"])
        let crash = try object(await service().run(["last-crash", "--process", "Example", "--device", "phone"], dryRun: true).data)
        #expect((crash["listing"] as? [String: Any])?["arguments"] as? [String] == ["devicectl", "device", "info", "files", "--domain-type", "systemCrashLogs",
            "--subdirectory", ".", "--no-recurse", "--device", "phone", "--timeout", "60", "--json-output", "-"])
    }

    @Test func readOnlyClassification() throws {
        let logs = ["logs", "--seconds", "5", "--pid", "1", "--simulator", uuid]
        #expect(try request(logs).isReadOnly)
        #expect(try request(["last-crash", "--process", "E", "--device", "phone"]).isReadOnly)
        #expect(try !request(["console", "a.b", "--seconds", "5", "--simulator", uuid]).isReadOnly)
        #expect(try request(logs).signalContext == "app output capture")
        #expect(try request(["console", "a.b", "--seconds", "5", "--device", "phone"]).signalContext == "app output capture")
        #expect(try request(["last-crash", "--process", "E", "--simulator", uuid]).signalContext == nil)
        // main.swift leaves a dry run outside the signal scope.
        #expect(try CLI.invocation(logs + ["--dry-run"]).dryRun)
    }

    @Test func physicalLogsFailAsUnsupportedWithNothingSent() async {
        await #expect { _ = try await service().run(["logs", "--seconds", "5", "--pid", "1", "--device", "phone"]) } throws: {
            ($0 as? CommandFailure)?.code == .unsupportedOperation && ($0 as? CommandFailure)?.inputSent == CommandFailure.InputSent.none
        }
    }
}

struct AppDiagnosticsMCPTests {
    private func tool(_ name: String) throws -> MCPToolDefinition { try #require(MCPTools.definitions.first { $0.name == name }) }

    @Test func toolsAreAnnotatedAndRouteToTheCLI() throws {
        let readOnly = try ["capture_logs", "latest_crash", "capture_console"].map { try tool($0).readOnly }
        #expect(readOnly == [true, true, false])
        let logArgs = try tool("capture_logs").command(["device": .string(uuid), "seconds": 10, "bundle_id": "com.example.app", "level": "debug",
                                                        "subsystem": "com.example.app", "category": "probe", "max_entries": 3])
        #expect(logArgs == ["logs", "--simulator=\(uuid)", "--seconds=10", "--max-entries=3", "--bundle=com.example.app",
                            "--subsystem=com.example.app", "--category=probe", "--level=debug"])
        guard case .logs(let parsed) = try diagnostics(logArgs) else { Issue.record("not logs"); return }
        #expect(parsed.maxEntries == 3 && parsed.level == .debug)
        let consoleArgs = try tool("capture_console").command(["platform": "simulator", "device": .string(uuid), "bundle_id": "a.b", "seconds": 5,
                                                               "os_log": true, "terminate": false, "app_arguments": ["-probeLogToken", "T1"]])
        #expect(consoleArgs == ["console", "--simulator=\(uuid)", "--seconds=5", "--os-log", "a.b", "--", "-probeLogToken", "T1"])
        #expect(summary(try request(consoleArgs)) == ["simulator", uuid, "console", "a.b", "--seconds", "5", "--os-log", "--", "-probeLogToken", "T1"])
        guard case .console(let consoleParsed) = try diagnostics(consoleArgs) else { Issue.record("not console"); return }
        #expect(consoleParsed.appArguments == ["-probeLogToken", "T1"])
        let crashArgs = try tool("latest_crash").command(["platform": "physical", "device": "phone", "process": "Example", "since": "2026-01-01T00:00:00Z"])
        #expect(crashArgs == ["last-crash", "--device=phone", "--process=Example", "--since=2026-01-01T00:00:00Z"])
        #expect(summary(try request(crashArgs)) == ["physical", "phone", "last-crash", "--process", "Example", "--since", "2026-01-01T00:00:00Z"])
    }

    @Test func schemasRejectWrongTypes() throws {
        let schema = try #require(try tool("capture_console").tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(schema["app_arguments"]?.objectValue?["type"] == "array")
        #expect(schema["app_arguments"]?.objectValue?["items"]?.objectValue?["type"] == "string")
        #expect(throws: MCPError.self) { try tool("capture_console").command(["platform": "simulator", "device": "d", "bundle_id": "a.b", "seconds": 5, "app_arguments": [1]]) }
        #expect(throws: MCPError.self) { try tool("capture_logs").command(["device": "d", "seconds": 1.5]) }
        #expect(throws: MCPError.self) { try tool("capture_logs").command(["device": "d", "predicate": "TRUEPREDICATE"]) }
        #expect(throws: MCPError.self) { try tool("latest_crash").command(["device": "d", "process": "E"]) }
    }
}
