import Foundation

/// AXP request archives. These are protocol values, not device-side
/// Objective-C instances. Incoming archives never instantiate these classes.
enum AccessibilityRequest {
    enum Action: Int { case press = 5, scrollToVisible = 11 }
    struct Token: Sendable {
        let pid: Int32
        let objectID: UInt64
        let rawElementData: Data?
        let bridgeDelegateToken: Data?
        let isApplicationElement: Bool
        let didPopulateAppInfo: Bool

        init(pid: Int32, objectID: UInt64, rawElementData: Data? = nil,
             bridgeDelegateToken: Data? = nil, isApplicationElement: Bool = false,
             didPopulateAppInfo: Bool = false) throws {
            guard pid > 0, (rawElementData?.count ?? 0) <= 1_048_576,
                  (bridgeDelegateToken?.count ?? 0) <= 1_048_576 - (rawElementData?.count ?? 0) else {
                throw CommandFailure(.transportFailed, "Invalid AX translation token PID or data size.", inputSent: .unknown)
            }
            self.pid = pid
            self.objectID = objectID
            self.rawElementData = rawElementData
            self.bridgeDelegateToken = bridgeDelegateToken
            self.isApplicationElement = isApplicationElement
            self.didPopulateAppInfo = didPopulateAppInfo
        }
    }

    static func application(pid: Int32) throws -> Data {
        guard pid > 0 else { throw CommandFailure(.internal, "AX application PID must be positive.", inputSent: .unknown) }
        return try archive(kind: 1, parameters: ["pid": NSNumber(value: pid)], token: nil)
    }

    /// Read-only primary-display point lookup. PID zero is confined to this
    /// synthetic query translation; returned/native tokens still require PID > 0.
    /// `container` asks with client type 2. With the default client type, a
    /// point over an area that has no accessibility element is refused
    /// (error 8); with type 2 the enclosing container answers instead. That
    /// matters when the only question is which process owns the point.
    static func hit(x: Double, y: Double, container: Bool = false) throws -> Data {
        guard x.isFinite, y.isFinite else { throw CommandFailure(.internal, "Invalid AX hit point.", inputSent: .unknown) }
        return try archive(kind: 6, parameters: ["point": NSValue(point: NSPoint(x: x, y: y)),
            "displayId": 0], token: nil, pointQuery: true, clientType: container ? 2 : 0)
    }

    /// Read-only query for the frontmost application of display 0, used by the
    /// simulator route. It carries the same synthetic PID-zero translation as
    /// a hit test; the physical route never sends it.
    static func frontmost() throws -> Data {
        try archive(kind: 4, parameters: ["displayId": 0], token: nil, pointQuery: true)
    }

    /// The snapshot depth every physical request uses.
    static let snapshotDepth = 48

    /// `maxDepth` other than 48 is used only by the simulator route's
    /// shallower retry (see `SimulatorAccessibilitySession.snapshot`).
    static func snapshot(_ token: Token, maxDepth: Int = snapshotDepth) throws -> Data {
        try archive(kind: 2, parameters: ["parameter": [
            "attributes": [2001, 2002, 2003, 2004, 5019, 2006, 2025, 5003, 5004, 3003],
            "maxDepth": maxDepth, "maxChildren": 512, "maxArrayCount": 512,
            "traverseFromParentsToChildren": true, "snapshotKeyHonorModalViews": false
        ]], token: token)
    }

    static func attributes(_ attributes: [Int], of token: Token) throws -> Data {
        let supported: Set<Int> = [3, 8, 21, 25, 27, 32, 53, focusedElementAttribute, focusedAttribute]
        guard !attributes.isEmpty, attributes.count <= supported.count,
              Set(attributes).count == attributes.count, attributes.allSatisfy(supported.contains) else {
            throw CommandFailure(.internal, "Unsupported, duplicate or empty AX attribute query.", inputSent: .unknown)
        }
        return try archive(kind: 5, parameters: ["attributes": attributes], token: token)
    }

    static func action(_ token: Token, action: Action) throws -> Data {
        try archive(kind: 7, parameters: nil, token: token, action: action.rawValue)
    }

    /// The application's focused element (19, AXFocusedUIElement) and an
    /// element's focused state (28, AXFocused), as AccessibilityPlatformTranslation
    /// maps those macOS names. Read on Apple TV simulators (docs/other-families.md).
    static let focusedElementAttribute = 19
    static let focusedAttribute = 28

    /// The value attribute (53), for the settable query and set-value below.
    static let valueAttribute = 53

    /// Whether the element's value can be set (request type 3, attribute 53).
    /// Observed in AccessibilityPlatformTranslation's own simulator traffic;
    /// sent only by the simulator route.
    static func settable(_ token: Token) throws -> Data {
        try archive(kind: 3, parameters: nil, token: token, attribute: valueAttribute)
    }

    /// Sets the element's value (request type 8, attribute 53, `value`).
    /// Sent only by the simulator route; unverified on physical devices.
    static func setValue(_ token: Token, text: String) throws -> Data {
        try archive(kind: 8, parameters: ["value": text], token: token, attribute: valueAttribute)
    }

    private static func archive(kind: Int, parameters: [String: Any]?, token: Token?, pointQuery: Bool = false, action: Int = 0,
                                clientType: Int = 0, attribute: Int? = nil) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorRequest", for: RequestObject.self)
        coder.setClassName("AXPTranslationObject", for: TranslationObject.self)
        coder.encode(RequestObject(kind: kind, parameters: parameters as NSDictionary?, token: token, pointQuery: pointQuery, action: action,
                                   clientType: clientType, attribute: attribute ?? (kind == 2 ? 52 : 0)), forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        let bytes = coder.encodedData
        guard bytes.count <= KeyedArchiveInspector.maximumBytes else {
            throw CommandFailure(.internal, "AX request archive exceeds byte limit.", inputSent: .unknown)
        }
        return bytes
    }

    @objc(ADCAXRequestArchive)
    private final class RequestObject: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: Int
        let parameters: NSDictionary?
        let token: Token?
        let pointQuery: Bool
        let action: Int
        let clientType: Int
        let attribute: Int

        init(kind: Int, parameters: NSDictionary?, token: Token?, pointQuery: Bool, action: Int, clientType: Int, attribute: Int) {
            self.kind = kind
            self.parameters = parameters
            self.token = token
            self.pointQuery = pointQuery
            self.action = action
            self.clientType = clientType
            self.attribute = attribute
        }

        required init?(coder: NSCoder) { return nil }

        func encode(with coder: NSCoder) {
            coder.encode(kind, forKey: "requestType")
            coder.encode(clientType, forKey: "clientType")
            coder.encode(action, forKey: "actionType")
            coder.encode(attribute, forKey: "attributeType")
            coder.encode(parameters, forKey: "parameters")
            coder.encode(pointQuery ? TranslationObject(pointQuery: ()) : token.map(TranslationObject.init), forKey: "translation")
        }
    }

    @objc(ADCAXTranslationArchive)
    private final class TranslationObject: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let token: Token?
        let queryID = UInt64.random(in: 1...UInt64.max)

        init(_ token: Token) { self.token = token }
        init(pointQuery: Void) { token = nil }
        required init?(coder: NSCoder) { return nil }

        func encode(with coder: NSCoder) {
            // Keep a primitive Int32 field. An optional/coalesced expression
            // can select NSCoder's object overload and archive an NSNumber UID.
            let pid: Int32 = token?.pid ?? 0
            coder.encode(pid, forKey: "pid")
            coder.encode(NSNumber(value: token?.objectID ?? queryID), forKey: "objectID")
            coder.encode(token?.rawElementData as NSData?, forKey: "rawElementData")
            coder.encode(token?.bridgeDelegateToken as NSData?, forKey: "bridgeDelegateToken")
            coder.encode(token?.isApplicationElement ?? false, forKey: "isApplicationElement")
            // The misspelling is Apple's established wire field name.
            coder.encode(token?.didPopulateAppInfo ?? false, forKey: "didPopuldateAppInfo")
        }
    }
}
