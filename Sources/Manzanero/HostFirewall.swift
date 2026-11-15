import Foundation

/// Whether the macOS application firewall lets this executable receive
/// incoming connections.
///
/// Native recording receives the device's video as incoming UDP on the tunnel
/// interface. With the firewall on and no rule for this executable, those
/// datagrams are dropped silently: the stream starts, cleanup is acknowledged
/// and no packet ever arrives. Rules are per executable path, so a build at a
/// new path, or an install in a new location, needs its own.
///
/// This only reads Apple's firewall tool. It never changes a rule: that needs
/// an administrator and is the user's decision.
struct HostFirewall: Sendable, Equatable {
    enum Status: String, Sendable {
        /// The firewall is off; nothing is filtered.
        case off
        /// A rule allows incoming connections for this executable.
        case allowed
        /// A rule blocks incoming connections for this executable.
        case blocked
        /// The firewall is on and has no rule for this executable.
        case noRule = "no-rule"
        /// The firewall state could not be read.
        case unknown
    }

    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    let status: Status
    let executable: String

    /// The running executable with symbolic links resolved, which is the path
    /// the firewall records (a Homebrew `bin` entry points into `libexec`).
    static var currentExecutable: String {
        URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    static func check(executable: String = currentExecutable,
                      run: ([String]) throws -> Data = { try ToolRunner().run($0, executable: tool, timeout: 5) }) -> HostFirewall {
        guard let state = try? run(["--getglobalstate"]) else { return .init(status: .unknown, executable: executable) }
        let enabled = parseEnabled(String(decoding: state, as: UTF8.self))
        guard let enabled else { return .init(status: .unknown, executable: executable) }
        guard enabled else { return .init(status: .off, executable: executable) }
        guard let apps = try? run(["--listapps"]) else { return .init(status: .unknown, executable: executable) }
        return .init(status: parseRule(String(decoding: apps, as: UTF8.self), executable: executable), executable: executable)
    }

    /// `Firewall is enabled. (State = 1)`; state 0 is off, 1 and 2 filter.
    static func parseEnabled(_ output: String) -> Bool? {
        guard let match = output.range(of: #"State = (\d)"#, options: .regularExpression),
              let digit = output[match].last?.wholeNumberValue else { return nil }
        return digit != 0
    }

    /// `--listapps` prints `N : <path>` followed by a line naming the rule.
    static func parseRule(_ output: String, executable: String) -> Status {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            guard let separator = line.range(of: " : "), Int(line[..<separator.lowerBound]) != nil,
                  line[separator.upperBound...].trimmingCharacters(in: .whitespaces) == executable else { continue }
            let rule = index + 1 < lines.count ? lines[index + 1] : ""
            if rule.localizedCaseInsensitiveContains("allow") { return .allowed }
            if rule.localizedCaseInsensitiveContains("block") { return .blocked }
        }
        return .noRule
    }

    /// True when incoming video is expected to be dropped.
    var dropsIncoming: Bool { status == .blocked || status == .noRule }

    var detail: String {
        switch status {
        case .off: "The macOS firewall is off."
        case .allowed: "The macOS firewall allows incoming connections for this executable."
        case .blocked: "The macOS firewall blocks incoming connections for this executable, so native recording receives no video."
        case .noRule: "The macOS firewall is on and has no rule for this executable. Unless the executable is signed by an identified developer and the firewall's automatic allowance for signed software is on, incoming video for native recording is dropped. Rules are per path, so each build or install location needs its own."
        case .unknown: "The macOS firewall state could not be read."
        }
    }

    /// What a person can do; nil when nothing is needed or known.
    var action: String? {
        guard dropsIncoming else { return nil }
        return "Allow incoming connections for \(executable) under System Settings > Network > Firewall > Options, or as an administrator run: \(Self.tool) --add '\(executable)' and then \(Self.tool) --unblockapp '\(executable)'."
    }

    var doctorEntry: [String: Any] {
        var entry: [String: Any] = ["name": "Firewall", "kind": "host-network", "status": status.rawValue,
                                    "executable": executable, "detail": detail, "affects": ["native-recording"]]
        if let action { entry["action"] = action }
        return entry
    }

    /// Appended to a recording failure in which no packet arrived.
    var recordingHint: String? {
        guard dropsIncoming, let action else { return nil }
        return "Likely cause: \(detail) \(action)"
    }
}
