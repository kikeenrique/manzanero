import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilityResponseTypeTests {
    static func archive(kind: NSNumber = 11) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorResponse", for: Fixture.self)
        coder.encode(Fixture(kind), forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        if let error = coder.error { throw error }
        return coder.encodedData
    }

    @Test func typeProjectionDoesNotExpandUnrelatedNotificationResults() throws {
        let direct = try Self.archive()
        let wrapped = try NSKeyedArchiver.archivedData(withRootObject: direct as NSData, requiringSecureCoding: true)
        for bytes in [direct, wrapped] {
            #expect(try KeyedArchiveInspector.protocolResponseType(bytes) == 11)
            #expect(throws: CommandFailure.self) { try AccessibilityResponse(archive: bytes) }
        }
        for kind in [NSNumber(value: true), NSNumber(value: 1.5), NSNumber(value: -1)] {
            #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.protocolResponseType(Self.archive(kind: kind)) }
        }
        let wrong = try NSKeyedArchiver.archivedData(withRootObject: ["associatedRequestType": 6] as NSDictionary, requiringSecureCoding: true)
        #expect(throws: CommandFailure.self) { try KeyedArchiveInspector.protocolResponseType(wrong) }
    }

    @Test func unrelatedNaNNotificationCannotSatisfyHitAndMatchingNaNStillCloses() throws {
        let fixture = AccessibilitySessionTests()
        for kind in [11, 6] {
            let notification = try AccessibilityDTX.invocation("processDataFromRemoteDevice:", argument: Self.archive(kind: NSNumber(value: kind)) as NSData, identifier: 99)
            var frames = [try fixture.reply(1, value: NSNumber(value: 26)), try fixture.reply(2), try fixture.reply(3), notification]
            if kind == 11 { frames.append(try fixture.callback(kind: 6)) }
            frames.append(try fixture.reply(4))
            let wire = AccessibilitySessionTests.Transport(frames)
            let session = AccessibilitySession(transport: wire)
            try session.start()
            if kind == 11 { #expect(try session.hit(x: 187.5, y: 406).pid == 42) }
            else { #expect(throws: CommandFailure.self) { try session.hit(x: 187.5, y: 406) } }
            #expect(session.close() == .stopAcknowledged && wire.closed && wire.incoming.isEmpty)
        }
    }

    @objc(ADCAXTypeProjectionFixture)
    private final class Fixture: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: NSNumber
        init(_ kind: NSNumber) { self.kind = kind }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(kind, forKey: "associatedRequestType")
            coder.encode(0, forKey: "attribute")
            coder.encode(0, forKey: "error")
            coder.encode(0, forKey: "notification")
            coder.encode(nil as NSObject?, forKey: "associatedTranslationObject")
            coder.encode(["unrelated": Double.nan] as NSDictionary, forKey: "resultData")
        }
    }
}
