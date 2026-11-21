import AppleDeviceBridge
import Foundation

/// The failure of one command. `description` is the human-readable message,
/// printed unchanged on stderr by the CLI and returned as MCP text content.
///
/// The structured part is set where the failure is created, never derived
/// from the message text, so the wording stays free to change. A failure
/// created with `init(description:)` is `unclassified`: whether input reached
/// the device is then `unknown` and a retry needs inspection first. See
/// docs/errors.md for the meaning of every value.
struct CommandFailure: Error, CustomStringConvertible {
    /// A small closed set; each value calls for a different reaction.
    enum Code: String, Sendable, CaseIterable {
        /// The arguments are wrong; fix the call.
        case usage
        /// The operation does not exist for this platform or backend.
        case unsupportedOperation = "unsupported-operation"
        /// Developer Mode, pairing, connection or developer-image state blocks the operation.
        case deviceNotReady = "device-not-ready"
        /// The primary display is off or its awake state is unknown.
        case displayOff = "display-off"
        /// Another manzanero process or recording owns the device.
        case deviceBusy = "device-busy"
        /// A human handoff is pending for the device.
        case handoffPending = "handoff-pending"
        /// An earlier input may have left a contact, key or button held, so
        /// input is refused until the device has been inspected and cleared.
        case deviceQuarantined = "device-quarantined"
        /// An accessibility selector or PID matched nothing, several things, or something unusable.
        case targetUnresolved = "ambiguous-or-missing-target"
        /// The display, application or element changed between two checks.
        case preconditionChanged = "precondition-changed"
        /// An Apple executable exited with an error.
        case toolFailed = "tool-failed"
        /// A connection, Apple service or device reply failed or was malformed.
        case transportFailed = "transport-failed"
        /// A deadline passed.
        case timeout
        /// The operation was cancelled.
        case cancelled
        /// Xcode could not sign, provision or build the app.
        case signingFailed = "signing-failed"
        /// The Mac lacks something: macOS version, private interface, firewall rule, terminal or MCP capability.
        case hostRequirement = "host-requirement"
        /// Input was attempted and its effect or release is unknown.
        case inputOutcomeUnknown = "input-outcome-unknown"
        /// An internal invariant failed.
        case `internal`
        /// The failure site has not been classified.
        case unclassified
    }

    /// Whether anything that can change device state (input, an app or file
    /// change, a clipboard write) may have reached the device.
    enum InputSent: String, Sendable, CaseIterable {
        case none, possible, unknown
    }

    /// Whether repeating the identical call is appropriate.
    enum Retry: String, Sendable, CaseIterable {
        /// Repeating cannot duplicate a device effect; it may fail again.
        case safe
        /// An effect may have happened: inspect the device first, never replay blindly.
        case afterInspection = "after-inspection"
        /// Nothing was sent; repeating is pointless until `action` is done.
        case afterAction = "after-action"
        /// The identical call can never succeed; change it.
        case no
    }

    /// What has to happen before a retry, for `Retry.afterAction`.
    enum Action: String, Sendable, CaseIterable {
        /// Wake the display (`wake --device <UDID>`) and unlock the device.
        case wake
        /// Wait for the other owner or the person to finish.
        case wait
        /// A person must act: Developer Mode, pairing, signing, the Mac's setup.
        case human
        /// Allow incoming connections for this executable in the macOS firewall.
        case allowFirewall = "allow-firewall"
        /// Inspect the device (`tree`, `screenshot`), then run `clear-quarantine`.
        case clearQuarantine = "clear-quarantine"
    }

    let description: String
    let code: Code
    let inputSent: InputSent
    let retry: Retry
    let action: Action?
    /// What the CLI prints instead of `description` in the text format: the
    /// argument parser's message with the command's usage line.
    var text: String? = nil

    /// An unclassified failure with honest defaults.
    init(description: String) {
        self.init(.unclassified, description, inputSent: .unknown)
    }

    /// A classified failure. `retry` and `action` default from the code and
    /// `inputSent`; pass them only when the site knows better.
    init(_ code: Code, _ description: String, inputSent: InputSent, retry: Retry? = nil, action: Action? = nil) {
        self.description = description
        self.code = code
        self.inputSent = inputSent
        let retry = retry ?? Self.defaultRetry(code, inputSent: inputSent)
        self.retry = retry
        self.action = action ?? (retry == .afterAction ? Self.defaultAction(code) : nil)
    }

    /// Wrong arguments; nothing was sent.
    static func usage(_ description: String, text: String? = nil) -> Self {
        var failure = Self(.usage, description, inputSent: .none)
        failure.text = text
        return failure
    }

    /// An operation that does not exist here; nothing was sent.
    static func unsupported(_ description: String) -> Self { Self(.unsupportedOperation, description, inputSent: .none) }

    /// Adds context to an inner error and keeps its classification. A
    /// cancellation stays `cancelled`; any other error type gets the
    /// category `foreignCode` recognises, or stays unclassified.
    init(_ description: String, wrapping error: any Error) {
        if let inner = error as? CommandFailure {
            self.init(inner.code, description, inputSent: inner.inputSent, retry: inner.retry, action: inner.action)
        } else if error is CancellationError {
            self.init(.cancelled, description, inputSent: .unknown)
        } else {
            self.init(Self.foreignCode(error), description, inputSent: .unknown)
        }
    }

    /// The category of an error that is not a `CommandFailure`, from its type
    /// and domain alone. The site is unknown, so callers keep
    /// `inputSent: unknown`; only what is recognised is classified.
    static func foreignCode(_ error: any Error) -> Code {
        // A reply that does not decode: malformed JSON or property list.
        if error is DecodingError { return .transportFailed }
        // The accessibility socket's own failures: a deadline (seen when the
        // cable was pulled during a batch on 2026-11-21, which reported it
        // unclassified), a closed socket, or a system call's error number.
        if let socket = error as? AccessibilitySocketTransport.Failure {
            switch socket {
            case .deadline: return .timeout
            case .closed: return .transportFailed
            case .system(_, let code): return foreignCode(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
        }
        let error = error as NSError
        switch error.domain {
        case NSPOSIXErrorDomain:
            switch Int32(error.code) {
            case ETIMEDOUT: return .timeout
            case ECONNREFUSED, ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN, ENETRESET:
                return .transportFailed
            case ENOENT, EACCES, EPERM, ENOSPC, EEXIST, ENOTDIR, EISDIR, EROFS: return .hostRequirement
            default: return .unclassified
            }
        case NSURLErrorDomain:
            return error.code == NSURLErrorTimedOut ? .timeout : .transportFailed
        case NSCocoaErrorDomain:
            switch error.code {
            // Property list and JSON data that cannot be read.
            case NSPropertyListReadCorruptError, NSPropertyListReadUnknownVersionError, NSPropertyListReadStreamError,
                 NSCoderReadCorruptError, NSCoderValueNotFoundError:
                return .transportFailed
            // A file or directory on this Mac that is missing, unreadable, unwritable or in the way.
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError, NSFileWriteNoPermissionError,
                 NSFileWriteOutOfSpaceError, NSFileWriteFileExistsError, NSFileWriteVolumeReadOnlyError, NSFileReadUnknownError,
                 NSFileWriteUnknownError, NSFileReadInvalidFileNameError, NSFileWriteInvalidFileNameError:
                return .hostRequirement
            default: return .unclassified
            }
        // AVFoundation, Core Media and VideoToolbox steps that return an error.
        case "AVFoundationErrorDomain", NSOSStatusErrorDomain: return .toolFailed
        default: return .unclassified
        }
    }

    /// The same failure where the caller knows nothing could have reached the
    /// device, for example a read-only command or a stage before any send.
    func noInputSent() -> Self {
        inputSent == .none ? self : Self(code, description, inputSent: .none)
    }

    /// The same failure after the caller has already sent input to the
    /// device, so a retry needs inspection whatever the inner stage was.
    func inputPossiblySent() -> Self {
        inputSent == .none ? Self(code, description, inputSent: .possible) : self
    }

    /// A failure from the bridge's input functions (`ADCPerformTouch` and the
    /// others that end in `ADCPerformInput`). They return
    /// `ADCInputOutcomeUnknown` once input was attempted and another non-zero
    /// value when they stopped before sending any input.
    static func inputDispatch(status: Int32, message: String) -> Self {
        status == ADCInputOutcomeUnknown
            ? Self(.inputOutcomeUnknown, message, inputSent: .possible)
            : Self(.transportFailed, message, inputSent: .none)
    }

    private static func defaultRetry(_ code: Code, inputSent: InputSent) -> Retry {
        guard inputSent == .none else { return .afterInspection }
        switch code {
        case .usage, .unsupportedOperation: return .no
        case .deviceNotReady, .displayOff, .deviceBusy, .handoffPending, .deviceQuarantined, .signingFailed, .hostRequirement: return .afterAction
        default: return .safe
        }
    }

    private static func defaultAction(_ code: Code) -> Action? {
        switch code {
        case .displayOff: .wake
        case .deviceBusy, .handoffPending: .wait
        case .deviceQuarantined: .clearQuarantine
        case .deviceNotReady, .signingFailed, .hostRequirement: .human
        default: nil
        }
    }

    /// Any thrown error as a classified failure with the message the CLI and
    /// MCP already print for it (`"\(error)"`).
    static func classify(_ error: any Error) -> Self {
        if let failure = error as? CommandFailure { return failure }
        if error is CancellationError { return Self(.cancelled, "\(error)", inputSent: .unknown) }
        return Self(foreignCode(error), "\(error)", inputSent: .unknown)
    }

    /// The CLI's exit status for a failure: 64 (EX_USAGE) when the call was
    /// wrong, 1 otherwise.
    static func exitCode(for error: any Error) -> Int32 {
        classify(error).code == .usage ? 64 : 1
    }

    /// The `error` object shared by the CLI's JSON format and MCP's structured content.
    var fields: [String: String?] {
        ["code": code.rawValue, "message": description, "inputSent": inputSent.rawValue,
         "retry": retry.rawValue, "action": action?.rawValue]
    }
}

/// How the CLI prints a failure on stderr. Text is the default and prints the
/// message exactly as before; JSON prints one object on one line.
enum ErrorFormat: String, Sendable, CaseIterable {
    case text, json

    static let option = "--error-format"
    static let environmentVariable = "MANZANERO_ERROR_FORMAT"

    /// The parsed `--error-format`, which wins over the environment variable;
    /// without either the format is text.
    static func select(_ chosen: ErrorFormat?, environment: [String: String]) throws -> ErrorFormat {
        if let chosen { return chosen }
        guard let value = environment[environmentVariable], !value.isEmpty else { return .text }
        guard let chosen = ErrorFormat(rawValue: value) else {
            throw CommandFailure.usage("\(environmentVariable) must be text or json.")
        }
        return chosen
    }

    /// The format for a failure to parse the arguments, which leaves no parsed
    /// option to read: the first `--error-format <value>` or
    /// `--error-format=<value>` before `--`, else the environment variable.
    static func scan(_ arguments: [String], environment: [String: String]) throws -> ErrorFormat {
        for (index, argument) in arguments.enumerated() {
            if argument == "--" { break }
            let value: String?
            if argument == option { value = index + 1 < arguments.count ? arguments[index + 1] : nil }
            else if argument.hasPrefix(option + "=") { value = String(argument.dropFirst(option.count + 1)) }
            else { continue }
            guard let value, let chosen = ErrorFormat(rawValue: value) else {
                throw CommandFailure.usage("\(option) requires text or json.")
            }
            return chosen
        }
        return try select(nil, environment: environment)
    }

    /// The stderr bytes for a failure. Text is `"\(error)\n"`, unchanged.
    func render(_ error: any Error) -> Data {
        switch self {
        case .text:
            return Data("\((error as? CommandFailure)?.text ?? "\(error)")\n".utf8)
        case .json:
            let fields = CommandFailure.classify(error).fields.mapValues { $0.map { $0 as Any } ?? NSNull() }
            let data = (try? JSONSerialization.data(withJSONObject: ["error": fields], options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data(#"{"error":{"code":"internal","message":"Cannot encode the failure as JSON.","inputSent":"unknown","retry":"after-inspection","action":null}}"#.utf8)
            return data + Data("\n".utf8)
        }
    }
}
