import Foundation
import Testing
@testable import AppleDevicesCMD

struct MediaHEVCAssemblerTests {
    static func nal(_ type: UInt8, _ body: [UInt8] = [7]) -> Data { Data([type << 1, 1] + body) }
    static let sets = [nal(32), nal(33), nal(34)]
    static func aggregation(_ nals: [Data]) -> Data {
        var result = Data([96, 1])
        for nal in nals { result.append(contentsOf: [UInt8(nal.count >> 8), UInt8(nal.count & 255)]); result.append(nal) }
        return result
    }
    static func packet(_ payload: Data, sequence: UInt16, timestamp: UInt32 = 1, marker: Bool = true, source: UInt32 = 1) throws -> MediaRTPPacket {
        var bytes = Data([0x80, marker ? 0xe4 : 100, UInt8(sequence >> 8), UInt8(sequence & 255)])
        for word in [timestamp, source] { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: word >> shift)) } }
        bytes.append(payload)
        return try #require(MediaRTPPacket(bytes, payloadType: 100))
    }

    @Test func aggregationEstablishesConfigurationAndRandomAccess() throws {
        var assembler = MediaHEVCAssembler()
        let picture = Self.nal(19)
        let firstResult = try assembler.accept(Self.packet(Self.aggregation(Self.sets + [picture]), sequence: 1))
        let unit = try #require(firstResult)
        #expect(unit.parameterSets == Self.sets && unit.nals == Self.sets + [picture] && unit.randomAccess)
        #expect(unit.lengthPrefixed == Data([0, 0, 0, 3, 64, 1, 7, 0, 0, 0, 3, 66, 1, 7, 0, 0, 0, 3, 68, 1, 7, 0, 0, 0, 3, 38, 1, 7]))
        let nextResult = try assembler.accept(Self.packet(Self.nal(1), sequence: 2, timestamp: 2))
        let next = try #require(nextResult)
        #expect(!next.randomAccess && next.parameterSets == Self.sets)
    }

    @Test func fragmentationAndSequenceWrapReconstructOriginalNAL() throws {
        var assembler = MediaHEVCAssembler()
        #expect(try assembler.accept(Self.packet(Self.aggregation(Self.sets), sequence: 65534)) == nil)
        #expect(try assembler.accept(Self.packet(Data([98, 1, 0x93, 4, 5]), sequence: 65535, timestamp: 2, marker: false)) == nil)
        let result = try assembler.accept(Self.packet(Data([98, 1, 0x53, 6]), sequence: 0, timestamp: 2))
        let unit = try #require(result)
        #expect(unit.nals == [Self.nal(19, [4, 5, 6])])
    }

    @Test func lossGatesDependentPicturesUntilNewRandomAccess() throws {
        var assembler = MediaHEVCAssembler()
        _ = try assembler.accept(Self.packet(Self.aggregation(Self.sets + [Self.nal(19)]), sequence: 1))
        #expect(try assembler.accept(Self.packet(Self.nal(1), sequence: 3, timestamp: 2)) == nil)
        #expect(try assembler.accept(Self.packet(Self.nal(1), sequence: 4, timestamp: 3)) == nil)
        #expect(try assembler.accept(Self.packet(Self.nal(19), sequence: 5, timestamp: 4))?.randomAccess == true)
        #expect(try assembler.accept(Self.packet(Self.nal(1), sequence: 5, timestamp: 4)) == nil) // duplicate
        #expect(try assembler.accept(Self.packet(Self.nal(1), sequence: 4, timestamp: 3)) == nil) // reordered
    }

    @Test(arguments: [Data([98, 1, 0xd3, 1]), Data([98, 1, 0x53, 1]), Data([96, 1, 0, 8, 38, 1]), Data([0x80, 1, 7]), Data([38, 0, 7]), Data([38, 9, 7]), Data([100, 1, 7])])
    func malformedPicturesCannotBePublished(payload: Data) throws {
        var assembler = MediaHEVCAssembler()
        _ = try assembler.accept(Self.packet(Self.aggregation(Self.sets), sequence: 1))
        #expect(try assembler.accept(Self.packet(payload, sequence: 2, timestamp: 2)) == nil)
        #expect(try assembler.accept(Self.packet(Self.nal(1), sequence: 3, timestamp: 3)) == nil)
        #expect(try assembler.accept(Self.packet(Self.nal(19), sequence: 4, timestamp: 4)) != nil)
    }

    @Test func incompleteTimestampAndChangedSourceAreNotAccepted() throws {
        var assembler = MediaHEVCAssembler()
        _ = try assembler.accept(Self.packet(Self.aggregation(Self.sets), sequence: 1))
        _ = try assembler.accept(Self.packet(Data([98, 1, 0x93, 1]), sequence: 2, timestamp: 2, marker: false))
        #expect(try assembler.accept(Self.packet(Data([98, 1, 0x53, 2]), sequence: 3, timestamp: 3)) == nil)
        #expect(throws: CommandFailure.self) { try assembler.accept(Self.packet(Self.nal(19), sequence: 4, source: 2)) }
    }

    @Test func accessUnitBudgetIsEnforcedAndRecoveryRemainsPossible() throws {
        var assembler = MediaHEVCAssembler(maximumBytes: 64)
        _ = try assembler.accept(Self.packet(Self.aggregation(Self.sets), sequence: 1))
        #expect(try assembler.accept(Self.packet(Data([98, 1, 0x93] + Array(repeating: 1, count: 64)), sequence: 2)) == nil)
        #expect(try assembler.accept(Self.packet(Self.nal(19), sequence: 3, timestamp: 2)) != nil)
    }
}
