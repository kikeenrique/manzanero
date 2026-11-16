import Foundation

/// `logs`, `console` and `last-crash`: what an app under test wrote and how it
/// ended. Parsing and dry-run plans only; execution lives in
/// `UnifiedLogCapture`, `AppConsole` and `CrashReport`. See docs/app-logs.md.
enum AppDiagnosticsCommand: Sendable, Equatable {
    case logs(LogCapture)
    case console(ConsoleCapture)
    case lastCrash(LastCrashQuery)

    static let operations = ["logs", "console", "last-crash"]
    /// Operations that only read; `console` launches an app.
    static let observations = ["logs", "last-crash"]

    /// One of `operations` with its options checked. Physical logs are refused.
    static func make(physical: Bool, device: String, operation: String, options: DiagnosticOptions) throws -> Self {
        guard !device.isEmpty, !device.hasPrefix("-") else {
            throw CommandFailure.usage("Device identifier must be nonempty and cannot begin with '-'.")
        }
        switch operation {
        case "logs":
            if physical {
                throw CommandFailure.unsupported("Physical logs are not implemented: Apple's tools cannot stream a device's unified log without root, and the native os_trace_relay route is not built. Use physical console (unverified) or last-crash; nothing was sent.")
            }
            return .logs(try LogCapture(device: SimulatorDevice.requireUUID(device, operation: "logs"), options: options))
        case "console":
            return .console(try ConsoleCapture(physical: physical,
                device: physical ? device : SimulatorDevice.requireUUID(device, operation: "console"), options: options))
        case "last-crash":
            return .lastCrash(try LastCrashQuery(physical: physical,
                device: physical ? device : SimulatorDevice.requireUUID(device, operation: "last-crash"), options: options))
        default:
            throw CommandFailure.unsupported("Unsupported diagnostics operation: \(operation).")
        }
    }

    var operation: String {
        switch self {
        case .logs: "logs"
        case .console: "console"
        case .lastCrash: "last-crash"
        }
    }

    var physical: Bool {
        switch self {
        case .logs: false
        case .console(let value): value.physical
        case .lastCrash(let value): value.physical
        }
    }

    var device: String {
        switch self {
        case .logs(let value): value.device
        case .console(let value): value.device
        case .lastCrash(let value): value.device
        }
    }
}

/// The options of `logs`, `console` and `last-crash` as the CLI's parser
/// gives them: `--name value` pairs keyed by option name, flags, the operands
/// before `--` and the app arguments after it.
struct DiagnosticOptions: Sendable {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    var trailing: [String] = []

    /// Leaves out options that were not given.
    init(values: [String: String?] = [:], flags: [String: Bool] = [:], positional: [String] = [], trailing: [String] = []) {
        self.values = values.compactMapValues { $0 }
        self.flags = Set(flags.filter(\.value).keys)
        self.positional = positional
        self.trailing = trailing
    }

    func integer(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text), range.contains(value) else {
            throw CommandFailure.usage("\(name) must be an integer in \(range.lowerBound)...\(range.upperBound).")
        }
        return value
    }

    func date(_ name: String) throws -> Date? {
        guard let text = values[name] else { return nil }
        guard let date = DiagnosticTime.parseISO8601(text) else {
            throw CommandFailure.usage("\(name) must be an ISO-8601 date and time, for example 2026-01-01T12:00:00Z.")
        }
        return date
    }
}

/// Validation of the values the tool quotes into predicates or matches
/// against report headers. Nothing outside these sets reaches a predicate.
enum DiagnosticNames {
    static func bundleIdentifier(_ value: String) throws -> String {
        guard (1...255).contains(value.utf8.count), value.first != ".", value.first != "-",
              value.unicodeScalars.allSatisfy({ ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "." || $0 == "-" }) else {
            throw CommandFailure.usage("Bundle identifiers may contain only ASCII letters, digits, '.' and '-' (1...255 characters).")
        }
        return value
    }

    static func processName(_ value: String) throws -> String {
        guard (1...255).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || " ._+-".unicodeScalars.contains($0) }),
              value.first != " ", value.first != "-" else {
            throw CommandFailure.usage("Process names may contain only ASCII letters, digits, space, '.', '_', '+' and '-' (1...255 characters).")
        }
        return value
    }

    static func subsystem(_ value: String) throws -> String {
        guard (1...255).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }) else {
            throw CommandFailure.usage("Subsystems may contain only ASCII letters, digits, '.', '_' and '-' (1...255 characters).")
        }
        return value
    }

    /// Printable ASCII without the predicate's quote and escape characters.
    static func category(_ value: String) throws -> String {
        guard (1...255).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) && $0 != "\"" && $0 != "\\" && $0 != "'" }) else {
            throw CommandFailure.usage("Categories may contain printable ASCII except quotes and backslashes (1...255 characters).")
        }
        return value
    }
}

/// Dates in the formats Apple's tools print, normalised to ISO 8601 UTC.
enum DiagnosticTime {
    /// `2026-11-15 21:18:02.202464+0100` (log) or `2026-11-15 21:21:29.00 +0100`
    /// (crash reports). Returns the instant and the fraction digits as written.
    static func parseApple(_ text: String) -> (date: Date, fraction: String)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 24 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for scalar in scalars[range] {
                guard let digit = Int(String(scalar)), ("0"..."9").contains(Character(scalar)) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard scalars[4] == "-", scalars[7] == "-", scalars[10] == " ", scalars[13] == ":", scalars[16] == ":",
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
        var index = 19
        var fraction = ""
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, ("0"..."9").contains(Character(scalars[index])) {
                fraction.unicodeScalars.append(scalars[index]); index += 1
            }
        }
        if index < scalars.count, scalars[index] == " " { index += 1 }
        guard index < scalars.count, scalars[index] == "+" || scalars[index] == "-" else { return nil }
        let sign = scalars[index] == "-" ? -1 : 1
        index += 1
        guard let zoneHours = number(index..<(index + 2)) else { return nil }
        index += 2
        if index < scalars.count, scalars[index] == ":" { index += 1 }
        guard let zoneMinutes = number(index..<(index + 2)), index + 2 == scalars.count,
              let zone = TimeZone(secondsFromGMT: sign * (zoneHours * 3600 + zoneMinutes * 60)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }
        let fractionValue = fraction.isEmpty ? 0 : (Double("0." + fraction) ?? 0)
        return (date.addingTimeInterval(fractionValue), fraction)
    }

    /// ISO 8601 UTC, keeping the source's fraction digits.
    static func iso8601(_ date: Date, fraction: String = "") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                          parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return base + (fraction.isEmpty ? "" : "." + fraction) + "Z"
    }

    /// Normalises an Apple timestamp, or returns it unchanged if unparseable.
    static func normalise(_ text: String) -> String {
        guard let parsed = parseApple(text) else { return text }
        return iso8601(parsed.date, fraction: parsed.fraction)
    }

    static func parseISO8601(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// `log show --start/--end` form with an explicit UTC offset. The man page
    /// says `ZZZZZ`, but log 27.2 parses with `%z`, which needs `+0000`.
    static func logArgument(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d+0000", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
