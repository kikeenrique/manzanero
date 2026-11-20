import Foundation
import Testing
@testable import Manzanero

/// The experiment's copy of a capture's stream: Annex B units and one line
/// for each RTP packet.
struct NativeStreamDumpTests {
    private static let sets = [Data([0x40, 0x01, 0x0c]), Data([0x42, 0x01, 0x01]), Data([0x44, 0x01, 0xc0])]
    private static let start = Data([0, 0, 0, 1])

    @Test func unitsAreWrittenAfterStartCodesWithTheParameterSetsOnce() {
        var dump = NativeStreamDump()
        let key = Data([0x28, 0x01, 0xaf]), delta = Data([0x02, 0x01, 0xd0])
        // A key frame that arrived with its parameter sets, one that did not, and a delta.
        dump.unit(.init(timestamp: 0, parameterSets: Self.sets, nals: Self.sets + [key], randomAccess: true))
        dump.unit(.init(timestamp: 1, parameterSets: Self.sets, nals: [key], randomAccess: true))
        dump.unit(.init(timestamp: 2, parameterSets: Self.sets, nals: [delta], randomAccess: false))
        let keyFrame = (Self.sets + [key]).reduce(Data()) { $0 + Self.start + $1 }
        #expect(dump.stream == keyFrame + keyFrame + Self.start + delta)
    }

    @Test func eachPacketGivesItsSequenceTimestampMarkerSizeAndExtension() {
        var dump = NativeStreamDump()
        // Version 2 with an extension: sequence 0x2742, timestamp 960, marker set,
        // extension profile 9011 with four bytes, then three bytes of payload.
        dump.packet(Data([0x90, 0xe3, 0x27, 0x42, 0, 0, 0x03, 0xc0, 1, 2, 3, 4,
                          0x90, 0x11, 0x00, 0x01, 0x00, 0x35, 0xf3, 0x54, 0x62, 0x01, 0x94]))
        // No extension, marker clear.
        dump.packet(Data([0x80, 0x63, 0x27, 0x43, 0, 0, 0x07, 0x80, 1, 2, 3, 4, 0x02, 0x01]))
        // Not RTP, and too short: no line.
        dump.packet(Data([0x00, 0x63, 0x27, 0x43, 0, 0, 0x07, 0x80, 1, 2, 3, 4, 0x02]))
        dump.packet(Data([0x80, 0x63]))
        #expect(dump.lines == ["10050 960 1 3 9011:0035f354", "10051 1920 0 2 -"])
    }

    @Test func bothFilesAreWrittenBesideTheFrames() throws {
        let directory = URL(fileURLWithPath: "tmp/stream-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dump = NativeStreamDump()
        dump.unit(.init(timestamp: 0, parameterSets: Self.sets, nals: [Data([0x02, 0x01])], randomAccess: false))
        dump.packet(Data([0x80, 0x63, 0, 1, 0, 0, 0, 2, 1, 2, 3, 4, 0x02, 0x01]))
        try dump.write(to: directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent(NativeStreamDump.streamName)) == Self.start + Data([0x02, 0x01]))
        #expect(try String(contentsOf: directory.appendingPathComponent(NativeStreamDump.packetsName), encoding: .utf8) == "1 2 0 2 -\n")
    }
}
