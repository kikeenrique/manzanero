import CoreGraphics
import Foundation
import ImageIO
import MCP
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

    private func inspect(_ data: Data) throws -> (width: Int, height: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height, (CGImageSourceGetType(source) as String?) ?? "")
    }

    private func withImage(_ body: (URL, Data) throws -> Void) throws {
        let url = try noisePNG(width: 600, height: 1300)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        try body(url, original)
        // Whatever was sent, the saved file is left as it was.
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func defaultsSendTheSavedPNGUnchanged() throws {
        try withImage { url, original in
            let (attachment, omission) = try InlineImage.attachment(for: url)
            #expect(omission == nil && attachment?.data == original)
            #expect(attachment?.mimeType == "image/png" && attachment?.note == nil)
        }
    }

    @Test func includeFalseLeavesTheImageOutAndSaysSo() throws {
        try withImage { url, _ in
            let (attachment, omission) = try InlineImage.attachment(for: url, options: .init(include: false))
            #expect(attachment == nil && omission == "PNG saved; inline image omitted as requested.")
        }
    }

    @Test func maximumEdgeDownscalesEvenWhenTheFileFits() throws {
        try withImage { url, _ in
            let (attachment, _) = try InlineImage.attachment(for: url, options: .init(maximumEdge: 400))
            let sent = try #require(attachment)
            let image = try inspect(sent.data)
            #expect(max(image.width, image.height) == 400 && image.type == UTType.png.identifier)
            #expect(abs(Double(image.width) / Double(image.height) - 600.0 / 1300.0) < 0.02)
            let note = try #require(sent.note)
            let factor = String(format: "%.4g", 600.0 / Double(image.width))
            #expect(note.contains("600x1300") && note.contains("\(image.width)x\(image.height)") && note.contains("must be scaled by \(factor)"))
        }
    }

    @Test func maximumEdgeAtOrAboveTheSavedSizeChangesNothing() throws {
        try withImage { url, original in
            let (attachment, _) = try InlineImage.attachment(for: url, options: .init(maximumEdge: 4000))
            #expect(attachment?.data == original && attachment?.note == nil)
        }
    }

    @Test func jpegIsSmallerKeepsItsSizeAndIsLabelled() throws {
        try withImage { url, original in
            let (attachment, _) = try InlineImage.attachment(for: url, options: .init(format: .jpeg, quality: 0.5))
            let sent = try #require(attachment)
            let image = try inspect(sent.data)
            #expect(sent.mimeType == "image/jpeg" && image.type == UTType.jpeg.identifier)
            #expect(image.width == 600 && image.height == 1300 && sent.data.count < original.count)
            let note = try #require(sent.note)
            #expect(note.contains("encoded as JPEG at quality 0.5") && !note.contains("must be scaled"))
            // Lower quality gives a smaller image.
            let (lower, _) = try InlineImage.attachment(for: url, options: .init(format: .jpeg, quality: 0.1))
            #expect(try #require(lower).data.count < sent.data.count)
        }
    }

    @Test func byteLimitShrinksTheImageUntilItFits() throws {
        try withImage { url, original in
            let limit = original.count / 4
            let (attachment, omission) = try InlineImage.attachment(for: url, options: .init(byteLimit: limit))
            let sent = try #require(attachment)
            #expect(omission == nil && sent.data.count <= limit)
            let sentWidth = try inspect(sent.data).width
            #expect(sentWidth < 600)
            #expect(sent.note?.contains("downscaled from 600x1300") == true)
            // A requested edge that still does not fit is halved further.
            let (smaller, _) = try InlineImage.attachment(for: url, options: .init(maximumEdge: 1200, byteLimit: 40_000))
            let fitted = try #require(smaller)
            let fittedHeight = try inspect(fitted.data).height
            #expect(fitted.data.count <= 40_000)
            #expect(fittedHeight < 1200)
        }
    }

    @Test func combinedEdgeAndJpegAreBothReported() throws {
        try withImage { url, _ in
            let (attachment, _) = try InlineImage.attachment(for: url, options: .init(maximumEdge: 300, format: .jpeg))
            let sent = try #require(attachment)
            let image = try inspect(sent.data)
            #expect(max(image.width, image.height) == 300 && sent.mimeType == "image/jpeg")
            #expect(sent.note?.contains("downscaled from 600x1300") == true && sent.note?.contains("encoded as JPEG") == true)
        }
    }

    @Test func impossibleLimitOmitsTheImageInsteadOfSendingTooMuch() throws {
        try withImage { url, _ in
            let (attachment, omission) = try InlineImage.attachment(for: url, options: .init(byteLimit: 16))
            #expect(attachment == nil && omission?.contains("could not be reduced to fit") == true)
        }
    }

    @Test func oversizedFileThatIsNotAnImageIsOmittedWithAReason() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/inline-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-an-image.png")
        try Data(repeating: 7, count: 4096).write(to: url)
        let (attachment, omission) = try InlineImage.attachment(for: url, options: .init(byteLimit: 1024))
        #expect(attachment == nil && omission?.contains("could not be read for conversion") == true)
    }

    @Test func requestOptionsAreParsedAndRangeChecked() throws {
        #expect(try MCPTools.imageOptions([:]) == InlineImage.Options())
        let options = try MCPTools.imageOptions(["image_include": .bool(true), "image_max_edge": .int(1568), "image_format": .string("jpeg"),
                                                 "image_quality": .double(0.6), "image_max_bytes": .int(500_000)])
        #expect(options == InlineImage.Options(include: true, maximumEdge: 1568, format: .jpeg, quality: 0.6, byteLimit: 500_000))
        #expect(try MCPTools.imageOptions(["image_include": .bool(false)]).include == false)
        for invalid: [String: Value] in [["image_max_edge": .int(8)], ["image_max_edge": .int(100_000)], ["image_max_edge": .double(300.5)],
                                         ["image_max_bytes": .int(10)], ["image_max_bytes": .int(InlineImage.maximumByteLimit + 1)],
                                         ["image_format": .string("jpeg"), "image_quality": .double(0)],
                                         ["image_format": .string("jpeg"), "image_quality": .double(1.5)],
                                         ["image_quality": .double(0.5)]] {
            #expect(throws: MCPError.self) { _ = try MCPTools.imageOptions(invalid) }
        }
    }

    @Test func onlyImageToolsCarryTheOptionsAndBadOnesStopBeforeCapture() async throws {
        let names = Set(MCPTools.imageFields.map(\.name))
        for definition in MCPTools.definitions {
            let has = !names.isDisjoint(with: definition.fields.map(\.name))
            #expect(has == (definition.imagePath != nil), "\(definition.name)")
        }
        // An invalid option is refused before the device operation runs.
        await #expect(throws: MCPError.self) {
            _ = try await MCPTools.call(name: "screenshot", arguments: ["platform": "physical", "device": "fixture", "path": "tmp/x.png", "image_max_edge": .int(1)],
                                        execute: { _ in Issue.record("Captured despite an invalid image option"); return CommandOutput(data: Data()) })
        }
    }

    @Test func toolResultCarriesTheRequestedRendition() async throws {
        let url = try noisePNG(width: 600, height: 1300)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func content(_ extra: [String: Value]) async throws -> [Tool.Content] {
            var arguments: [String: Value] = ["platform": "physical", "device": "fixture", "path": .string(url.path)]
            arguments.merge(extra) { $1 }
            return try await MCPTools.call(name: "screenshot", arguments: arguments, execute: { command in
                // The image options shape the result only; they never reach the CLI.
                #expect(command == ["physical", "fixture", "screenshot", url.path])
                return CommandOutput(data: Data("{}".utf8))
            }).content
        }
        func images(_ content: [Tool.Content]) -> [(Data, String)] {
            content.compactMap { if case .image(let data, let mimeType, _, _) = $0 { return (Data(base64Encoded: data) ?? Data(), mimeType) }; return nil }
        }
        let saved = try Data(contentsOf: url)
        let plain = images(try await content([:]))
        #expect(plain.count == 1 && plain[0].1 == "image/png" && plain[0].0 == saved)
        let reduced = images(try await content(["image_max_edge": .int(256), "image_format": .string("jpeg"), "image_quality": .double(0.4)]))
        #expect(reduced.count == 1 && reduced[0].1 == "image/jpeg" && reduced[0].0.count < plain[0].0.count / 10)
        #expect(images(try await content(["image_include": .bool(false)])).isEmpty)
    }
}
