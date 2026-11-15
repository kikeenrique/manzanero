import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Manzanero

struct InlineImageTests {
    /// A PNG of pseudo-random pixels, which compresses badly, like a detailed screen.
    private func noisePNG(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0x1234_5678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 8)
        }
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/inline-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("screen.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(of data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func imageWithinTheLimitIsSentUnchanged() throws {
        let url = try noisePNG(width: 60, height: 130)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (attachment, omission) = try InlineImage.attachment(for: url)
        #expect(omission == nil)
        #expect(attachment?.data == (try Data(contentsOf: url)) && attachment?.note == nil)
    }

    @Test func oversizedImageIsDownscaledAndSaysSo() throws {
        let url = try noisePNG(width: 600, height: 1300)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let limit = original.count / 4
        let (attachment, omission) = try InlineImage.attachment(for: url, byteLimit: limit, edge: 400)
        let sent = try #require(attachment)
        #expect(omission == nil && sent.data.count <= limit)
        let (width, height) = try size(of: sent.data)
        // The long edge is bounded and the aspect ratio is kept.
        #expect(max(width, height) <= 400 && abs(Double(width) / Double(height) - 600.0 / 1300.0) < 0.02)
        let note = try #require(sent.note)
        #expect(note.contains("600x1300") && note.contains("\(width)x\(height)") && note.contains("Normalized coordinates are unaffected"))
        // The saved file is left as it was.
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func edgeIsHalvedUntilTheCopyFits() throws {
        let url = try noisePNG(width: 600, height: 1300)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A limit the first downscaled copy cannot meet.
        let (attachment, omission) = try InlineImage.attachment(for: url, byteLimit: 40_000, edge: 1200)
        let sent = try #require(attachment)
        #expect(omission == nil && sent.data.count <= 40_000)
        let (width, height) = try size(of: sent.data)
        #expect(max(width, height) < 1200)
    }

    @Test func oversizedFileThatIsNotAnImageIsOmittedWithAReason() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/inline-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-an-image.png")
        try Data(repeating: 7, count: 4096).write(to: url)
        let (attachment, omission) = try InlineImage.attachment(for: url, byteLimit: 1024)
        #expect(attachment == nil)
        #expect(omission?.contains("could not be read for downscaling") == true)
    }

    @Test func impossibleLimitOmitsTheImageInsteadOfSendingTooMuch() throws {
        let url = try noisePNG(width: 600, height: 1300)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (attachment, omission) = try InlineImage.attachment(for: url, byteLimit: 16)
        #expect(attachment == nil && omission?.contains("could not be downscaled to fit") == true)
    }
}
