import Foundation

/// Pure planning of Apple `devicectl`/`simctl` invocations, independent of process execution.
struct DeviceCommand: Sendable, Equatable {
    var executable: String = "/usr/bin/xcrun"
    var arguments: [String]
    let jsonOutput: Bool
    /// Overlaid on the inherited environment for the run (a simulator
    /// launch's `SIMCTL_CHILD_` variables).
    var environment: [String: String] = [:]

    /// Stands for the process identifier that physical `terminate <bundle>`
    /// resolves just before it runs.
    static let resolvedPIDPlaceholder = "<resolved PID>"

    /// `launch` with its options. Language and locale become the app's
    /// `-AppleLanguages` and `-AppleLocale` arguments, ahead of the caller's.
    static func launch(physical: Bool, device: String, bundle: String, options: LaunchOptions) throws -> Self {
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure.usage("Device identifier must be nonempty and cannot begin with '-'.")
        }
        let bundle = try DiagnosticNames.bundleIdentifier(bundle)
        let appArguments = options.appArguments
        if physical {
            var arguments = ["devicectl", "device", "process", "launch", "--device", device]
            if options.relaunch { arguments.append("--terminate-existing") }
            if !options.environment.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: options.environment, options: [.sortedKeys])
                arguments += ["--environment-variables", String(decoding: data, as: UTF8.self)]
            }
            // Options before the bundle: devicectl passes everything after it to the app.
            return Self(arguments: arguments + ["--timeout", "60", "--json-output", "-", bundle] + appArguments, jsonOutput: true)
        }
        let environment = Dictionary(uniqueKeysWithValues: options.environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) })
        return Self(arguments: ["simctl", "launch"] + (options.relaunch ? ["--terminate-running-process"] : []) + [device, bundle] + appArguments,
                    jsonOutput: false, environment: environment)
    }

    /// The `devicectl` or `simctl` invocation for one wrapped operation, after
    /// checking its operands. An operation the platform lacks is unsupported.
    static func plan(physical: Bool, device: String, operation: String, operands: [String] = []) throws -> Self {
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure.usage("Device identifier must be nonempty and cannot begin with '-'.")
        }
        func require(_ count: Int) throws {
            guard operands.count == count, operands.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                throw CommandFailure.usage("\(operation) expects \(count) nonempty operand(s), without a leading '-'.")
            }
        }
        let command: [String]
        if physical {
            if let dataCommand = try (AppDataCommand.plan(operation: operation, operands: operands) ?? ReportCommand.plan(operation: operation, operands: operands)) {
                return Self(arguments: ["devicectl", "device"] + dataCommand + ["--device", device, "--timeout", "60", "--json-output", "-"], jsonOutput: true)
            }
            switch operation {
            case "apps":
                try require(0)
                command = ["info", "apps", "--include-default-apps"]
            case "launch":
                try require(1)
                // Launch consumes everything after the app operand as app argv.
                // Keep device/output options before it, including in Build & Run.
                return Self(arguments: ["devicectl", "device", "process", "launch", "--device", device,
                    "--timeout", "60", "--json-output", "-"] + operands, jsonOutput: true)
            case "processes", "details":
                try require(0)
                command = ["info", operation]
            case "terminate":
                try require(1)
                if operands[0].allSatisfy(\.isNumber) {
                    guard let pid = UInt32(operands[0]), pid > 0, pid <= Int32.max else {
                        throw CommandFailure.usage("Physical terminate requires a positive process ID or a bundle identifier.")
                    }
                    command = ["process", "terminate", "--pid", String(pid)]
                } else {
                    // A bundle: its one running process is found when the command runs.
                    _ = try DiagnosticNames.bundleIdentifier(operands[0])
                    command = ["process", "terminate", "--pid", resolvedPIDPlaceholder]
                }
            case "open-url":
                try require(1)
                guard URL(string: operands[0])?.scheme != nil else {
                    throw CommandFailure.usage("open-url requires an absolute URL with a scheme.")
                }
                command = ["process", "openURL", operands[0]]
            case "install", "uninstall":
                try require(1)
                command = [operation, "app"] + operands
            case "screenshot":
                try require(1)
                guard operands[0].lowercased().hasSuffix(".png") else {
                    throw CommandFailure.usage("Screenshot destination must end in .png.")
                }
                command = ["capture", "screenshot", "--destination", operands[0]]
            default:
                throw CommandFailure.unsupported("Unsupported physical-device operation: \(operation).")
            }
            return Self(arguments: ["devicectl", "device"] + command + ["--device", device, "--timeout", "60", "--json-output", "-"], jsonOutput: true)
        }
        switch operation {
        case "apps":
            try require(0)
            command = ["listapps", device]
        case "boot", "shutdown":
            try require(0)
            command = [operation, device]
        case "launch", "terminate", "install", "uninstall", "open-url":
            try require(1)
            command = [operation == "open-url" ? "openurl" : operation, device] + operands
        case "screenshot":
            try require(1)
            guard operands[0].lowercased().hasSuffix(".png") else {
                throw CommandFailure.usage("Screenshot destination must end in .png.")
            }
            command = ["io", device, "screenshot", "--type=png", operands[0]]
        default:
            // Simulator input and accessibility (SimulatorInput) are routed
            // before these simctl wrappers.
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        return Self(arguments: ["simctl"] + command, jsonOutput: false)
    }
}

/// The one running process of an installed app on a physical device, read
/// from `devicectl`'s app and process lists: the process whose executable
/// sits directly in the app's folder (an extension's sits deeper).
enum RunningApp {
    static func pid(of bundle: String, apps: Data, processes: Data) throws -> Int32 {
        let consequence = "nothing was terminated"
        guard let folder = try PhysicalLogCapture.appDirectory(apps, bundle: bundle, consequence: consequence) else {
            throw CommandFailure(.targetUnresolved, "\(bundle) is not installed on the device; nothing was terminated.", inputSent: .none)
        }
        let appFolder = PhysicalLogCapture.normalized(folder) + "/"
        let matches = try PhysicalLogCapture.runningProcesses(processes, consequence: consequence).filter {
            PhysicalLogCapture.normalized(URL(fileURLWithPath: $0.executable).deletingLastPathComponent().path) + "/" == appFolder
        }
        switch matches.count {
        case 0:
            throw CommandFailure(.targetUnresolved, "\(bundle) is not running; nothing was terminated.", inputSent: .none)
        case 1:
            return matches[0].pid
        default:
            let pids = matches.map { String($0.pid) }.joined(separator: ", ")
            throw CommandFailure(.targetUnresolved, "\(bundle) has \(matches.count) running processes (PIDs \(pids)); terminate one by its PID. Nothing was terminated.", inputSent: .none)
        }
    }
}

/// What `launch` passes to the app beyond its bundle identifier.
struct LaunchOptions: Sendable, Equatable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    /// A language code for `-AppleLanguages`, such as `es` or `pt-BR`.
    var language: String?
    /// A locale identifier for `-AppleLocale`, such as `es_ES`.
    var locale: String?
    /// End a running copy of the app first.
    var relaunch = false

    init(arguments: [String] = [], environment: [String] = [], language: String? = nil, locale: String? = nil, relaunch: Bool = false) throws {
        guard arguments.allSatisfy({ !$0.contains("\0") }) else { throw CommandFailure.usage("App arguments cannot contain NUL.") }
        var variables: [String: String] = [:]
        for entry in environment {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else {
                throw CommandFailure.usage("--env takes NAME=VALUE; got '\(entry)'.")
            }
            let name = String(entry[..<equals])
            guard name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }),
                  name.first.map({ !$0.isNumber }) ?? false else {
                throw CommandFailure.usage("Environment variable names may contain only ASCII letters, digits and '_', and cannot start with a digit; got '\(name)'.")
            }
            guard variables[name] == nil else { throw CommandFailure.usage("--env names \(name) twice.") }
            let value = String(entry[entry.index(after: equals)...])
            guard !value.contains("\0") else { throw CommandFailure.usage("Environment values cannot contain NUL.") }
            variables[name] = value
        }
        func identifier(_ value: String?, _ option: String, separator: Character) throws -> String? {
            guard let value else { return nil }
            let parts = value.split(separator: separator, omittingEmptySubsequences: false)
            guard (2...35).contains(value.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
                  parts[0].count >= 2, parts[0].allSatisfy(\.isLetter) else {
                throw CommandFailure.usage("\(option) takes an identifier such as \(separator == "-" ? "es or pt-BR" : "es_ES or en_US"); got '\(value)'.")
            }
            return value
        }
        self.arguments = arguments
        self.environment = variables
        self.language = try identifier(language, "--language", separator: "-")
        self.locale = try identifier(locale, "--locale", separator: "_")
        self.relaunch = relaunch
    }

    /// The app's arguments: language and locale first, then the caller's.
    var appArguments: [String] {
        (language.map { ["-AppleLanguages", "(\($0))"] } ?? []) + (locale.map { ["-AppleLocale", $0] } ?? []) + arguments
    }
}
