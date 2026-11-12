import Foundation
import Testing
@testable import AppleDevicesCMD

struct AccessibilityDTXTests {
    private func decode(_ bytes: Data) throws -> AccessibilityDTX {
        var remaining = bytes
        let result = try AccessibilityDTX.read { count in
            guard count <= remaining.count else { throw CommandFailure(description: "fixture truncated") }
            let result = Data(remaining.prefix(count))
            remaining.removeFirst(count)
            return result
        }
        #expect(remaining.isEmpty)
        return result
    }

    private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }

    @Test func independentEmptyAcknowledgementFixture() throws {
        // Header magic/size, fragment 0 of 1, 16-byte payload, ID 7,
        // conversation 1, channel -3, no reply; empty payload header.
        let bytes = Data([0x79, 0x5b, 0x3d, 0x1f, 32, 0, 0, 0, 0, 0, 1, 0, 16, 0, 0, 0,
                          7, 0, 0, 0, 1, 0, 0, 0, 0xfd, 0xff, 0xff, 0xff, 0, 0, 0, 0] + Array(repeating: 0, count: 16))
        let message = try decode(bytes)
        #expect(message.identifier == 7 && message.conversation == 1 && message.channel == -3)
        #expect(message.kind == .acknowledgement && message.expectsReply == false)
        #expect(message.auxiliary.isEmpty && message.object.isEmpty)
        #expect(try message.encoded() == bytes)
    }

    @Test func outboundSubscriptionHasSeparateSelectorAndArchivedArgument() throws {
        let message = try AccessibilityDTX.invocation("clientNeedsAccessibility:", argument: NSNumber(value: true), identifier: 42)
        let decoded = try decode(message.encoded())
        #expect(decoded.identifier == 42 && decoded.channel == 0 && decoded.conversation == 0)
        #expect(decoded.kind == .invocation && decoded.expectsReply)
        // Parse only property-list containers, never instantiate archived classes.
        let selector = try #require(try PropertyListSerialization.propertyList(from: decoded.object, format: nil) as? [String: Any])
        let objects = try #require(selector["$objects"] as? [Any])
        #expect(objects.contains { $0 as? String == "clientNeedsAccessibility:" })
        let argument = try #require(try PropertyListSerialization.propertyList(from: decoded.archiveArgument(), format: nil) as? [String: Any])
        #expect(argument["$archiver"] as? String == "NSKeyedArchiver")
        #expect((argument["$objects"] as? [Any])?.contains { ($0 as? NSNumber)?.boolValue == true } == true)
    }

    @Test func fragmentedMessageUsesDeclarationThenCorrelatedFragments() throws {
        let original = try AccessibilityDTX.invocation("processDataFromRemoteDevice:", argument: NSData(data: Data("fixture".utf8)), identifier: 9)
        let encoded = try original.encoded()
        let body = Data(encoded.dropFirst(32)), split = 23
        var declaration = Data(encoded.prefix(32))
        put(UInt16(3), at: 10, in: &declaration)
        func fragment(_ index: UInt16, _ payload: Data) -> Data {
            var header = declaration
            put(index, at: 8, in: &header)
            put(UInt32(payload.count), at: 12, in: &header)
            return header + payload
        }
        let first = fragment(1, Data(body.prefix(split))), second = fragment(2, Data(body.dropFirst(split)))
        let decoded = try decode(declaration + first + second)
        #expect(decoded.object == original.object && decoded.auxiliary == original.auxiliary)
        for offset in [8, 10, 16, 20, 24, 28] {
            var invalid = declaration + first + second
            invalid[32 + offset] ^= 1
            #expect(throws: CommandFailure.self) { try decode(invalid) }
        }
        var tooLong = declaration + first + second
        put(UInt32(body.count + 1), at: 32 + 12, in: &tooLong)
        #expect(throws: CommandFailure.self) { try decode(tooLong) }
    }

    @Test func refusesInvalidHeadersBeforeRequestingBody() throws {
        let base = try AccessibilityDTX(identifier: 1, conversation: 0, channel: 0, expectsReply: false,
            kind: .acknowledgement, auxiliary: Data(), object: Data()).encoded()
        var variants: [Data] = [Data(base.prefix(31))]
        for (offset, value): (Int, UInt32) in [(0, 0), (4, 31), (8, 0), (8, 0x0001_0001),
                                               (8, 0x0041_0000), (12, 15), (12, UInt32(AccessibilityDTX.maximumBody + 1)), (28, 2)] {
            var header = Data(base.prefix(32))
            put(value, at: offset, in: &header)
            variants.append(header)
        }
        for header in variants {
            var reads = 0
            #expect(throws: CommandFailure.self) {
                try AccessibilityDTX.read { _ in reads += 1; return header }
            }
            #expect(reads == 1)
        }
    }

    @Test func refusesMalformedPayloadAndArgumentLengths() throws {
        let invocation = try AccessibilityDTX.invocation("callback:", argument: NSData(data: Data([1, 2, 3])), identifier: 1)
        let base = try invocation.encoded()
        for (offset, value): (Int, UInt32) in [(32, 0x1002), (32, 4), (32, 0), (36, .max), (40, 1)] {
            var bytes = base
            put(value, at: offset, in: &bytes)
            #expect(throws: CommandFailure.self) { try decode(bytes) }
        }
        for offset in [0, 8, 16, 20, 24] {
            var auxiliary = invocation.auxiliary
            auxiliary[offset] ^= 1
            let message = AccessibilityDTX(identifier: 1, conversation: 0, channel: 0, expectsReply: false,
                kind: .invocation, auxiliary: auxiliary, object: invocation.object)
            #expect(throws: CommandFailure.self) { try message.archiveArgument() }
        }
        let empty = AccessibilityDTX(identifier: 1, conversation: 0, channel: 0, expectsReply: false,
            kind: .invocation, auxiliary: Data(), object: Data())
        #expect(throws: CommandFailure.self) { try empty.archiveArgument() }
    }

    @Test func correlatesRepliesWithoutTreatingCallbackAsAcknowledgement() throws {
        for conversation: UInt32 in [0, 1, 2] {
            let request = AccessibilityDTX(identifier: 12, conversation: conversation, channel: 7, expectsReply: true,
                kind: .invocation, auxiliary: Data(), object: Data())
            let reply = try request.reply()
            #expect(reply.conversation == conversation + 1)
            #expect(reply.channel == ((conversation + 1).isMultiple(of: 2) ? 7 : -7))
            #expect(reply.isReply(to: request))
            for field in 0..<5 {
                let other = AccessibilityDTX(identifier: field == 0 ? 13 : reply.identifier,
                    conversation: field == 1 ? 99 : reply.conversation, channel: field == 2 ? 3 : reply.channel,
                    expectsReply: field == 3, kind: field == 4 ? .invocation : .acknowledgement,
                    auxiliary: Data(), object: Data())
                #expect(other.isReply(to: request) == false)
            }
        }
        for (conversation, channel): (UInt32, Int32) in [(.max, 0), (0, .min)] {
            let request = AccessibilityDTX(identifier: 1, conversation: conversation, channel: channel, expectsReply: true,
                kind: .invocation, auxiliary: Data(), object: Data())
            #expect(throws: CommandFailure.self) { try request.reply() }
        }
    }

    @Test func archivesRemainOpaqueEvenWithUnrecognizedClassNames() throws {
        let hostile = Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>$classname</key><string>UnrecognizedExecutableClass</string></dict></plist>"#.utf8)
        let frame = AccessibilityDTX(identifier: 3, conversation: 0, channel: 0, expectsReply: false,
            kind: .object, auxiliary: Data(), object: hostile)
        #expect(try decode(frame.encoded()).object == hostile)
        #expect(throws: CommandFailure.self) {
            try AccessibilityDTX(identifier: 0, conversation: 0, channel: 0, expectsReply: false,
                kind: .object, auxiliary: Data(), object: Data(count: AccessibilityDTX.maximumBody)).encoded()
        }
    }
}
