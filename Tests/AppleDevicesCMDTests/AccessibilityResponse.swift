import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilityResponseTests {
    @Test func actionRepliesRequireCapturedNilTranslationAndKnownBooleanShape() throws {
        for result: Value in [.boolean(true), .boolean(false), .signed(0), .unsigned(1)] {
            #expect(try AccessibilityResponse(value: response(kind: .signed(7), attribute: .signed(0), translation: .null, result: result))
                .matchingResult(for: .action) == result)
        }
        for value in [response(kind: .signed(7), attribute: .signed(0), result: .boolean(true)),
                      response(kind: .signed(7), attribute: .signed(52), translation: .null, result: .boolean(true)),
                      response(kind: .signed(7), attribute: .signed(0), translation: .null, result: .real(1)),
                      response(kind: .signed(7), attribute: .signed(0), translation: .null, result: .unsigned(2)),
                      response(kind: .signed(7), attribute: .signed(0), translation: .null, result: .null),
                      response(kind: .signed(7), attribute: .signed(0), translation: .null, result: .boolean(true), error: .signed(1))] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value).matchingResult(for: .action) }
        }
    }
    @Test func pointResultsRequireNativeTokenAndZeroAttributeWithoutAnApplicationFlag() throws {
        let result = token(application: false)
        #expect(try AccessibilityResponse(value: response(kind: .signed(6), attribute: .signed(0), result: result))
            .matchingResult(for: .hit) == result)
        for value in [response(kind: .signed(6), attribute: .signed(1), result: result),
                      response(kind: .signed(6), attribute: .signed(0), result: token(pid: .signed(0))),
                      response(kind: .signed(6), attribute: .signed(0), result: .null),
                      response(kind: .signed(6), attribute: .signed(0), result: result, error: .signed(1))] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value).matchingResult(for: .hit) }
        }
        #expect(try AccessibilityResponse(value: response()).matchingResult(for: .hit) == nil)
    }
    typealias Value = AccessibilityArchiveValue

    private func token(pid: Value = .signed(42), identity: Value = .unsigned(.max), application: Bool = true) -> Value {
        .object(className: "AXPTranslationObject", fields: [
            "pid": pid, "objectID": identity, "rawElementData": .data(Data("bplist00opaque".utf8)),
            "bridgeDelegateToken": .null, "isApplicationElement": .boolean(application),
            "didPopuldateAppInfo": .boolean(true)
        ])
    }

    private func response(kind: Value = .signed(2), attribute: Value = .signed(52),
                          translation: Value? = nil, result: Value = .dictionary([:]),
                          error: Value = .signed(0), notification: Value = .signed(0)) -> Value {
        .object(className: "AXPTranslatorResponse", fields: [
            "associatedRequestType": kind, "attribute": attribute, "error": error,
            "notification": notification, "associatedTranslationObject": translation ?? token(), "resultData": result
        ])
    }

    @Test func matchingSnapshotsRejectUnrelatedCallbacksAndWrongTargets() throws {
        let expected = AccessibilityResponse.Expected.snapshot(try AccessibilityResponse.token(token()))
        let result = Value.dictionary(["fixture": .string("snapshot")])
        #expect(try AccessibilityResponse(value: response(result: result)).matchingResult(for: expected) == result)
        // Unrelated types are ignored even if their semantic result is an error.
        #expect(try AccessibilityResponse(value: response(kind: .signed(11), error: .signed(4))).matchingResult(for: expected) == nil)
        let invalid = [response(attribute: .signed(129)), response(error: .signed(4)),
                       response(notification: .signed(1)), response(result: .null),
                       response(translation: token(pid: .signed(43))),
                       response(translation: token(identity: .unsigned(1))), response(translation: .null)]
        for value in invalid {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value).matchingResult(for: expected) }
        }
    }

    @Test func applicationAndAttributeResultsHaveTheirOwnGuards() throws {
        let expected = AccessibilityResponse.Expected.application(pid: 42)
        #expect(try AccessibilityResponse(value: response(kind: .signed(1), attribute: .signed(0), result: token()))
            .matchingResult(for: expected) == token())
        for value in [response(kind: .signed(1), attribute: .signed(0), result: token(pid: .signed(43))),
                      response(kind: .signed(1), attribute: .signed(0), result: token(application: false)),
                      response(kind: .signed(1), attribute: .signed(52), result: token()),
                      response(kind: .signed(1), attribute: .signed(0), result: .null)] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value).matchingResult(for: expected) }
        }
        let attrs = AccessibilityResponse.Expected.attributes(try AccessibilityResponse.token(token()))
        let data = Value.dictionary(["21": .string("frame")])
        #expect(try AccessibilityResponse(value: response(kind: .signed(5), attribute: .signed(0), translation: .null, result: data))
            .matchingResult(for: attrs) == data)
        #expect(try AccessibilityResponse(value: response(kind: .signed(5), attribute: .signed(0), result: data))
            .matchingResult(for: attrs) == data)
        for value in [response(kind: .signed(5), attribute: .signed(52)),
                      response(kind: .signed(5), attribute: .signed(0), result: .boolean(false)),
                      response(kind: .signed(5), attribute: .signed(0), translation: token(pid: .signed(43)), result: data)] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value).matchingResult(for: attrs) }
        }
    }

    @Test func tokensPreserveBitPatternsAndRejectNonIntegerIdentities() throws {
        for identity: Value in [.unsigned(.max), .signed(-1)] {
            let decoded = try AccessibilityResponse.token(token(identity: identity))
            #expect(decoded.objectID == UInt64.max && decoded.pid == 42)
            #expect(decoded.rawElementData == Data("bplist00opaque".utf8))
            #expect(decoded.bridgeDelegateToken == nil)
        }
        for value in [token(pid: .boolean(true)), token(pid: .real(42)), token(pid: .signed(0)),
                      token(pid: .unsigned(UInt64(Int32.max) + 1)), token(identity: .real(1)),
                      token(identity: .boolean(true)), .dictionary([:])] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse.token(value) }
        }
        guard case .object(let name, let fields) = token() else { Issue.record("Invalid token fixture"); return }
        for (key, value): (String, Value?) in [("rawElementData", .string("not bytes")),
                                              ("bridgeDelegateToken", .data(Data(count: 1_048_577))),
                                              ("isApplicationElement", .signed(1)),
                                              ("didPopuldateAppInfo", nil)] {
            var altered = fields
            altered[key] = value
            #expect(throws: CommandFailure.self) {
                try AccessibilityResponse.token(.object(className: name, fields: altered))
            }
        }
    }

    @Test func opaqueDataExpansionUsesTheSharedByteBudget() throws {
        // Shared UID references keep the input small; expanded raw token data
        // must still be charged for each reference instead of bypassing limits.
        let shared = Data(count: 1_048_576) as NSData
        let repeated = Array(repeating: shared, count: 33) as NSArray
        let archive = try NSKeyedArchiver.archivedData(withRootObject: repeated, requiringSecureCoding: true)
        #expect(archive.count < KeyedArchiveInspector.maximumBytes)
        #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.decodeProtocol(archive) }
    }

    @Test func refusesMalformedResponseScalarsAndMissingFields() throws {
        for value in [response(kind: .boolean(true)), response(attribute: .real(52)),
                      response(error: .boolean(false)), response(error: .unsigned(.max)),
                      response(notification: .real(0)), .object(className: "OtherClass", fields: [:]),
                      .object(className: "AXPTranslatorResponse", fields: [:]), .dictionary([:])] {
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(value: value) }
        }
    }

    @Test func binaryCallbackEnvelopePreservesDataAndNumericTypes() throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorResponse", for: CallbackFixture.self)
        coder.encode(CallbackFixture(), forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        let direct = coder.encodedData
        let wrapped = try NSKeyedArchiver.archivedData(withRootObject: direct as NSData, requiringSecureCoding: true)
        for bytes in [direct, wrapped] {
            let decoded = try AccessibilityResponse(archive: bytes)
            #expect(decoded.requestType == 11 && decoded.error == 0)
            guard case .dictionary(let result) = decoded.result else { Issue.record("Missing result dictionary"); return }
            #expect(result["opaque"] == .data(Data("bplist00opaque".utf8)))
            #expect(result["identity"]?.unsignedInteger == UInt64.max)
            #expect(result["enabled"] == .boolean(true))
            #expect(result["fraction"] == .real(1.5))
        }
        // One transport envelope is allowed; arbitrary recursive NSData is not.
        let twice = try NSKeyedArchiver.archivedData(withRootObject: wrapped as NSData, requiringSecureCoding: true)
        #expect(throws: CommandFailure.self) { try AccessibilityResponse(archive: twice) }
        // The offline inspector still treats plist-looking opaque bytes as a
        // nested archive and rejects the deliberately invalid fixture content.
        #expect(throws: (any Error).self) { try KeyedArchiveInspector.inspect(direct) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_AX_CALLBACK_FILE"] != nil))
    func explicitlySelectedHistoricalCallbackDecodesWithoutRuntimeClasses() throws {
        let path = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_AX_CALLBACK_FILE"])
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let bytes = try #require(try file.read(upToCount: KeyedArchiveInspector.maximumBytes + 1))
        let response = try AccessibilityResponse(archive: bytes)
        #expect(response.requestType == 11 && response.error == 0)
        guard case .dictionary(let result) = response.result,
              case .array(let entries) = result["treeDump"] else { Issue.record("Missing historical callback records"); return }
        #expect(entries.isEmpty == false)
        for entry in entries { _ = try AccessibilityResponse(value: entry) }
    }

    @objc(ADCAXCallbackTestArchive)
    private final class CallbackFixture: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        override init() {}
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(11, forKey: "associatedRequestType")
            coder.encode(0, forKey: "attribute")
            coder.encode(0, forKey: "error")
            coder.encode(0, forKey: "notification")
            coder.encode(nil as NSObject?, forKey: "associatedTranslationObject")
            coder.encode(["opaque": Data("bplist00opaque".utf8), "identity": NSNumber(value: UInt64.max),
                          "enabled": true, "fraction": 1.5] as NSDictionary, forKey: "resultData")
        }
    }
}
