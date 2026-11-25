import CoreImage
import CoreVideo
import Foundation

/// Own pixels before crossing actors. Copy during the decoder callback, then
/// consume the mutable buffer into Apple's Sendable read-only wrapper.
struct NativeVideoFrame: Sendable {
    let nanoseconds: UInt64
    let pixels: CVReadOnlyPixelBuffer

    /// A copy of the decoded picture, or of its top-left `crop` pixels: the
    /// stream pads the screen on the right and at the bottom.
    /// `image` turned `turn` degrees clockwise (0, 90, 180 or 270), with its
    /// extent back at the origin.
    static func turned(_ image: CIImage, by turn: Int) -> CIImage {
        let orientation: CGImagePropertyOrientation
        switch turn {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: return image
        }
        let oriented = image.oriented(orientation)
        return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    }

    static func copy(_ source: CVPixelBuffer, context: CIContext, crop: (width: Int, height: Int)? = nil, turn: Int = 0) throws -> CVReadOnlyPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        guard (1...8192).contains(sourceWidth), (1...8192).contains(sourceHeight), sourceWidth * sourceHeight <= 20_000_000,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw CommandFailure(.toolFailed, "Native decoded pixel buffer has unsupported dimensions or format.", inputSent: .none)
        }
        let width = min(max(crop?.width ?? sourceWidth, 1), sourceWidth)
        let height = min(max(crop?.height ?? sourceHeight, 1), sourceHeight)
        let sideways = turn == 90 || turn == 270
        let owned = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
            size: .init(width: sideways ? height : width, height: sideways ? width : height)))
        // Core Image's origin is the bottom left: keep the top rows, and move
        // them down to the origin of the smaller buffer.
        let dropped = CGFloat(sourceHeight - height)
        let picture = turned(CIImage(cvPixelBuffer: source)
            .cropped(to: CGRect(x: 0, y: dropped, width: CGFloat(width), height: CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: 0, y: -dropped)), by: turn)
        owned.withUnsafeBuffer { context.render(picture, to: $0) }
        return CVReadOnlyPixelBuffer(owned)
    }
}
