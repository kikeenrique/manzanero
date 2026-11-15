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
        /// Wake the display (`physical <UDID> wake`) and unlock the device.
        case wake
        /// Wait for the other owner or the person to finish.
        case wait
        /// A person must act: Developer Mode, pairing, signing, the Mac's setup.
        case human
        /// Allow incoming connections for this executable in the macOS firewall.
        case allowFirewall = "allow-firewall"
    }

    let description: String
    let code: Code
    let inputSent: InputSent
    let retry: Retry
    let action: Action?

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
    static func usage(_ description: String) -> Self { Self(.usage, description, inputSent: .none) }

    /// An operation that does not exist here; nothing was sent.
    static func unsupported(_ description: String) -> Self { Self(.unsupportedOperation, description, inputSent: .none) }

    /// Adds context to an inner error and keeps its classification. A
    /// cancellation stays `cancelled`; any other error type is unclassified.
    init(_ description: String, wrapping error: any Error) {
        if let inner = error as? CommandFailure {
            self.init(inner.code, description, inputSent: inner.inputSent, retry: inner.retry, action: inner.action)
        } else if error is CancellationError {
            self.init(.cancelled, description, inputSent: .unknown)
        } else {
            self.init(description: description)
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
        case .deviceNotReady, .displayOff, .deviceBusy, .handoffPending, .signingFailed, .hostRequirement: return .afterAction
        default: return .safe
        }
    }

    private static func defaultAction(_ code: Code) -> Action? {
        switch code {
        case .displayOff: .wake
        case .deviceBusy, .handoffPending: .wait
        case .deviceNotReady, .signingFailed, .hostRequirement: .human
        default: nil
        }
    }

    /// Any thrown error as a classified failure with the message the CLI and
    /// MCP already print for it (`"\(error)"`).
    static func classify(_ error: any Error) -> Self {
        if let failure = error as? CommandFailure { return failure }
        if error is CancellationError { return Self(.cancelled, "\(error)", inputSent: .unknown) }
        return Self(description: "\(error)")
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

    /// Removes a leading `--error-format <text|json>` (first, or right after
    /// `--dry-run`) from `arguments`. The option wins over the environment
    /// variable; without either the format is text and `arguments` is untouched.
    static func select(_ arguments: inout [String], environment: [String: String]) throws -> ErrorFormat {
        let index = arguments.first == "--dry-run" ? 1 : 0
        if arguments.count > index, arguments[index] == option {
            guard arguments.count > index + 1, let chosen = ErrorFormat(rawValue: arguments[index + 1]) else {
                throw CommandFailure.usage("\(option) requires text or json.")
            }
            arguments.removeSubrange(index...(index + 1))
            return chosen
        }
        guard let value = environment[environmentVariable], !value.isEmpty else { return .text }
        guard let chosen = ErrorFormat(rawValue: value) else {
            throw CommandFailure.usage("\(environmentVariable) must be text or json.")
        }
        return chosen
    }

    /// The stderr bytes for a failure. Text is `"\(error)\n"`, unchanged.
    func render(_ error: any Error) -> Data {
        switch self {
        case .text:
            return Data("\(error)\n".utf8)
        case .json:
            let fields = CommandFailure.classify(error).fields.mapValues { $0.map { $0 as Any } ?? NSNull() }
            let data = (try? JSONSerialization.data(withJSONObject: ["error": fields], options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data(#"{"error":{"code":"internal","message":"Cannot encode the failure as JSON.","inputSent":"unknown","retry":"after-inspection","action":null}}"#.utf8)
            return data + Data("\n".utf8)
        }
    }
}
