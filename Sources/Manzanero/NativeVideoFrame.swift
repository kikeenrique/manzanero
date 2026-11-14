import CoreImage
import CoreVideo
import Foundation

/// Own pixels before crossing actors. Copy during the decoder callback, then
/// consume the mutable buffer into Apple's Sendable read-only wrapper.
@available(macOS 26.0, *)
struct NativeVideoFrame: Sendable {
    let nanoseconds: UInt64
    let pixels: CVReadOnlyPixelBuffer

    static func copy(_ source: CVPixelBuffer, context: CIContext) throws -> CVReadOnlyPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw CommandFailure(description: "Native decoded pixel buffer has unsupported dimensions or format.")
        }
        let owned = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
            size: .init(width: width, height: height)))
        owned.withUnsafeBuffer { context.render(CIImage(cvPixelBuffer: source), to: $0) }
        return CVReadOnlyPixelBuffer(owned)
    }
}
