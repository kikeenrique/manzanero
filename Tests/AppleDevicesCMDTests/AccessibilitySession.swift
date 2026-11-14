import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilitySessionTests {
    final class Transport: AccessibilitySessionTransport {
        var incoming: [AccessibilityDTX]
        var outgoing: [AccessibilityDTX] = []
        var closed = false
        var beforeRead: (() -> Void)?
        var writeObserver: ((AccessibilityDTX) -> Void)?
        init(_ incoming: [AccessibilityDTX]) { self.incoming = incoming }
        func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
            beforeRead?()
            if cancelled() { throw CancellationError() }
            guard !closed, !incoming.isEmpty else { throw CommandFailure(description: "fixture EOF") }
            return incoming.removeFirst()
        }
        func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
            if cancelled() { throw CancellationError() }
            guard !closed else { throw CommandFailure(description: "fixture closed") }
            outgoing.append(message)
            writeObserver?(message)
        }
        func close() { closed = true }
    }

    func reply(_ id: UInt32, value: NSObject? = nil, kind: AccessibilityDTX.Kind? = nil) throws -> AccessibilityDTX {
        let bytes = try value.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) } ?? Data()
        return AccessibilityDTX(identifier: id, conversation: 1, channel: 0, expectsReply: false,
            kind: kind ?? (bytes.isEmpty ? .acknowledgement : .object), auxiliary: Data(), object: bytes)
    }

    func callback(kind: Int, attribute: Int = 0, id: UInt32 = 90, pid: Int32 = 42,
                  rootID: UInt64 = .max, nativeSnapshot: Bool = false) throws -> AccessibilityDTX {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorResponse", for: ResponseFixture.self)
        coder.setClassName("AXPTranslationObject", for: TokenFixture.self)
        coder.encode(ResponseFixture(kind: kind, attribute: attribute, pid: pid, rootID: rootID, nativeSnapshot: nativeSnapshot), forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        return try AccessibilityDTX.invocation("processDataFromRemoteDevice:", argument: coder.encodedData as NSData, identifier: id)
    }

    private func selector(_ message: AccessibilityDTX) throws -> String? {
        guard message.kind == .invocation else { return nil }
        guard case .string(let value) = try KeyedArchiveInspector.decodeProtocol(message.object) else { return nil }
        return value
    }

    @Test func versionCallbacksAndSemanticRepliesWorkBeforeAndAfterAcknowledgements() throws {
        let host = try AccessibilityDTX.invocation("hostAPIVersion", argument: nil, identifier: 77)
        let wire = Transport([host, try reply(1, value: NSNumber(value: 26)), try reply(2),
                              try callback(kind: 1), try reply(3), try reply(4),
                              try callback(kind: 2, attribute: 52), try reply(5), try callback(kind: 5), try reply(6)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        let token = try session.application(pid: 42)
        #expect(token.pid == 42 && token.objectID == UInt64.max)
        #expect(try session.snapshot(token) == .dictionary(["fixture": .string("result")]))
        #expect(try session.attributes([21], of: token) == .dictionary(["fixture": .string("result")]))
        #expect(session.close() == .stopAcknowledged && wire.closed)
        let hostReply = try #require(wire.outgoing.first { $0.identifier == 77 })
        #expect(hostReply.kind == .object && hostReply.conversation == 1)
        #expect(try KeyedArchiveInspector.decodeProtocol(hostReply.object).unsignedInteger == 7)
        #expect(try wire.outgoing.compactMap(selector) == ["deviceAPIVersion", "clientNeedsAccessibility:",
            "processDataFromHost:", "processDataFromHost:", "processDataFromHost:", "clientNeedsAccessibility:"])
        #expect(wire.outgoing.filter { $0.identifier == 90 && $0.kind == .acknowledgement }.count == 3)
        let count = wire.outgoing.count
        #expect(session.close() == .stopAcknowledged && wire.outgoing.count == count)
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
    }

    @Test func anEmptyCarrierAcknowledgementIsNotAResultAndFailureClosesSession() throws {
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2), try reply(3), try reply(4)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        // The last ack is unrelated to request 3's semantic response, followed
        // by EOF. Cleanup is attempted and cannot claim an acknowledgement.
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
        #expect(wire.closed)
        guard case .unconfirmed = session.cleanup else { Issue.record("Cleanup incorrectly confirmed"); return }
        #expect(try wire.outgoing.compactMap(selector).last == "clientNeedsAccessibility:")
        let count = wire.outgoing.count
        #expect(throws: CommandFailure.self) { try session.start() }
        #expect(wire.outgoing.count == count)
    }

    @Test func wrongAPIVersionDoesNotSubscribeAndAmbiguousEnableAttemptsDisable() throws {
        let wrong = Transport([try reply(1, value: NSNumber(value: 25))])
        let session = AccessibilitySession(transport: wrong)
        #expect(throws: CommandFailure.self) { try session.start() }
        #expect(session.cleanup == .notSubscribed && wrong.closed)
        #expect(try wrong.outgoing.compactMap(selector) == ["deviceAPIVersion"])
        let ambiguous = Transport([try reply(1, value: NSNumber(value: 26))])
        let other = AccessibilitySession(transport: ambiguous)
        #expect(throws: CommandFailure.self) { try other.start() }
        #expect(try ambiguous.outgoing.compactMap(selector) == ["deviceAPIVersion", "clientNeedsAccessibility:", "clientNeedsAccessibility:"])
        #expect(ambiguous.closed)
    }

    @Test func matchingTargetMismatchAndDTXErrorsNeverProduceResults() throws {
        for failure in [try callback(kind: 1, pid: 43), try reply(3, kind: .error)] {
            let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2), failure, try reply(4)])
            let session = AccessibilitySession(transport: wire)
            try session.start()
            #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
            #expect(wire.closed && session.cleanup == .stopAcknowledged)
        }
    }

    @Test func cancellationStillAttemptsBoundedDisableAndNeverReplaysRead() throws {
        var cancelled = false
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2), try reply(4)])
        let session = AccessibilitySession(transport: wire, cancelled: { cancelled })
        try session.start()
        wire.writeObserver = { message in if message.identifier == 3 { cancelled = true } }
        #expect(throws: CancellationError.self) { try session.application(pid: 42) }
        #expect(session.cleanup == .stopAcknowledged && wire.closed)
        #expect(try wire.outgoing.compactMap(selector).filter { $0 == "processDataFromHost:" }.count == 1)
    }

    @Test func expiredDeadlineClosesEvenIfTransportReturnsAFrame() throws {
        var instant = ContinuousClock.now
        let wire = Transport([try reply(1, value: NSNumber(value: 26))])
        let session = AccessibilitySession(transport: wire, now: { instant })
        wire.beforeRead = { instant = instant.advanced(by: .seconds(5)) }
        #expect(throws: CommandFailure.self) { try session.start() }
        #expect(session.cleanup == .notSubscribed && wire.closed)
    }

    @Test func frameExhaustionReservesCleanupAndRefusesAnotherRequest() throws {
        let unrelated = try reply(999)
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2)]
            + Array(repeating: unrelated, count: 254) + [try reply(4)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
        #expect(session.cleanup == .stopAcknowledged && wire.closed)
        #expect(wire.incoming.isEmpty)
        let count = wire.outgoing.count
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
        #expect(wire.outgoing.count == count)
    }

    @Test func duplicateMatchingCallbacksCannotProduceAnArbitraryResult() throws {
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2),
            try callback(kind: 1), try callback(kind: 1, id: 91), try reply(3), try reply(4)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
        #expect(session.cleanup == .stopAcknowledged && wire.closed)
    }

    @Test func onlyOneRequestCanBeInFlightAndStartupCallbacksAreDiscarded() throws {
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try callback(kind: 1, pid: 43), try reply(2),
                              try reply(3), try callback(kind: 1), try reply(4)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        var attempted = false
        wire.writeObserver = { message in
            if message.identifier == 3 {
                attempted = true
                #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
            }
        }
        #expect(try session.application(pid: 42).pid == 42)
        #expect(attempted)
        #expect(session.close() == .stopAcknowledged)
    }

    @Test func unknownCallbacksAreNotAcknowledgedAsSuccessful() throws {
        let unknown = try AccessibilityDTX.invocation("unrecognized:", argument: nil, identifier: 90)
        let wire = Transport([try reply(1, value: NSNumber(value: 26)), try reply(2), unknown, try reply(4)])
        let session = AccessibilitySession(transport: wire)
        try session.start()
        #expect(throws: CommandFailure.self) { try session.application(pid: 42) }
        #expect(wire.outgoing.contains { $0.identifier == 90 } == false)
        #expect(session.cleanup == .stopAcknowledged)
    }

    @objc(ADCAXSessionTestToken)
    private final class TokenFixture: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let pid: Int32
        let objectID: UInt64
        init(pid: Int32, objectID: UInt64 = .max) { self.pid = pid; self.objectID = objectID }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(pid, forKey: "pid")
            coder.encode(NSNumber(value: objectID), forKey: "objectID")
            coder.encode(nil as NSObject?, forKey: "rawElementData")
            coder.encode(nil as NSObject?, forKey: "bridgeDelegateToken")
            coder.encode(true, forKey: "isApplicationElement")
            coder.encode(true, forKey: "didPopuldateAppInfo")
        }
    }

    @objc(ADCAXSessionTestResponse)
    private final class ResponseFixture: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: Int
        let attribute: Int
        let pid: Int32
        let rootID: UInt64
        let nativeSnapshot: Bool
        init(kind: Int, attribute: Int, pid: Int32, rootID: UInt64, nativeSnapshot: Bool) {
            self.kind = kind; self.attribute = attribute; self.pid = pid; self.rootID = rootID; self.nativeSnapshot = nativeSnapshot
        }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(kind, forKey: "associatedRequestType")
            coder.encode(attribute, forKey: "attribute")
            coder.encode(0, forKey: "error")
            coder.encode(0, forKey: "notification")
            coder.encode(kind == 1 ? nil : TokenFixture(pid: pid, objectID: rootID), forKey: "associatedTranslationObject")
            let result: NSObject
            if kind == 1 || kind == 6 { result = TokenFixture(pid: pid, objectID: rootID) }
            else if nativeSnapshot {
                result = ["UIAccessibilitySnapshotKeyElement": TokenFixture(pid: pid, objectID: rootID),
                    "UIAccessibilitySnapshotKeyAttributes": [NSNumber(value: 2001): "Fixture"],
                    "UIAccessibilitySnapshotKeyChildren": [], "UIAccessibilitySnapshotKeyChildrenCount": 0] as NSDictionary
            } else { result = ["fixture": "result"] as NSDictionary }
            coder.encode(result, forKey: "resultData")
        }
    }
}
