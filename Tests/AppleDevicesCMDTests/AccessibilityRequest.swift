import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilityRequestTests {
    @Test func pressUsesFreshTokenNilParametersAndCapturedActionFive() throws {
        let bytes = try AccessibilityRequest.press(.init(pid: 42, objectID: 9, rawElementData: Data([1, 2])))
        guard case .object("AXPTranslatorRequest", let fields) = try KeyedArchiveInspector.decodeProtocol(bytes),
              case .object("AXPTranslationObject", let token) = fields["translation"] else { Issue.record("Invalid action archive"); return }
        #expect(fields["requestType"]?.unsignedInteger == 7 && fields["actionType"]?.unsignedInteger == 5)
        #expect(fields["clientType"]?.unsignedInteger == 0 && fields["attributeType"]?.unsignedInteger == 0)
        #expect(fields["parameters"] == .null)
        #expect(token["objectID"]?.unsignedInteger == 9 && token["pid"]?.unsignedInteger == 42)
        #expect(token["rawElementData"] == .data(Data([1, 2])))
    }
    @Test func pointQueryUsesCapturedNSValueShapeWithoutRelaxingNativeTokens() throws {
        let bytes = try AccessibilityRequest.hit(x: 187.5, y: 406)
        let plist = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let objects = try #require(plist["$objects"] as? [Any])
        let rawToken = try #require(objects.compactMap { $0 as? [String: Any] }.first { $0["pid"] != nil })
        #expect(rawToken["pid"] as? Int32 == 0)
        let request = try fields(bytes)
        #expect(request["requestType"] as? Int == 6 && request["attributeType"] as? Int == 0)
        let parameters = try #require(request["parameters"] as? [String: Any])
        #expect(parameters["displayId"] as? Int == 0)
        let point = try #require(parameters["point"] as? [String: Any])
        #expect(point["className"] as? String == "NSValue")
        let pointFields = try #require(point["fields"] as? [String: Any])
        #expect(pointFields["NS.special"] as? Int == 1)
        #expect(pointFields["NS.pointval"] as? String == "{187.5, 406}")
        let translation = try #require(request["translation"] as? [String: Any])
        let token = try #require(translation["fields"] as? [String: Any])
        #expect(token["pid"] as? Int == 0)
        #expect(token["isApplicationElement"] as? Bool == false)
        #expect(token["didPopuldateAppInfo"] as? Bool == false)
        #expect(token["rawElementData"] is NSNull && token["bridgeDelegateToken"] is NSNull)
        #expect(throws: CommandFailure.self) { try AccessibilityRequest.hit(x: .nan, y: 0) }
        #expect(throws: CommandFailure.self) { try AccessibilityRequest.hit(x: 0, y: .infinity) }
        #expect(throws: CommandFailure.self) { try AccessibilityRequest.Token(pid: 0, objectID: 1) }
    }
    private func fields(_ bytes: Data) throws -> [String: Any] {
        let inspected = try #require(try JSONSerialization.jsonObject(with: KeyedArchiveInspector.inspect(bytes)) as? [String: Any])
        let root = try #require(inspected["decoded"] as? [String: Any])
        #expect(root["className"] as? String == "AXPTranslatorRequest")
        let fields = try #require(root["fields"] as? [String: Any])
        #expect(fields["clientType"] as? Int == 0)
        #expect(fields["actionType"] as? Int == 0)
        return fields
    }

    @Test func applicationRequestUsesNoTranslationAndPositivePID() throws {
        let request = try fields(AccessibilityRequest.application(pid: 42))
        #expect(request["requestType"] as? Int == 1 && request["attributeType"] as? Int == 0)
        #expect(request["translation"] is NSNull)
        #expect((request["parameters"] as? [String: Int]) == ["pid": 42])
        for pid: Int32 in [0, -1, .min] {
            #expect(throws: CommandFailure.self) { try AccessibilityRequest.application(pid: pid) }
        }
    }

    @Test func snapshotPreservesUnsignedIdentityAndBoundedOptions() throws {
        let token = try AccessibilityRequest.Token(pid: 42, objectID: UInt64.max,
            rawElementData: Data([1, 2, 3]), bridgeDelegateToken: Data([4]),
            isApplicationElement: true, didPopulateAppInfo: true)
        let bytes = try AccessibilityRequest.snapshot(token)
        let request = try fields(bytes)
        #expect(request["requestType"] as? Int == 2 && request["attributeType"] as? Int == 52)
        let translation = try #require(request["translation"] as? [String: Any])
        #expect(translation["className"] as? String == "AXPTranslationObject")
        let identity = try #require(translation["fields"] as? [String: Any])
        #expect(identity["pid"] as? Int == 42)
        #expect((identity["objectID"] as? NSNumber)?.uint64Value == UInt64.max)
        #expect(identity["isApplicationElement"] as? Bool == true)
        #expect(identity["didPopuldateAppInfo"] as? Bool == true)
        #expect((identity["rawElementData"] as? [String: Int]) == ["dataBytes": 3])
        #expect((identity["bridgeDelegateToken"] as? [String: Int]) == ["dataBytes": 1])
        // Inspection deliberately redacts opaque bytes. Check the raw archive
        // separately so equal-length corruption cannot pass the round trip.
        let envelope = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let objects = try #require(envelope["$objects"] as? [Any])
        #expect(objects.contains { $0 as? Data == Data([1, 2, 3]) })
        #expect(objects.contains { $0 as? Data == Data([4]) })
        let parameters = try #require(request["parameters"] as? [String: Any])
        let options = try #require(parameters["parameter"] as? [String: Any])
        #expect(options["attributes"] as? [Int] == [2001, 2002, 2003, 2004, 5019, 2006, 2025, 5003, 5004, 3003])
        #expect(options["maxDepth"] as? Int == 48 && options["maxChildren"] as? Int == 512)
        #expect(options["maxArrayCount"] as? Int == 512)
        #expect(options["traverseFromParentsToChildren"] as? Bool == true)
        #expect(options["snapshotKeyHonorModalViews"] as? Bool == false)
    }

    @Test func attributeQueriesAreReadOnlyAndRejectUnknownOrDuplicateIDs() throws {
        let token = try AccessibilityRequest.Token(pid: 42, objectID: 0)
        let request = try fields(AccessibilityRequest.attributes([21, 25, 27, 32], of: token))
        #expect(request["requestType"] as? Int == 5 && request["attributeType"] as? Int == 0)
        #expect((request["parameters"] as? [String: [Int]]) == ["attributes": [21, 25, 27, 32]])
        let translation = try #require(request["translation"] as? [String: Any])
        let identity = try #require(translation["fields"] as? [String: Any])
        #expect(identity["rawElementData"] is NSNull && identity["bridgeDelegateToken"] is NSNull)
        #expect(identity["isApplicationElement"] as? Bool == false)
        #expect(identity["didPopuldateAppInfo"] as? Bool == false)
        for attributes in [[], [21, 21], [999], [3, 8, 21, 25, 27, 32, 53, 3]] {
            #expect(throws: CommandFailure.self) { try AccessibilityRequest.attributes(attributes, of: token) }
        }
    }

    @Test func tokenRejectsInvalidPIDAndCombinedDataBudget() throws {
        #expect(throws: CommandFailure.self) { try AccessibilityRequest.Token(pid: 0, objectID: 1) }
        #expect(throws: CommandFailure.self) {
            try AccessibilityRequest.Token(pid: 42, objectID: 1, rawElementData: Data(count: 1_048_577))
        }
        #expect(throws: CommandFailure.self) {
            try AccessibilityRequest.Token(pid: 42, objectID: 1,
                rawElementData: Data(count: 1_048_576), bridgeDelegateToken: Data([0]))
        }
    }

    @Test func requestIsNestedNSDataInDTXArgument() throws {
        let bytes = try AccessibilityRequest.application(pid: 42)
        let invocation = try AccessibilityDTX.invocation("processDataFromHost:", argument: bytes as NSData, identifier: 1)
        let inspected = try #require(try JSONSerialization.jsonObject(with: KeyedArchiveInspector.inspect(invocation.archiveArgument())) as? [String: Any])
        let wrapped = try #require(inspected["decoded"] as? [String: Any])
        #expect(wrapped["byteCount"] as? Int == bytes.count)
        let nested = try #require(wrapped["nestedArchive"] as? [String: Any])
        #expect(nested["className"] as? String == "AXPTranslatorRequest")
    }
}
