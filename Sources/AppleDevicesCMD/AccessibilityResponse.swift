import Foundation

/// A semantic callback, separate from the DTX acknowledgement for its carrier.
/// One request may be outstanding; a timeout must end the owning session rather
/// than reuse it because AXP does not provide a request sequence identifier.
struct AccessibilityResponse: Sendable {
    enum Expected: Sendable {
        case application(pid: Int32)
        case snapshot(AccessibilityRequest.Token)
        case attributes(AccessibilityRequest.Token)
    }

    let requestType: UInt64
    let attribute: UInt64
    let error: Int64
    let notification: UInt64
    let translation: AccessibilityArchiveValue
    let result: AccessibilityArchiveValue

    init(archive: Data) throws {
        try self.init(value: KeyedArchiveInspector.decodeProtocol(archive))
    }

    init(value: AccessibilityArchiveValue) throws {
        guard case .object("AXPTranslatorResponse", let fields) = value,
              let type = fields["associatedRequestType"]?.unsignedInteger,
              let attribute = fields["attribute"]?.unsignedInteger,
              let notification = fields["notification"]?.unsignedInteger,
              let errorValue = fields["error"], let error = Self.signedInteger(errorValue),
              let translation = fields["associatedTranslationObject"], let result = fields["resultData"] else {
            throw Self.invalid("missing response class or typed fields")
        }
        self.requestType = type
        self.attribute = attribute
        self.error = error
        self.notification = notification
        self.translation = translation
        self.result = result
    }

    /// nil means an unrelated response, not a successful empty result.
    /// A matching refusal, target mismatch or nil result terminates the request.
    func matchingResult(for expected: Expected) throws -> AccessibilityArchiveValue? {
        let kind: UInt64
        switch expected {
        case .application: kind = 1
        case .snapshot: kind = 2
        case .attributes: kind = 5
        }
        guard requestType == kind else { return nil }
        guard notification == 0, error == 0 else { throw Self.invalid("semantic refusal or notification in request response (error \(error))") }
        switch expected {
        case .application(let pid):
            let token = try Self.token(result)
            guard pid > 0, token.pid == pid, token.isApplicationElement else {
                throw Self.invalid("application result PID or application flag mismatch")
            }
            guard attribute == 0 else { throw Self.invalid("application attribute mismatch") }
        case .snapshot(let token), .attributes(let token):
            let actual = try Self.token(translation)
            guard actual.pid == token.pid, actual.objectID == token.objectID else {
                throw Self.invalid("response translation identity mismatch")
            }
            guard attribute == (kind == 2 ? 52 : 0) else { throw Self.invalid("response attribute mismatch") }
            if kind == 5 {
                guard case .dictionary = result else { throw Self.invalid("attribute response is not a dictionary") }
            }
        }
        guard result != .null else { throw Self.invalid("request returned no data") }
        return result
    }

    static func token(_ value: AccessibilityArchiveValue) throws -> AccessibilityRequest.Token {
        guard case .object("AXPTranslationObject", let fields) = value,
              let pidValue = fields["pid"]?.unsignedInteger, let pid = Int32(exactly: pidValue), pid > 0,
              let identity = fields["objectID"],
              case .boolean(let application) = fields["isApplicationElement"],
              case .boolean(let populated) = fields["didPopuldateAppInfo"] else {
            throw invalid("translation class, PID, identity or flags")
        }
        let objectID: UInt64
        switch identity {
        case .unsigned(let value): objectID = value
        case .signed(let value): objectID = UInt64(bitPattern: value)
        default: throw invalid("non-integer translation identity")
        }
        func bytes(_ key: String) throws -> Data? {
            switch fields[key] {
            case .null: return nil
            case .data(let bytes): return bytes
            default: throw invalid("translation \(key) is not data or nil")
            }
        }
        return try AccessibilityRequest.Token(pid: pid, objectID: objectID,
            rawElementData: bytes("rawElementData"), bridgeDelegateToken: bytes("bridgeDelegateToken"),
            isApplicationElement: application, didPopulateAppInfo: populated)
    }

    private static func signedInteger(_ value: AccessibilityArchiveValue) -> Int64? {
        switch value {
        case .signed(let value): return value
        case .unsigned(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    private static func invalid(_ reason: String) -> CommandFailure {
        CommandFailure(description: "Invalid accessibility response: \(reason).")
    }
}
