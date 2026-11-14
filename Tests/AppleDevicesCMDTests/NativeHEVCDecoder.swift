import Testing
@testable import AppleDevicesCMD

struct NativeHEVCDecoderTests {
    @Test func permitsObservedCodedPaddingAndRejectsUnexpectedGeometry() {
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1136, 2464, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(NativeHEVCDecoder.acceptsCodedDimensions(1136, 2448, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(1136, 2465, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(1135, 2448, negotiatedWidth: 1136, negotiatedHeight: 2448))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(8193, 1, negotiatedWidth: 8192, negotiatedHeight: 1))
        #expect(!NativeHEVCDecoder.acceptsCodedDimensions(5000, 5000, negotiatedWidth: 4999, negotiatedHeight: 4999))
    }
}
