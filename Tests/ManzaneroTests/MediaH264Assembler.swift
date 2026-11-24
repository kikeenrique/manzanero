import Foundation
import Testing
@testable import Manzanero

/// An Apple Watch's screen stream: H.264 whose parameter sets arrive in a
/// sample-description packet, then FU-A fragments and single NAL units.
struct MediaH264AssemblerTests {
    static let sps = Data([0x67, 0x64, 0x00, 0x1f]), pps = Data([0x68, 0xee, 0x3c])
    static func packet(_ payload: Data, sequence: UInt16, timestamp: UInt32, marker: Bool, source: UInt32) throws -> MediaRTPPacket {
        try MediaHEVCAssemblerTests.packet(payload, sequence: sequence, timestamp: timestamp, marker: marker, source: source)
    }

    /// Four bytes, then an `avc1` entry with an `avcC` box, as the watch sent
    /// it (2026-11-25), shortened.
    static func description(sps: Data = sps, pps: Data = pps) -> Data {
        var avcC = Data([1, 0x64, 0, 0x1f, 0xff, 0xe1, 0, UInt8(sps.count)]) + sps
        avcC += Data([1, 0, UInt8(pps.count)]) + pps
        let box = Data([0, 0, 0, UInt8(avcC.count + 8)]) + Data("avcC".utf8) + avcC
        let entry = Data([0, 0, 0, UInt8(box.count + 16)]) + Data("avc1".utf8) + Data(repeating: 0, count: 8) + box
        return Data([0x92, 0xe6, 0xc0, 0xa3]) + entry
    }

    @Test func theDescriptionGivesTheParameterSets() throws {
        let sets = try #require(MediaH264Assembler.descriptionParameterSets(Self.description()))
        #expect(sets.sps == Self.sps && sets.pps == Self.pps)
        #expect(MediaH264Assembler.descriptionParameterSets(Data([0x3c, 0x85, 1, 2])) == nil)
    }

    @Test func anIDRInFragmentsAfterTheDescriptionThenADependentPicture() throws {
        var assembler = MediaVideoAssembler()
        #expect(try assembler.accept(Self.packet(Self.description(), sequence: 1, timestamp: 0, marker: false, source: 1)) == nil)
        // FU-A of an IDR slice (type 5): start, middle, end.
        #expect(try assembler.accept(Self.packet(Data([0x3c, 0x85, 1, 2]), sequence: 2, timestamp: 0, marker: false, source: 1)) == nil)
        #expect(try assembler.accept(Self.packet(Data([0x3c, 0x05, 3]), sequence: 3, timestamp: 0, marker: false, source: 1)) == nil)
        let first = try assembler.accept(Self.packet(Data([0x3c, 0x45, 4]), sequence: 4, timestamp: 0, marker: true, source: 1))
        let unit = try #require(first)
        #expect(unit.codec == .h264 && unit.randomAccess && unit.parameterSets == [Self.sps, Self.pps])
        #expect(unit.nals == [Data([0x25, 1, 2, 3, 4])])
        let second = try assembler.accept(Self.packet(Data([0x21, 0xd0, 9]), sequence: 5, timestamp: 400, marker: true, source: 1))
        #expect(try #require(second).nals == [Data([0x21, 0xd0, 9])])
    }

    @Test func aLostFragmentWaitsForTheNextIDR() throws {
        var assembler = MediaH264Assembler()
        _ = try assembler.accept(Self.packet(Self.description(), sequence: 1, timestamp: 0, marker: false, source: 1))
        _ = try assembler.accept(Self.packet(Data([0x3c, 0x85, 1]), sequence: 2, timestamp: 0, marker: false, source: 1))
        // Sequence 3 lost.
        #expect(try assembler.accept(Self.packet(Data([0x3c, 0x45, 4]), sequence: 4, timestamp: 0, marker: true, source: 1)) == nil)
        #expect(try assembler.accept(Self.packet(Data([0x21, 0xd0, 9]), sequence: 5, timestamp: 400, marker: true, source: 1)) == nil)
        let key = try assembler.accept(Self.packet(Data([0x65, 0x88, 7]), sequence: 6, timestamp: 800, marker: true, source: 1))
        #expect(try #require(key).randomAccess)
    }

    @Test func anHEVCStreamStillGoesToTheHEVCAssembler() throws {
        var assembler = MediaVideoAssembler()
        let sets = MediaHEVCAssemblerTests.sets, picture = MediaHEVCAssemblerTests.nal(19)
        let result = try assembler.accept(Self.packet(MediaHEVCAssemblerTests.aggregation(sets + [picture]), sequence: 1, timestamp: 1, marker: true, source: 1))
        #expect(try #require(result).codec == .hevc)
    }
}
