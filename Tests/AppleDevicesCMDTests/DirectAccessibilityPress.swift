import Foundation
import Testing
@testable import AppleDevicesCMD

struct DirectAccessibilityPressTests {
    final class Wire: AccessibilitySessionTransport {
        let failure: String
        var incoming: [AccessibilityDTX] = []
        var kinds: [UInt64] = []
        var snapshots = 0, hits = 0, applications = 0
        var closed = false
        init(_ failure: String) { self.failure = failure }
        func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
            guard !incoming.isEmpty else { throw CommandFailure(description: "Fixture EOF") }
            return incoming.removeFirst()
        }
        func close() { closed = true }
        func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
            guard message.kind == .invocation else { return }
            let fixture = AccessibilitySessionTests()
            let selector = try KeyedArchiveInspector.decodeProtocol(message.object)
            if selector == .string("deviceAPIVersion") {
                incoming.append(try fixture.reply(message.identifier, value: NSNumber(value: 26))); return
            }
            if selector == .string("clientNeedsAccessibility:") {
                let enabled = try KeyedArchiveInspector.decodeProtocol(message.archiveArgument())
                if failure != "cleanup" || enabled == .boolean(true) { incoming.append(try fixture.reply(message.identifier)) }
                return
            }
            guard case .object("AXPTranslatorRequest", let fields) = try KeyedArchiveInspector.decodeProtocol(message.archiveArgument()),
                  let kind = fields["requestType"]?.unsignedInteger else { throw CommandFailure(description: "Bad fixture request") }
            kinds.append(kind)
            let response: Response
            switch kind {
            case 1:
                applications += 1
                response = Response(kind: kind, result: Token(applications == 2 && failure == "root" ? 9 : 1))
            case 2:
                snapshots += 1
                let target = snapshots == 2 && failure == "identity" ? 3 : 2
                var children = [record(target)]
                if failure == "ambiguous" { children.append(record(3)) }
                if failure == "duplicate" { children.append(record(target)) }
                if failure == "inconsistent" { children.append(record(target, shifted: true)) }
                response = Response(kind: kind, translation: Token(1), result: record(1, children: children))
            case 5:
                response = Response(kind: kind, result: [
                    21: NSValue(rect: NSRect(x: failure == "frame" ? 11 : failure == "offscreen" ? 1000 : 10, y: 20, width: 30, height: 40)),
                    25: failure == "identifier" ? "other" : "fixture.control",
                    27: failure == "unknown-state" ? NSNumber(value: 2) : NSNumber(value: failure != "disabled"), 32: failure != "hidden"] as NSDictionary)
            case 6:
                hits += 1
                response = Response(kind: kind, result: Token(hits == 2 && failure == "hit" ? 3 : 2,
                    pid: (hits == 1 && failure == "pid") || (hits == 3 && failure == "foreground") ? 43 : 42))
            case 7:
                #expect(fields["actionType"]?.unsignedInteger == 5 && fields["parameters"] == .null)
                if failure == "cancel" { throw CancellationError() }
                incoming.append(try fixture.reply(message.identifier))
                if failure == "lost" { return }
                response = Response(kind: kind, result: NSNumber(value: failure != "refused"))
                incoming.append(try callback(response)); return
            default: throw CommandFailure(description: "Unexpected fixture request")
            }
            // Semantic reply before the carrier acknowledgement exercises both
            // orderings; action replies above arrive after their carrier ack.
            incoming.append(try callback(response))
            incoming.append(try fixture.reply(message.identifier))
        }
        func record(_ id: Int, children: [NSDictionary] = [], shifted: Bool = false) -> NSDictionary {
            ["UIAccessibilitySnapshotKeyElement": Token(id), "UIAccessibilitySnapshotKeyChildren": children,
                "UIAccessibilitySnapshotKeyChildrenCount": children.count,
                "UIAccessibilitySnapshotKeyAttributes": [2001: id == 1 ? "App" : "Fixture", 5019: id == 1 ? "app" : "fixture.control",
                    2003: NSValue(rect: NSRect(x: shifted ? 11 : failure == "offscreen" ? 1000 : 10, y: 20, width: 30, height: 40)), 2025: true] as NSDictionary] as NSDictionary
        }
        func callback(_ response: Response) throws -> AccessibilityDTX {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            coder.setClassName("AXPTranslatorResponse", for: Response.self)
            coder.setClassName("AXPTranslationObject", for: Token.self)
            coder.encode(response, forKey: NSKeyedArchiveRootObjectKey); coder.finishEncoding()
            if let error = coder.error { throw error }
            return try AccessibilityDTX.invocation("processDataFromRemoteDevice:", argument: coder.encodedData as NSData, identifier: 90)
        }
    }

    @Test(arguments: ["none", "duplicate", "ambiguous", "inconsistent", "identity", "disabled", "unknown-state", "hidden", "identifier", "frame", "offscreen", "hit", "root", "foreground", "pid", "display", "refused", "lost", "cleanup", "cancel"])
    func actionGuardsAndUnknownOutcomesNeverReplay(_ failure: String) throws {
        let wire = Wire(failure)
        let press = try DirectAccessibilityPress(.init(device: "fixture", operation: "press-id", operands: ["42", "fixture.control"]))
        var displays = 0
        let run = {
            try press.execute(session: AccessibilitySession(transport: wire), display: {
                displays += 1
                return try AccessibilityDisplay(AccessibilityDisplayTests.data(scale: failure == "display" && displays == 2 ? 2 : 3))
            })
        }
        if ["none", "duplicate", "cleanup"].contains(failure) {
            let result = try #require(JSONSerialization.jsonObject(with: run()) as? [String: Any])
            #expect(result["nativeAccepted"] as? Bool == true && result["effectVerified"] as? Bool == false)
            #expect((result["cleanup"] as? [String: Any])?["confirmed"] as? Bool == (failure != "cleanup"))
            #expect(String(describing: result).contains("rawElementData") == false)
        } else if failure == "cancel" {
            #expect(throws: CancellationError.self) { try run() }
        } else {
            do { _ = try run(); Issue.record("Guard failed open") }
            catch {
                let state = ["refused", "lost"].contains(failure) ? (failure == "refused" ? "refused" : "submitted") : "not-sent"
                #expect(String(describing: error).contains("state=\(state)"))
            }
        }
        #expect(wire.closed)
        #expect(wire.kinds.filter { $0 == 7 }.count == (["none", "duplicate", "cleanup", "refused", "lost", "cancel"].contains(failure) ? 1 : 0))
    }

    @objc(ADCAXPressTestToken)
    final class Token: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let id: Int
        let pid: Int32
        init(_ id: Int, pid: Int32 = 42) { self.id = id; self.pid = pid }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(pid, forKey: "pid"); coder.encode(NSNumber(value: id), forKey: "objectID")
            coder.encode(id == 1, forKey: "isApplicationElement"); coder.encode(true, forKey: "didPopuldateAppInfo")
            coder.encode(nil as NSObject?, forKey: "rawElementData"); coder.encode(nil as NSObject?, forKey: "bridgeDelegateToken")
        }
    }
    @objc(ADCAXPressTestResponse)
    final class Response: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: UInt64
        let translation: Token?
        let result: NSObject
        init(kind: UInt64, translation: Token? = nil, result: NSObject) { self.kind = kind; self.translation = translation; self.result = result }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(Int(kind), forKey: "associatedRequestType"); coder.encode(kind == 2 ? 52 : 0, forKey: "attribute")
            coder.encode(0, forKey: "error"); coder.encode(0, forKey: "notification")
            coder.encode(translation, forKey: "associatedTranslationObject"); coder.encode(result, forKey: "resultData")
        }
    }
}
