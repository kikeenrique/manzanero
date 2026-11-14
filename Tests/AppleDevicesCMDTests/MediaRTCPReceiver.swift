import Foundation
import AppleDeviceBridge
import Testing
@testable import AppleDevicesCMD

struct MediaRTCPReceiverTests {
    let sender: UInt32 = 0x55667788
    let receiver: UInt32 = 0x11223344
    func make() throws -> MediaRTCPReceiver {
        try MediaRTCPReceiver(sender: sender, receiver: receiver, payloadType: 100, cname: "t", intervalSeconds: 1, now: 0)
    }
    func append(_ word: UInt32, to data: inout Data) {
        for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: word >> shift)) }
    }
    func rtp(_ sequence: UInt16, timestamp: UInt32 = 0, source: UInt32? = nil) -> Data {
        var data = Data([0x80, 100, UInt8(sequence >> 8), UInt8(sequence & 255)])
        append(timestamp, to: &data); append(source ?? sender, to: &data); data.append(contentsOf: [2, 1, 7])
        return data
    }
    func sr(source: UInt32? = nil) -> Data {
        var data = Data([0x80, 200, 0, 6])
        for word in [source ?? sender, 0x12345678, 0x9abcdef0, 9000, 1, 100] { append(word, to: &data) }
        return data
    }
    func word(_ bytes: Data, _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    @Test func emptyReportHasExactCompoundReceiverAndCnameBytes() throws {
        var receiver = try make()
        #expect(receiver.reportIfDue(now: 999_999_999) == nil)
        let result = receiver.reportIfDue(now: 1_000_000_000)
        let report = try #require(result)
        #expect(report == Data([0x80, 201, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x81, 202, 0, 2, 0x11, 0x22, 0x33, 0x44, 1, 1, 0x74, 0]))
        #expect(receiver.reportIfDue(now: 1_999_999_999) == nil)
    }

    @Test func lossAndIntervalFractionsMatchKnownSequenceGap() throws {
        var receiver = try make()
        try receiver.observe(rtp(100), now: 100_000_000)
        try receiver.observe(rtp(102, timestamp: 9000), now: 200_000_000)
        let first = receiver.reportIfDue(now: 1_000_000_000)
        let report = try #require(first)
        #expect(report.prefix(32) == Data([0x81, 201, 0, 7, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
            85, 0, 0, 1, 0, 0, 0, 102, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        try receiver.observe(rtp(103, timestamp: 18000), now: 300_000_000)
        let next = receiver.reportIfDue(now: 2_000_000_000)
        let interval = try #require(next)
        #expect(interval[12] == 0 && interval[15] == 1) // no new loss; cumulative loss retained
    }

    @Test func wrapDuplicatesAndConfirmedRestartHaveBoundedStatistics() throws {
        var receiver = try make()
        try receiver.observe(rtp(65535), now: 0)
        try receiver.observe(rtp(0, timestamp: 9000), now: 100_000_000)
        try receiver.observe(rtp(0, timestamp: 9000), now: 101_000_000)
        let first = receiver.reportIfDue(now: 1_000_000_000)
        let report = try #require(first)
        #expect(word(report, 16) == 65536)
        #expect(Array(report[13..<16]) == [255, 255, 255]) // duplicate yields signed cumulative -1
        try receiver.observe(rtp(5000), now: 1_100_000_000) // suspicious jump alone cannot restart
        try receiver.observe(rtp(5001), now: 1_200_000_000)
        let next = receiver.reportIfDue(now: 2_000_000_000)
        let restarted = try #require(next)
        #expect(word(restarted, 16) == 5001 && word(restarted, 12) == 0)
    }

    @Test func jitterSenderReportAndDelayUseNetworkByteOrderAndFixedPoint() throws {
        var receiver = try make()
        try receiver.observe(rtp(1), now: 0)
        try receiver.observe(rtp(2, timestamp: 9000), now: 200_000_000)
        try receiver.observe(sr(), now: 500_000_000)
        let result = receiver.reportIfDue(now: 1_000_000_000)
        let report = try #require(result)
        #expect(word(report, 20) == 562)
        #expect(word(report, 24) == 0x56789abc)
        #expect(word(report, 28) == 32768)
        #expect(receiver.senderReportsObserved == 1)
    }

    @Test func malformedCompoundsCannotPartiallyUpdateSenderTiming() throws {
        var receiver = try make()
        for packet in [Data(sr().prefix(20)), sr() + Data([0]), sr() + Data([0x80, 0, 0, 0]), sr(source: 9)] {
            try receiver.observe(packet, now: 1)
            #expect(receiver.senderReportsObserved == 0)
        }
        var extended = Data([0x80, 201, 0, 255])
        extended.append(Data(repeating: 0, count: 1020)); extended.append(sr())
        try receiver.observe(extended, now: 2)
        #expect(receiver.senderReportsObserved == 1)
    }

    @Test func senderIdentityAndNegotiatedBoundsAreRequired() throws {
        var receiver = try make()
        #expect(throws: CommandFailure.self) { try receiver.observe(rtp(1, source: 99), now: 0) }
        for interval in [0.0, 0.1, 11, .nan, .infinity] {
            #expect(throws: CommandFailure.self) {
                try MediaRTCPReceiver(sender: sender, receiver: self.receiver, payloadType: 100, cname: "t", intervalSeconds: interval, now: 0)
            }
        }
        #expect(throws: CommandFailure.self) { try MediaRTCPReceiver(sender: 1, receiver: 1, payloadType: 100, cname: "t", intervalSeconds: 1, now: 0) }
        #expect(throws: CommandFailure.self) { try MediaRTCPReceiver(sender: 1, receiver: 2, payloadType: 70, cname: "t", intervalSeconds: 1, now: 0) }
    }

    @Test func compoundReportsPassNativeOwnershipBoundaryAndTamperingFails() throws {
        var receiver = try make()
        try receiver.observe(rtp(1), now: 0)
        let result = receiver.reportIfDue(now: 1_000_000_000)
        let report = try #require(result)
        func validate(_ bytes: Data) -> Int32 {
            var error = [CChar](repeating: 0, count: 512)
            return bytes.withUnsafeBytes {
                ADCValidateVideoReceiverReport($0.bindMemory(to: UInt8.self).baseAddress, $0.count, sender, self.receiver, &error, error.count)
            }
        }
        #expect(validate(report) == 0)
        for offset in [0, 1, 3, 4, 8, 32, 33, 39, 40, 41, 43] {
            var corrupt = report; corrupt[offset] ^= 0xff
            #expect(validate(corrupt) != 0, "tampered offset \(offset)")
        }
        #expect(validate(report.dropLast()) != 0)
        #expect(validate(report + Data(repeating: 0, count: 1024)) != 0)
    }
}
