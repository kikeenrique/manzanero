import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image block an MCP result carries for a saved PNG.
///
/// The saved file is always the full-resolution PNG: it is the evidence. What
/// travels inline is a separate decision, because it is paid for in response
/// size and in the model's context. The default is therefore a reduced copy
/// sized for a vision model to read interface text, and a caller asks for more
/// (or less, or nothing) per request.
///
/// Reduction prefers losing nothing, then losing little: the longest edge is
/// capped first; `auto` keeps lossless PNG when that fits the byte cap and
/// switches to JPEG when it does not; only then is the image shrunk further.
///
/// Normalized coordinates mean the same thing at any scale. Pixel positions
/// read from a reduced image must be multiplied by `scale`.
enum InlineImage {
    enum Format: String, Sendable, CaseIterable {
        /// PNG when it fits the byte cap, otherwise JPEG.
        case auto
        case png, jpeg
    }

    enum Encoding: String, Sendable, Equatable {
        case png, jpeg
        var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
        var type: UTType { self == .png ? .png : .jpeg }
    }

    struct Options: Sendable, Equatable {
        /// False leaves the image out of the result; the file is still saved.
        var include = true
        /// Longest edge in pixels of the inline image.
        var maximumEdge = InlineImage.defaultEdge
        var format: Format = .auto
        /// JPEG quality, 0.1...1. Unused when the result is PNG.
        var quality = 0.8
        /// The inline image is reduced until its encoded size fits.
        var byteLimit = InlineImage.defaultByteLimit

        static let edgeRange = 64...8192
        static let qualityRange = 0.1...1.0
        static let byteRange = 16 * 1024...16 * 1024 * 1024
    }

    /// Enough to read interface text; larger images are commonly resized by the
    /// model before it looks at them, so more pixels only cost transfer.
    static let defaultEdge = 1568
    /// Cap on the encoded inline image. It travels as base64, a third larger.
    static let defaultByteLimit = 1024 * 1024

    struct Attachment: Equatable {
        let data: Data
        let encoding: Encoding
        let width: Int
        let height: Int
        /// Multiply inline pixel positions by this to get saved-file pixels.
        let scale: Double
        /// Set when the inline image differs from the saved file.
        var note: String? = nil

        var mimeType: String { encoding.mimeType }
        /// The same facts as data, for callers that compute with them.
        var description: [String: Any] {
            ["included": true, "format": encoding.rawValue, "width": width, "height": height, "bytes": data.count, "scale": scale]
        }
    }

    enum Outcome: Equatable {
        case attached(Attachment)
        /// No image block; the reason is also shown as text.
        case omitted(String)

        var description: [String: Any] {
            switch self {
            case .attached(let attachment): attachment.description
            case .omitted(let reason): ["included": false, "reason": reason]
            }
        }
    }

    static func attachment(for url: URL, options: Options = Options()) throws -> Outcome {
        guard options.include else { return .omitted("PNG saved; inline image omitted as requested.") }
        let megabytes = String(format: "%.3g", Double(options.byteLimit) / (1024 * 1024))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return .omitted("PNG saved; inline image omitted because the file could not be read as an image.")
        }
        let full = max(width, height)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // The saved file itself, when no reduction is asked for or needed.
        if options.maximumEdge >= full, options.format != .jpeg, size <= options.byteLimit {
            return .attached(Attachment(data: try Data(contentsOf: url), encoding: .png, width: width, height: height, scale: 1))
        }
        let encodings: [Encoding] = switch options.format {
        case .auto: [.png, .jpeg]
        case .png: [.png]
        case .jpeg: [.jpeg]
        }
        // At each size try lossless first (for auto), then lossy; shrink last.
        var target = min(full, options.maximumEdge)
        while target >= 32 {
            let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceThumbnailMaxPixelSize: target,
                                              kCGImageSourceCreateThumbnailWithTransform: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) {
                for encoding in encodings {
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, encoding.type.identifier as CFString, 1, nil) else { continue }
                    let settings: [CFString: Any] = encoding == .jpeg ? [kCGImageDestinationLossyCompressionQuality: options.quality] : [:]
                    CGImageDestinationAddImage(destination, image, settings as CFDictionary)
                    guard CGImageDestinationFinalize(destination), output.length <= options.byteLimit else { continue }
                    let scale = Double(width) / Double(image.width)
                    var changes: [String] = []
                    if image.width != width || image.height != height {
                        changes.append("downscaled from \(width)x\(height) to \(image.width)x\(image.height) pixels")
                    }
                    if encoding == .jpeg { changes.append("encoded as JPEG at quality \(String(format: "%.2g", options.quality))") }
                    var note = "Inline image \(changes.joined(separator: " and ")) (\(output.length) bytes; limit \(megabytes) MiB). The saved file is the full-resolution PNG. Normalized coordinates are unaffected"
                    note += image.width != width
                        ? "; pixel positions read from the inline image must be multiplied by \(String(format: "%.4g", scale))."
                        : "."
                    return .attached(Attachment(data: output as Data, encoding: encoding, width: image.width, height: image.height,
                                                scale: scale, note: changes.isEmpty ? nil : note))
                }
            }
            target /= 2
        }
        return .omitted("PNG saved; inline image omitted because it could not be reduced to fit \(megabytes) MiB.")
    }
}
