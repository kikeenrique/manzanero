import Foundation
import Testing
@testable import AppleDevicesCMD

struct MediaRTPPacketTests {
    static let header: [UInt8] = [0x80, 0xe4, 0xff, 0xff, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]

    @Test func fixedHeaderAndNonzeroDataIndices() throws {
        let data = Data([0xaa] + Self.header + [0x65, 1, 2]).dropFirst()
        let packet = try #require(MediaRTPPacket(data, payloadType: 100))
        #expect(packet.sequence == .max && packet.timestamp == 0x01234567 && packet.source == 0x89abcdef)
        #expect(packet.marker && packet.payload == Data([0x65, 1, 2]))
    }

    @Test func csrcExtensionAndPaddingAreExcluded() throws {
        var bytes = Self.header
        bytes[0] = 0xb1 // V2, padding, extension, one CSRC
        bytes += [0, 0, 0, 4] // CSRC
        bytes += [0xbe, 0xde, 0, 1, 1, 2, 3, 4] // one extension word
        bytes += [0x61, 7, 0, 2]
        let packet = try #require(MediaRTPPacket(Data(bytes), payloadType: 100))
        #expect(packet.payload == Data([0x61, 7]))
    }

    @Test(arguments: ["short", "version", "payload", "csrc", "extension-header", "extension-body", "zero-padding", "all-padding", "oversized"])
    func malformedPacketsAreRejected(mutation: String) {
        var bytes = Self.header + [0x65]
        switch mutation {
        case "short": bytes = Array(bytes.prefix(11))
        case "version": bytes[0] = 0x40
        case "payload": bytes[1] = 99
        case "csrc": bytes[0] = 0x8f
        case "extension-header": bytes[0] = 0x90
        case "extension-body": bytes[0] = 0x90; bytes += [0, 0, 0xff, 0xff]
        case "zero-padding": bytes[0] = 0xa0; bytes += [0]
        case "all-padding": bytes[0] = 0xa0; bytes[12] = 1
        case "oversized": bytes += Array(repeating: 0, count: 65_536)
        default: break
        }
        #expect(MediaRTPPacket(Data(bytes), payloadType: 100) == nil)
    }
}
