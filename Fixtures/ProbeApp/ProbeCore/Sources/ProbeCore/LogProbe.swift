import Foundation

/// The log probe: known lines the app writes to the unified log, stdout and
/// stderr, so Manzanero's `logs` and `console` can be checked against ground
/// truth. This type only plans what to write; the app writes it.
///
/// Triggers, none of which needs a touch:
/// - every launch emits one set (token from `-probeLogToken <token>`, else `launch`);
/// - activating the accessibility element `probe.log.emit` (Manzanero
///   `press --id probe.log.emit`) emits another set with the token `emit`;
/// - `-probeCrash abort|trap` crashes deliberately after one set and an
///   `about to crash` line. Only that launch argument crashes the app.
///
/// A custom URL scheme was tried as the trigger and rejected: iOS asks
/// "Open in …?" before delivering it, which needs a touch.
public enum LogProbe {
    public static let category = "probe"
    public static let tokenArgument = "-probeLogToken"
    public static let crashArgument = "-probeCrash"
    public static let defaultToken = "launch"
    public static let emitToken = "emit"
    public static let emitIdentifier = "probe.log.emit"
    public static let maximumTokenLength = 64

    /// Unified-log levels in `Logger` terms; `notice` is the log's `Default`.
    public enum Level: String, CaseIterable, Sendable {
        case debug, info, notice, error, fault

        /// The level name `log --style ndjson` reports (`messageType`, lowercased).
        public var logName: String { self == .notice ? "default" : rawValue }
    }

    public enum CrashMode: String, Sendable { case abort, trap }

    public enum Channel: Equatable, Sendable {
        case log(Level)
        /// A private-interpolated value at the default level, to observe redaction.
        case logPrivate
        case stdoutFlushed
        case stdoutUnflushed
        case stderr
    }

    public struct Emission: Equatable, Sendable {
        public let channel: Channel
        /// The public part of the line. For `logPrivate` the app appends the
        /// private value through a `.private` interpolation.
        public let text: String
        public let privateValue: String?
    }

    /// Tokens are short and plain so they can be searched for without escaping.
    public static func isValidToken(_ token: String) -> Bool {
        (1...maximumTokenLength).contains(token.utf8.count)
            && token.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The launch token: the value after `-probeLogToken` when valid, else `launch`.
    public static func token(arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: tokenArgument), index + 1 < arguments.count,
              isValidToken(arguments[index + 1]) else { return defaultToken }
        return arguments[index + 1]
    }

    /// The deliberate crash, only when `-probeCrash abort|trap` is present.
    public static func crashMode(arguments: [String]) -> CrashMode? {
        guard let index = arguments.firstIndex(of: crashArgument), index + 1 < arguments.count else { return nil }
        return CrashMode(rawValue: arguments[index + 1])
    }

    /// The `probe.log.emit` element's value: sets emitted so far, so a reader
    /// can tell whether an activation landed.
    public static func emitValue(sets: Int) -> String { "{\"sets\":\(sets)}" }

    /// One set of lines, all carrying `token` and the set's sequence number.
    public static func emissions(token: String, sequence: Int) -> [Emission] {
        let prefix = "probe.log \(token) #\(sequence)"
        var lines = Level.allCases.map { Emission(channel: .log($0), text: "\(prefix) level=\($0.logName)", privateValue: nil) }
        lines.append(Emission(channel: .logPrivate, text: "\(prefix) private=", privateValue: "secret-\(token)"))
        lines.append(Emission(channel: .stdoutFlushed, text: "stdout \(token) #\(sequence) flushed", privateValue: nil))
        lines.append(Emission(channel: .stdoutUnflushed, text: "stdout \(token) #\(sequence) unflushed", privateValue: nil))
        lines.append(Emission(channel: .stderr, text: "stderr \(token) #\(sequence)", privateValue: nil))
        return lines
    }

    public static func crashLine(token: String, mode: CrashMode) -> String {
        "probe.log \(token) about to crash mode=\(mode.rawValue)"
    }
}
