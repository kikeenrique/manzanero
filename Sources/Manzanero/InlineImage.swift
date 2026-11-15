import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image block an MCP result carries for a saved PNG.
///
/// A full-resolution phone screenshot of a detailed screen can exceed the
/// inline size limit; leaving the image out would hand an agent a screen it
/// cannot see. Such a file is sent as a smaller PNG instead. The saved file is
/// never changed, and normalized coordinates mean the same thing at any scale.
enum InlineImage {
    static let byteLimit = 8 * 1024 * 1024
    /// Longest edge of a downscaled copy. Small enough to stay far below the
    /// byte limit, large enough to read interface text.
    static let downscaledEdge = 1568

    struct Attachment: Equatable {
        let data: Data
        /// Set when the inline image is smaller than the saved file.
        var note: String? = nil
    }

    /// The PNG at `url` as it is when it fits, otherwise a downscaled PNG with
    /// a note. Returns nil with a note only if the file cannot be reduced.
    static func attachment(for url: URL, byteLimit: Int = byteLimit, edge: Int = downscaledEdge) throws -> (Attachment?, String?) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size <= byteLimit { return (Attachment(data: try Data(contentsOf: url)), nil) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return (nil, "PNG saved; image content omitted because it exceeds \(byteLimit / (1024 * 1024)) MiB and could not be read for downscaling.")
        }
        // Halve the edge until the encoded copy fits; a few steps at most.
        var target = min(edge, max(width, height))
        while target >= 64 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: target,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            let output = NSMutableData()
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination), output.length <= byteLimit {
                    let note = "Inline image downscaled from \(width)x\(height) to \(image.width)x\(image.height) pixels because the saved PNG exceeds \(byteLimit / (1024 * 1024)) MiB. The saved file is full resolution. Normalized coordinates are unaffected; pixel positions read from the inline image must be scaled by \(String(format: "%.4g", Double(width) / Double(image.width)))."
                    return (Attachment(data: output as Data, note: note), nil)
                }
            }
            target /= 2
        }
        return (nil, "PNG saved; image content omitted because it exceeds \(byteLimit / (1024 * 1024)) MiB and could not be downscaled to fit.")
    }
}
