import Foundation

public enum ReadbackMode: String, Codable, Sendable {
    /// Read the accessibility summary after every action (default): per-action windows
    /// and a foreground check before each further input.
    case each
    /// Read only before the first and after the last action; actions are separated by
    /// gesture order in the log. Faster, but no foreground check between actions.
    case end
}

public struct RunOptions: Sendable, Equatable {
    public static let defaultBundleID = "com.lemambo.manzanero.probeapp"
    public static let defaultManzanero = ".build/debug/manzanero"
    public static let maximumRepeat = 50

    public var device: String
    /// `physical` (default) or `simulator`: every Manzanero command names the
    /// target as `--device <UDID>` or `--simulator <UUID>`.
    public var platform = "physical"
    public var planPath: String?
    public var repeatCount = 1
    public var readback: ReadbackMode = .each
    public var settleOverride: Double?
    public var bundleID = RunOptions.defaultBundleID
    public var manzanero = RunOptions.defaultManzanero
    public var outputDirectory: String?
    public var reset = true
    public var pull = true
    public var dryRun = false
    /// Accept a landscape probe (launched with `-ProbeAllowRotation YES`) at
    /// preflight. Off by default: a portrait-only run stops on a landscape size.
    public var anyOrientation = false

    public init(device: String) { self.device = device }
}

public enum RunnerCommand: Sendable, Equatable {
    case run(RunOptions)
    case compare(directory: String)
    case printPlan
    case help
}

public enum RunnerArguments {
    public static let usage = """
    probe-touch — measure Manzanero's physical touch delivery against the probe app

    Usage:
      probe-touch run <UDID> [options]   Send a plan of touches and compare with what the probe received
      probe-touch compare <run-dir>      Recompute report.json and summary.txt from a run directory
      probe-touch plan                   Print the built-in plan as JSON (a starting point for --plan)
      probe-touch --help

    Run options:
      --dry-run              Print the plan and every command; contact no device. Each action is
                             also checked with `manzanero --dry-run` when the binary exists.
      --plan <file>          Plan JSON instead of the built-in plan (docs/probe-touch-runner.md)
      --repeat <n>           Run the plan n times, 1...50 (default 1)
      --readback each|end    Readback after every action (default) or only at the end
      --settle <seconds>     Pause before each readback, 0...5 (default: plan, else 0.5)
      --bundle-id <id>       Probe bundle identifier for the log pull (default com.lemambo.manzanero.probeapp)
      --manzanero <path>     Manzanero executable (default .build/debug/manzanero)
      --out <dir>            New run directory (default tmp/probe-touch/<timestamp>)
      --no-reset             Do not press probe.touch.reset before the first action
      --no-pull              Do not pull Documents/touch-log.jsonl at the end
      --platform physical|simulator
                             Address a physical device (default) or a booted simulator by UUID.
                             The simulator has no log pull; the readouts are the evidence.
      --any-orientation      Accept a landscape probe at preflight (rotation measurements);
                             coordinates stay normalized to the current interface.

    The UDID is required; there is no default device. The probe must already be the
    foreground app. Inputs are never retried or replayed.
    """

    public static func parse(_ arguments: [String]) throws -> RunnerCommand {
        guard let command = arguments.first else { return .help }
        switch command {
        case "--help", "-h", "help": return .help
        case "plan":
            guard arguments.count == 1 else { throw RunnerError("plan takes no arguments") }
            return .printPlan
        case "compare":
            guard arguments.count == 2, !arguments[1].hasPrefix("-") else { throw RunnerError("compare takes one run directory") }
            return .compare(directory: arguments[1])
        case "run":
            return .run(try parseRun(Array(arguments.dropFirst())))
        default:
            throw RunnerError("unknown command \(command); see --help")
        }
    }

    static func parseRun(_ arguments: [String]) throws -> RunOptions {
        guard let device = arguments.first, !device.hasPrefix("-") else {
            throw RunnerError("run requires an explicit device UDID as its first argument; there is no default device")
        }
        guard (1...64).contains(device.utf8.count),
              device.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw RunnerError("device UDID must be 1...64 ASCII letters, digits or hyphens")
        }
        var options = RunOptions(device: device)
        var rest = arguments.dropFirst()[...]
        func value(_ flag: String) throws -> String {
            guard let next = rest.first, !next.hasPrefix("--") else { throw RunnerError("\(flag) needs a value") }
            rest = rest.dropFirst()
            return next
        }
        while let flag = rest.first {
            rest = rest.dropFirst()
            switch flag {
            case "--dry-run": options.dryRun = true
            case "--no-reset": options.reset = false
            case "--no-pull": options.pull = false
            case "--any-orientation": options.anyOrientation = true
            case "--plan": options.planPath = try value(flag)
            case "--out": options.outputDirectory = try value(flag)
            case "--manzanero": options.manzanero = try value(flag)
            case "--repeat":
                guard let count = Int(try value(flag)), (1...RunOptions.maximumRepeat).contains(count) else {
                    throw RunnerError("--repeat must be an integer 1...\(RunOptions.maximumRepeat)")
                }
                options.repeatCount = count
            case "--readback":
                guard let mode = ReadbackMode(rawValue: try value(flag)) else { throw RunnerError("--readback must be each or end") }
                options.readback = mode
            case "--settle":
                guard let seconds = Double(try value(flag)), seconds.isFinite, (0...5).contains(seconds) else {
                    throw RunnerError("--settle must be 0...5 seconds")
                }
                options.settleOverride = seconds
            case "--platform":
                let platform = try value(flag)
                guard ["physical", "simulator"].contains(platform) else { throw RunnerError("--platform must be physical or simulator") }
                options.platform = platform
            case "--bundle-id":
                let id = try value(flag)
                let parts = id.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
                    throw RunnerError("--bundle-id must be a reverse-DNS identifier")
                }
                options.bundleID = id
            default:
                throw RunnerError("unknown option \(flag); see --help")
            }
        }
        if options.platform == "simulator" {
            guard UUID(uuidString: device) != nil else { throw RunnerError("--platform simulator requires the simulator's UUID") }
            // Manzanero has no simulator app-data pull; the recent-gestures and
            // last-gesture readouts are the evidence (docs/probe-touch-runner.md).
            options.pull = false
        }
        return options
    }
}
