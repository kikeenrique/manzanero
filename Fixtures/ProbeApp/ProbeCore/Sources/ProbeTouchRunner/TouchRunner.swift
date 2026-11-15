import Foundation
import ProbeAnalysis
import ProbeCore

/// One Manzanero invocation as recorded in `run.json`.
public struct StepRecord: Codable, Sendable, Equatable {
    public var index: Int
    public var label: String
    /// The full argument vector, executable first.
    public var arguments: [String]
    public var exitCode: Int32?
    public var timedOut: Bool
    /// Host seconds the command took (informational; never compared with device time).
    public var elapsedSeconds: Double
    public var stdoutFile: String?
    public var stderrFile: String?
    /// The invocation itself failed (for example the executable is missing).
    public var error: String?
}

public struct StopRecord: Codable, Sendable, Equatable {
    public var reason: String
    /// Index of the step after which the runner stopped.
    public var afterStep: Int
}

public struct PullRecord: Codable, Sendable, Equatable {
    public var exitCode: Int32?
    /// Local path of the pulled log, relative to the working directory.
    public var path: String?
    public var bytes: Int?
    public var error: String?
}

/// Everything the runner did and saw, written to `run.json` after every step so an
/// interrupted run still leaves evidence. `probe-touch compare` rebuilds the report from it.
public struct RunRecord: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public var v = RunRecord.formatVersion
    public var device: String
    public var plan: TouchPlan
    public var repeatCount: Int
    public var readback: ReadbackMode
    public var settleSeconds: Double
    public var bundleID: String
    public var manzanero: String
    /// Host wall clock at start, ISO 8601 (informational).
    public var startedAt: String
    public var reset: Bool
    public var preflight: ProbeReadback?
    public var baseline: ProbeReadback?
    public var attempts: [ActionAttempt] = []
    public var steps: [StepRecord] = []
    public var stop: StopRecord?
    public var pull: PullRecord?
    public var completed = false
    public var deviceStateLeft: [String] = []
}

public final class TouchRunner {
    public struct Outcome {
        public var exitCode: Int32
        /// Text for stdout.
        public var output: String
        public var directory: String?
        public var record: RunRecord?
        public var report: TouchReport?
    }

    /// Exit statuses: 0 all actions sent, 2 usage, plan or dry-run check error, 3 stopped early.
    public static let exitStopped: Int32 = 3
    public static let exitUsage: Int32 = 2
    public static let logRemotePath = "Documents/touch-log.jsonl"
    public static let maximumConsecutiveDispatchFailures = 3

    let options: RunOptions
    let invoker: ManzaneroInvoking
    let fs: RunnerFileSystem
    let clock: RunnerClock
    let progress: (String) -> Void

    public init(options: RunOptions, invoker: ManzaneroInvoking, fileSystem: RunnerFileSystem, clock: RunnerClock,
                progress: @escaping (String) -> Void = { _ in }) {
        self.options = options
        self.invoker = invoker
        fs = fileSystem
        self.clock = clock
        self.progress = progress
    }

    // MARK: Plan

    public func loadPlan() throws -> (TouchPlan, PlanValidation) {
        let plan: TouchPlan
        if let path = options.planPath {
            do { plan = try TouchPlan.decode(fs.read(path)) } catch {
                throw RunnerError("cannot read plan \(path): \(error)")
            }
        } else {
            plan = .builtIn
        }
        return (plan, plan.validate())
    }

    func attempts(for plan: TouchPlan) -> [ActionAttempt] {
        var list: [ActionAttempt] = []
        for round in 1...options.repeatCount {
            for planned in plan.actions {
                list.append(ActionAttempt(sequence: list.count + 1, round: round, planned: planned,
                                          dispatch: DispatchOutcome(state: .notSent), readback: nil))
            }
        }
        return list
    }

    func settle(_ plan: TouchPlan) -> Double { options.settleOverride ?? plan.settle }

    var treeArguments: [String] { [options.platform, options.device, "tree"] }
    var resetArguments: [String] { [options.platform, options.device, "press-id", ProbeTree.resetIdentifier] }
    func actionArguments(_ action: TouchAction) -> [String] { [options.platform, options.device] + action.cliArguments }
    func pullArguments(destination: String) -> [String] {
        ["physical", options.device, "pull", options.bundleID, Self.logRemotePath, destination]
    }

    public func execute() -> Outcome {
        let plan: TouchPlan
        let validation: PlanValidation
        do { (plan, validation) = try loadPlan() } catch {
            return Outcome(exitCode: Self.exitUsage, output: "\(error)\n")
        }
        guard validation.isValid else {
            return Outcome(exitCode: Self.exitUsage, output: "Plan \(plan.name) is invalid; nothing was sent:\n"
                + validation.errors.map { "  - \($0)\n" }.joined())
        }
        return options.dryRun ? dryRun(plan, validation) : run(plan, validation)
    }

    // MARK: Dry run

    func dryRun(_ plan: TouchPlan, _ validation: PlanValidation) -> Outcome {
        let m = options.manzanero
        let attempts = attempts(for: plan)
        let settle = settle(plan)
        var lines: [String] = []
        lines.append("probe-touch dry run: no device contacted")
        lines.append("Device: \(options.device)")
        if options.platform != "physical" {
            lines.append("Platform: \(options.platform); no log pull, the readouts are the evidence")
        }
        lines.append("Plan: \(plan.name), \(plan.actions.count) action(s) x \(options.repeatCount) = \(attempts.count) sent action(s)")
        lines.append("Readback: \(options.readback.rawValue); settle \(formatCLINumber(settle)) s before each readback")
        lines.append("Tolerances: position \(formatCLINumber(plan.tolerances.position)) (normalised), hold \(formatCLINumber(plan.tolerances.duration)) s")
        lines.append("Bundle identifier for the pull: \(options.bundleID)")
        lines.append("Run directory on a live run: \(options.outputDirectory ?? "tmp/probe-touch/<yyyyMMdd-HHmmss>")")
        let contactSeconds = attempts.reduce(0) { $0 + $1.planned.action.scheduledSeconds }
        lines.append(String(format: "Scheduled contact time: %.2f s, plus the readbacks and settle pauses", contactSeconds))
        for warning in validation.warnings { lines.append("Warning: \(warning)") }
        lines.append("")
        lines.append("Steps:")
        var n = 0
        func step(_ text: String, _ arguments: [String]?) {
            n += 1
            lines.append("  \(n). \(text)")
            if let arguments { lines.append("       " + shellQuoted([m] + arguments)) }
        }
        step("preflight readback: stop unless probe.touch.summary is present, portrait, with no contact down, and owned by \(options.bundleID) when the tree reports nativeAttributes \(ProbeTree.bundleIDAttribute)", treeArguments)
        if options.reset {
            step("reset the probe through accessibility (no touch); stop unless the receipt is accepted", resetArguments)
            step("baseline readback: stop unless the session changed, no contact is down and the identity holds", treeArguments)
        }
        for (index, attempt) in attempts.enumerated() {
            let action = attempt.planned.action
            let expected = action.expectedGestures
            let contacts = expected.reduce(0) { $0 + $1.contacts.count }
            step("action \(attempt.sequence)/\(attempts.count) round \(attempt.round) \(attempt.planned.id): expect \(expected.count) gesture(s), \(contacts) contact(s), up to \(expected.map(\.maxActive).max() ?? 0) down at once, \(formatCLINumber(action.scheduledSeconds)) s",
                 actionArguments(action))
            if options.readback == .each || index == attempts.count - 1 {
                step("wait \(formatCLINumber(settle)) s, then readback: stop if the probe is gone, another bundle owns it, or a contact is still down", treeArguments)
            } else {
                lines.append("       then wait \(formatCLINumber(settle)) s")
            }
        }
        if options.pull {
            step("pull the probe log (read only)", pullArguments(destination: "\(options.outputDirectory ?? "tmp/probe-touch/<yyyyMMdd-HHmmss>")/touch-log.jsonl"))
        }
        step("compare and write run.json, report.json and summary.txt in the run directory", nil)
        lines.append("")
        lines.append("Stop rules: no input is retried or replayed. The run stops before any input if the preflight,")
        lines.append("reset or baseline checks fail; after an action if its readback fails, the probe is not found,")
        lines.append("the summary node reports a bundle identifier other than \(options.bundleID), or a contact is still down;")
        lines.append("after \(Self.maximumConsecutiveDispatchFailures) consecutive dispatch failures; and, with --readback end,")
        lines.append("at the first dispatch failure. A failed dispatch is recorded and its readback still taken.")

        var exitCode: Int32 = 0
        lines.append("")
        if fs.exists(m) {
            var unique: [[String]] = [treeArguments]
            if options.reset { unique.append(resetArguments) }
            for attempt in attempts where !unique.contains(actionArguments(attempt.planned.action)) {
                unique.append(actionArguments(attempt.planned.action))
            }
            if options.pull { unique.append(pullArguments(destination: "tmp/probe-touch/dry-run-check/touch-log.jsonl")) }
            var rejected: [String] = []
            for arguments in unique {
                let result = try? invoker.invoke(executable: m, arguments: ["--dry-run"] + arguments, timeout: 30)
                if result?.exitCode != 0 {
                    let message = result.map { String(decoding: $0.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "not run"
                    rejected.append("\(shellQuoted(arguments)): \(message)")
                }
            }
            lines.append("CLI check: \(unique.count - rejected.count)/\(unique.count) distinct commands accepted by `\(m) --dry-run` (plans only; no device contact).")
            for line in rejected { lines.append("  rejected: \(line)") }
            if !rejected.isEmpty { exitCode = Self.exitUsage }
        } else {
            lines.append("CLI check skipped: \(m) does not exist. Build it with `mise run build`.")
        }
        return Outcome(exitCode: exitCode, output: lines.joined(separator: "\n") + "\n")
    }

    // MARK: Live run

    func run(_ plan: TouchPlan, _ validation: PlanValidation) -> Outcome {
        let directory = options.outputDirectory ?? "tmp/probe-touch/" + Self.timestamp(clock.now())
        if fs.exists(directory) {
            return Outcome(exitCode: Self.exitUsage, output: "Run directory \(directory) already exists; choose another with --out.\n")
        }
        do {
            try fs.createDirectory(directory + "/raw")
            try fs.write(Self.encode(plan), to: directory + "/plan.json")
        } catch {
            return Outcome(exitCode: 1, output: "Cannot create run directory \(directory): \(error)\n")
        }
        for warning in validation.warnings { progress("warning: \(warning)") }
        let settle = settle(plan)
        var record = RunRecord(device: options.device, plan: plan, repeatCount: options.repeatCount,
                               readback: options.readback, settleSeconds: settle, bundleID: options.bundleID,
                               manzanero: options.manzanero, startedAt: ISO8601DateFormatter().string(from: clock.now()),
                               reset: options.reset)
        var attempts = attempts(for: plan)

        func persist() { try? fs.write(Self.encode(record), to: directory + "/run.json") }

        func invoke(_ label: String, _ arguments: [String], timeout: Double) -> InvocationResult? {
            let index = record.steps.count + 1
            let base = String(format: "raw/%03d-", index) + label.replacingOccurrences(of: " ", with: "-")
            let started = clock.uptime()
            progress("\(index). \(label): \(shellQuoted([options.manzanero] + arguments))")
            var step = StepRecord(index: index, label: label, arguments: [options.manzanero] + arguments, exitCode: nil,
                                  timedOut: false, elapsedSeconds: 0, stdoutFile: nil, stderrFile: nil, error: nil)
            var result: InvocationResult?
            do {
                let invocation = try invoker.invoke(executable: options.manzanero, arguments: arguments, timeout: timeout)
                result = invocation
                step.exitCode = invocation.exitCode
                step.timedOut = invocation.timedOut
                step.stdoutFile = base + ".stdout"
                step.stderrFile = base + ".stderr"
                try? fs.write(invocation.stdout, to: directory + "/" + base + ".stdout")
                try? fs.write(invocation.stderr, to: directory + "/" + base + ".stderr")
            } catch {
                step.error = String(describing: error)
            }
            step.elapsedSeconds = ProbeJSON.round(clock.uptime() - started, 3)
            record.steps.append(step)
            persist()
            return result
        }

        var reportedUncheckedIdentity = false
        func observe(_ label: String) -> Result<ProbeTree.Observation, RunnerError> {
            guard let result = invoke(label, treeArguments, timeout: 90) else {
                return .failure(RunnerError("\(label): tree could not be run (\(record.steps.last?.error ?? "unknown"))"))
            }
            guard result.exitCode == 0, !result.timedOut else {
                let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = message.isEmpty ? "." : ": \(message)"
                return .failure(RunnerError("\(label): tree exited \(result.exitCode)\(result.timedOut ? " after timing out" : "")\(detail)"))
            }
            let observation: ProbeTree.Observation
            do { observation = try ProbeTree.observe(result.stdout) } catch let error as RunnerError {
                return .failure(RunnerError("\(label): \(error.description)"))
            } catch {
                return .failure(RunnerError("\(label): \(error)"))
            }
            // Foreground identity: a different bundle identifier is treated like a missing probe.
            // An absent attribute is "not checked" and recorded through the readback's bundleID.
            if let problem = ProbeTree.identityProblem(observation.readback, expected: options.bundleID) {
                return .failure(RunnerError("\(label): \(problem)."))
            }
            if observation.readback.bundleID == nil, !reportedUncheckedIdentity {
                reportedUncheckedIdentity = true
                progress("note: the tree reports no nativeAttributes[\"\(ProbeTree.bundleIDAttribute)\"] for \(ProbeTree.summaryIdentifier); the foreground bundle identifier is not checked")
            }
            return .success(observation)
        }

        func stop(_ reason: String) {
            guard record.stop == nil else { return }
            record.stop = StopRecord(reason: reason, afterStep: record.steps.count)
            progress("stopping: \(reason)")
            persist()
        }

        // 1. Preflight: the probe must be the display-centre app, portrait, idle.
        switch observe("preflight") {
        case .failure(let error): stop(error.description + " Nothing was sent.")
        case .success(let observation):
            record.preflight = observation.readback
            let summary = observation.readback.summary
            if !observation.portrait {
                stop("preflight: the probe reports a non-portrait size \(summary.size). Nothing was sent.")
            } else if summary.active > 0 {
                stop("preflight: \(summary.active) contact(s) are down on the probe. Nothing was sent.")
            }
        }

        // 2. Reset through accessibility, then a baseline that proves it took effect.
        if record.stop == nil, let preflight = record.preflight {
            if options.reset {
                let result = invoke("reset", resetArguments, timeout: 90)
                let status = result.flatMap { ProbeTree.receiptStatus($0.stdout) }
                if result?.exitCode != 0 || status != "accepted" {
                    stop("reset: press-id was not accepted (exit \(result.map { String($0.exitCode) } ?? "none"), status \(status ?? "none")). No touch input was sent.")
                } else {
                    switch observe("baseline") {
                    case .failure(let error): stop(error.description + " No touch input was sent.")
                    case .success(let observation):
                        let summary = observation.readback.summary
                        if summary.session == preflight.summary.session {
                            stop("baseline: the session is still \(summary.session); the reset was not observed. No touch input was sent.")
                        } else if summary.active > 0 {
                            stop("baseline: \(summary.active) contact(s) are down. No touch input was sent.")
                        } else {
                            record.baseline = observation.readback
                            if summary.events > 0 {
                                progress("note: \(summary.events) event(s) recorded after the reset before any input; they are excluded from every window")
                            }
                        }
                    }
                }
            } else {
                record.baseline = preflight
            }
        }
        persist()

        // 3. Actions, each followed by a settle pause and (in `each` mode) a readback.
        var consecutiveFailures = 0
        var lastSession = record.baseline?.summary.session
        for index in attempts.indices where record.stop == nil {
            let attempt = attempts[index]
            let action = attempt.planned.action
            let result = invoke("action \(attempt.sequence) \(attempt.planned.id)", actionArguments(action),
                                timeout: action.scheduledSeconds + 90)
            attempts[index].dispatch = Self.dispatchOutcome(result, error: record.steps.last?.error)
            let dispatched = attempts[index].dispatch.state == .dispatched
            consecutiveFailures = dispatched ? 0 : consecutiveFailures + 1
            record.attempts = attempts.filter(\.dispatch.sent)
            persist()
            clock.sleep(seconds: settle)
            if options.readback == .each || index == attempts.count - 1 {
                switch observe("readback \(attempt.sequence)") {
                case .failure(let error):
                    stop(error.description + " No further input was sent.")
                case .success(let observation):
                    attempts[index].readback = observation.readback
                    let summary = observation.readback.summary
                    if summary.session != lastSession {
                        progress("note: the probe session changed from \(lastSession ?? "none") to \(summary.session) after action \(attempt.sequence)")
                        lastSession = summary.session
                    }
                    if summary.active > 0 {
                        stop("readback \(attempt.sequence): \(summary.active) contact(s) still down; release is unverified. No further input was sent.")
                    }
                }
            } else if !dispatched {
                stop("action \(attempt.sequence) did not dispatch and --readback end gives no foreground check before more input.")
            }
            if record.stop == nil, consecutiveFailures >= Self.maximumConsecutiveDispatchFailures {
                stop("\(consecutiveFailures) consecutive dispatch failures.")
            }
            record.attempts = attempts.filter(\.dispatch.sent)
            persist()
        }

        // A run stopped for a reason other than a failed readback gets one closing read
        // (no input) so the last window is bounded.
        if let last = attempts.lastIndex(where: \.dispatch.sent), attempts[last].readback == nil,
           !(record.stop?.reason.hasPrefix("readback") ?? false) {
            if case .success(let observation) = observe("closing readback") { attempts[last].readback = observation.readback }
        }
        record.attempts = attempts
        record.completed = record.stop == nil

        // 4. Pull the log (read only).
        var log: ParsedProbeLog?
        if options.pull, record.baseline != nil {
            let destination = directory + "/touch-log.jsonl"
            let result = invoke("pull", pullArguments(destination: destination), timeout: 180)
            var pull = PullRecord(exitCode: result?.exitCode, path: nil, bytes: nil, error: record.steps.last?.error)
            if result?.exitCode == 0 {
                let file = fs.isDirectory(destination) ? destination + "/touch-log.jsonl" : destination
                if let data = try? fs.read(file) {
                    pull.path = file
                    pull.bytes = data.count
                    log = ParsedProbeLog.parse(data)
                } else {
                    pull.error = "pull reported success but \(file) could not be read"
                }
            }
            record.pull = pull
        }

        record.deviceStateLeft = Self.deviceState(record)
        persist()

        // 5. Compare.
        var report: TouchReport?
        if let baseline = record.baseline {
            let built = TouchComparison.compare(ComparisonInput(
                planName: plan.name, tolerances: plan.tolerances, baseline: baseline, attempts: attempts, log: log,
                notes: Self.notes(record), expectedBundleID: options.bundleID))
            report = built
            try? fs.write(built.json(), to: directory + "/report.json")
            try? fs.write(Data(built.text().utf8), to: directory + "/summary.txt")
        }
        var output = report?.text() ?? "No baseline readback; nothing was measured.\n"
        if let stop = record.stop { output += "Stopped: \(stop.reason)\n" }
        output += "Device state: " + record.deviceStateLeft.joined(separator: " ") + "\n"
        output += "Run directory: \(directory)\n"
        return Outcome(exitCode: record.stop == nil ? 0 : Self.exitStopped, output: output, directory: directory,
                       record: record, report: report)
    }

    static func dispatchOutcome(_ result: InvocationResult?, error: String?) -> DispatchOutcome {
        guard let result else { return DispatchOutcome(state: .failed, message: error ?? "not run") }
        let status = ProbeTree.receiptStatus(result.stdout)
        let message = String(decoding: result.stderr.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut {
            return DispatchOutcome(state: .timedOut, exitCode: result.exitCode, receiptStatus: status, message: message)
        }
        let state: DispatchOutcome.State = result.exitCode == 0 && status == "dispatched" ? .dispatched : .failed
        return DispatchOutcome(state: state, exitCode: result.exitCode, receiptStatus: status,
                               message: message.isEmpty ? nil : message)
    }

    static func deviceState(_ record: RunRecord) -> [String] {
        var state = ["The runner launches, terminates and relaunches nothing and presses no button."]
        if record.baseline != nil, record.reset {
            state.append("The probe was reset once; its current session and Documents/touch-log.jsonl hold this run's touches until the next reset or launch.")
        } else if record.preflight != nil {
            state.append("The probe was not reset by this run.")
        }
        if let reason = record.stop?.reason, reason.contains("still down") {
            state.append("A contact was still down at the last readback; release is unverified. Inspect the device before anything else.")
        }
        if record.preflight == nil {
            state.append("The probe was not observed; no input was sent.")
        }
        return state
    }

    static func notes(_ record: RunRecord) -> [String] {
        var notes: [String] = []
        if let stop = record.stop { notes.append("Run stopped: \(stop.reason)") }
        if let pull = record.pull, pull.path == nil { notes.append("Log pull failed: exit \(pull.exitCode.map(String.init) ?? "none") \(pull.error ?? "")") }
        if !record.reset { notes.append("Run without reset: earlier events in the session are excluded by the baseline window.") }
        if record.readback == .end { notes.append("Readback only at the end: actions are separated by gesture order in the log.") }
        return notes
    }

    // MARK: Compare an existing run directory

    public static func compare(directory: String, fileSystem fs: RunnerFileSystem) -> Outcome {
        let record: RunRecord
        do {
            record = try JSONDecoder().decode(RunRecord.self, from: fs.read(directory + "/run.json"))
        } catch {
            return Outcome(exitCode: exitUsage, output: "Cannot read \(directory)/run.json: \(error)\n")
        }
        guard let baseline = record.baseline else {
            return Outcome(exitCode: exitUsage, output: "The run has no baseline readback; nothing was measured.\n")
        }
        let path = record.pull?.path ?? directory + "/touch-log.jsonl"
        let file = fs.isDirectory(path) ? path + "/touch-log.jsonl" : path
        let log = (try? fs.read(file)).map(ParsedProbeLog.parse)
        let report = TouchComparison.compare(ComparisonInput(
            planName: record.plan.name, tolerances: record.plan.tolerances, baseline: baseline,
            attempts: record.attempts, log: log, notes: notes(record), expectedBundleID: record.bundleID))
        try? fs.write(report.json(), to: directory + "/report.json")
        try? fs.write(Data(report.text().utf8), to: directory + "/summary.txt")
        return Outcome(exitCode: 0, output: report.text() + "Run directory: \(directory)\n", directory: directory,
                       record: record, report: report)
    }

    // MARK: Helpers

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
