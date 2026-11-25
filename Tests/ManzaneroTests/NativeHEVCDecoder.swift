import Foundation
import Testing
@testable import Manzanero

struct NativeHEVCDecoderTests {
    @Test func permitsObservedCodedPaddingAndRejectsUnexpectedGeometry() {
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1136, 2464, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1136, 2448, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(1136, 2465, negotiatedWidth: 1136, negotiatedHeight: 2448))
        // An iPhone Duo's inner display, fitted into its outer display's
        // negotiated frame (2026-11-25); no smaller than a sixteenth less.
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1408, 2016, negotiatedWidth: 1408, negotiatedHeight: 2048))
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1135, 2448, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(1408, 1919, negotiatedWidth: 1408, negotiatedHeight: 2048))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(1000, 2048, negotiatedWidth: 1408, negotiatedHeight: 2048))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(8193, 1, negotiatedWidth: 8192, negotiatedHeight: 1))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(5000, 5000, negotiatedWidth: 4999, negotiatedHeight: 4999))
    }

    /// Stream data that is not what was negotiated is a transport failure, a
    /// framework step that fails is a tool failure, and neither sent input.
    @MainActor @Test func failuresAreClassifiedAndSendNoInput() throws {
        let dimensions = try #require(throws: CommandFailure.self) { _ = try NativeHEVCDecoder(width: 0, height: 10) }
        #expect(dimensions.code == .transportFailed && dimensions.inputSent == .none)

        let decoder = try NativeHEVCDecoder(width: 64, height: 64)
        let sets = [Data([1, 2]), Data([3, 4]), Data([5, 6])]
        let empty = try #require(throws: CommandFailure.self) {
            _ = try decoder.decode(MediaHEVCAccessUnit(timestamp: 0, parameterSets: sets, nals: [], randomAccess: true))
        }
        #expect(empty.code == .transportFailed && empty.inputSent == .none && empty.description.contains("invalid access unit"))
        let dependent = try #require(throws: CommandFailure.self) {
            _ = try decoder.decode(MediaHEVCAccessUnit(timestamp: 0, parameterSets: sets, nals: [Data([38, 1, 0])], randomAccess: false))
        }
        #expect(dependent.code == .transportFailed && dependent.description.contains("not random access"))
        // Core Media rejects these bytes as parameter sets.
        let garbage = try #require(throws: CommandFailure.self) {
            _ = try decoder.decode(MediaHEVCAccessUnit(timestamp: 0, parameterSets: sets, nals: [Data([38, 1, 0])], randomAccess: true))
        }
        #expect(garbage.code == .toolFailed && garbage.inputSent == .none && garbage.retry == .safe)

        decoder.close()
        let closed = try #require(throws: CommandFailure.self) {
            _ = try decoder.decode(MediaHEVCAccessUnit(timestamp: 0, parameterSets: sets, nals: [Data([38, 1, 0])], randomAccess: true))
        }
        #expect(closed.code == .internal && closed.inputSent == .none)
    }
}
