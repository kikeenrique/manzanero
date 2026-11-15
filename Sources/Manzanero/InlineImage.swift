import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image block an MCP result carries for a saved PNG.
///
/// The saved file is always the full-resolution PNG. What travels inline is a
/// separate decision, because it is paid for in response size and in the
/// model's tokens, and different agents want different trade-offs. A caller can
/// leave the image out, cap its longest edge, ask for JPEG at a chosen quality,
/// and cap its byte size. With no options the PNG is sent as it is when it fits
/// the byte limit and downscaled when it does not, since leaving it out would
/// hand an agent a screen it cannot see.
///
/// Normalized coordinates mean the same thing at any scale; pixel positions
/// read from a reduced image must be scaled, and the note says by how much.
enum InlineImage {
    enum Format: String, Sendable, CaseIterable {
        case png, jpeg
        var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
        var type: UTType { self == .png ? .png : .jpeg }
    }

    struct Options: Sendable, Equatable {
        /// False leaves the image out of the result; the file is still saved.
        var include = true
        /// Longest edge in pixels of the inline image; nil keeps the saved size.
        var maximumEdge: Int? = nil
        var format: Format = .png
        /// JPEG quality, 0.1...1. Ignored for PNG, which is lossless.
        var quality = 0.8
        /// The inline image is reduced until its encoded size fits.
        var byteLimit = InlineImage.defaultByteLimit

        static let edgeRange = 64...8192
        static let qualityRange = 0.1...1.0
        static let byteRange = 16 * 1024...InlineImage.maximumByteLimit
    }

    /// Default cap on the encoded inline image. The image travels as base64,
    /// about a third larger than this.
    static let defaultByteLimit = 8 * 1024 * 1024
    /// The largest cap a request may ask for.
    static let maximumByteLimit = 16 * 1024 * 1024
    /// Starting edge when an image must shrink to fit and the caller named none:
    /// far below the byte limit, large enough to read interface text.
    static let fallbackEdge = 1568

    struct Attachment: Equatable {
        let data: Data
        var mimeType = Format.png.mimeType
        /// Set when the inline image differs from the saved file.
        var note: String? = nil
    }

    /// The inline image for the PNG at `url`, or nil with a notice when it is
    /// left out on request or cannot be produced within the byte limit.
    static func attachment(for url: URL, options: Options = Options()) throws -> (Attachment?, String?) {
        guard options.include else { return (nil, "PNG saved; inline image omitted as requested.") }
        let megabytes = String(format: "%.3g", Double(options.byteLimit) / (1024 * 1024))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if options.format == .png, options.maximumEdge == nil, size <= options.byteLimit {
            return (Attachment(data: try Data(contentsOf: url)), nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return (nil, "PNG saved; inline image omitted because the file could not be read for conversion.")
        }
        let full = max(width, height)
        if options.format == .png, let edge = options.maximumEdge, edge >= full, size <= options.byteLimit {
            return (Attachment(data: try Data(contentsOf: url)), nil)
        }
        // Start at the requested edge, or the saved size for a format change
        // alone, or the fallback edge when only the byte limit forces a change.
        var target = min(full, options.maximumEdge ?? (options.format == .png ? fallbackEdge : full))
        // Halve the edge until the encoded copy fits; a few steps at most.
        while target >= 32 {
            let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceThumbnailMaxPixelSize: target,
                                              kCGImageSourceCreateThumbnailWithTransform: true]
            let output = NSMutableData()
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary),
               let destination = CGImageDestinationCreateWithData(output, options.format.type.identifier as CFString, 1, nil) {
                let encoding: [CFString: Any] = options.format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: options.quality] : [:]
                CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= options.byteLimit {
                    var changes: [String] = []
                    if image.width != width || image.height != height {
                        changes.append("downscaled from \(width)x\(height) to \(image.width)x\(image.height) pixels")
                    }
                    if options.format == .jpeg { changes.append("encoded as JPEG at quality \(String(format: "%.2g", options.quality))") }
                    var note = "Inline image \(changes.joined(separator: " and ")) (\(output.length) bytes; limit \(megabytes) MiB). The saved file is the full-resolution PNG. Normalized coordinates are unaffected"
                    note += image.width != width
                        ? "; pixel positions read from the inline image must be scaled by \(String(format: "%.4g", Double(width) / Double(image.width)))."
                        : "."
                    return (Attachment(data: output as Data, mimeType: options.format.mimeType, note: note), nil)
                }
            }
            target /= 2
        }
        return (nil, "PNG saved; inline image omitted because it could not be reduced to fit \(megabytes) MiB.")
    }
}
