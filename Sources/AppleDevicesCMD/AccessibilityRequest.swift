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
                throw CommandFailure(description: "Invalid AX translation token PID or data size.")
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
        guard pid > 0 else { throw CommandFailure(description: "AX application PID must be positive.") }
        return try archive(kind: 1, parameters: ["pid": NSNumber(value: pid)], token: nil)
    }

    /// Read-only primary-display point lookup. PID zero is confined to this
    /// synthetic query translation; returned/native tokens still require PID > 0.
    static func hit(x: Double, y: Double) throws -> Data {
        guard x.isFinite, y.isFinite else { throw CommandFailure(description: "Invalid AX hit point.") }
        return try archive(kind: 6, parameters: ["point": NSValue(point: NSPoint(x: x, y: y)),
            "displayId": 0], token: nil, pointQuery: true)
    }

    static func snapshot(_ token: Token) throws -> Data {
        try archive(kind: 2, parameters: ["parameter": [
            "attributes": [2001, 2002, 2003, 2004, 5019, 2006, 2025, 5003, 5004, 3003],
            "maxDepth": 48, "maxChildren": 512, "maxArrayCount": 512,
            "traverseFromParentsToChildren": true, "snapshotKeyHonorModalViews": false
        ]], token: token)
    }

    static func attributes(_ attributes: [Int], of token: Token) throws -> Data {
        let supported: Set<Int> = [3, 8, 21, 25, 27, 32, 53]
        guard !attributes.isEmpty, attributes.count <= supported.count,
              Set(attributes).count == attributes.count, attributes.allSatisfy(supported.contains) else {
            throw CommandFailure(description: "Unsupported, duplicate or empty AX attribute query.")
        }
        return try archive(kind: 5, parameters: ["attributes": attributes], token: token)
    }

    static func action(_ token: Token, action: Action) throws -> Data {
        try archive(kind: 7, parameters: nil, token: token, action: action.rawValue)
    }

    private static func archive(kind: Int, parameters: [String: Any]?, token: Token?, pointQuery: Bool = false, action: Int = 0) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorRequest", for: RequestObject.self)
        coder.setClassName("AXPTranslationObject", for: TranslationObject.self)
        coder.encode(RequestObject(kind: kind, parameters: parameters as NSDictionary?, token: token, pointQuery: pointQuery, action: action), forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        let bytes = coder.encodedData
        guard bytes.count <= KeyedArchiveInspector.maximumBytes else {
            throw CommandFailure(description: "AX request archive exceeds byte limit.")
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

        init(kind: Int, parameters: NSDictionary?, token: Token?, pointQuery: Bool, action: Int) {
            self.kind = kind
            self.parameters = parameters
            self.token = token
            self.pointQuery = pointQuery
            self.action = action
        }

        required init?(coder: NSCoder) { return nil }

        func encode(with coder: NSCoder) {
            coder.encode(kind, forKey: "requestType")
            coder.encode(0, forKey: "clientType")
            coder.encode(action, forKey: "actionType")
            coder.encode(kind == 2 ? 52 : 0, forKey: "attributeType")
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
