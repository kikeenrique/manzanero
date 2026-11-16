import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers
@testable import Manzanero

struct InlineImageTests {
    /// A PNG the size of a phone screenshot. Noise compresses badly, like a
    /// photo wallpaper; a flat fill compresses well, like a settings screen.
    private func png(width: Int = 600, height: Int = 1300, noise: Bool = true, photo: Bool = false) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0x1234_5678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            if photo {
                // A smooth gradient with fine grain: PNG cannot compress the
                // grain, JPEG discards it. This is what a photo wallpaper does.
                let pixel = index / 4, x = pixel % width, y = pixel / width
                let grain = Int(state >> 29)
                pixels[index] = UInt8(clamping: x * 200 / width + grain)
                pixels[index + 1] = UInt8(clamping: y * 200 / height + grain)
                pixels[index + 2] = UInt8(clamping: 120 + grain)
                continue
            }
            pixels[index] = noise ? UInt8(truncatingIfNeeded: state >> 24) : 240
            pixels[index + 1] = noise ? UInt8(truncatingIfNeeded: state >> 16) : 240
            pixels[index + 2] = noise ? UInt8(truncatingIfNeeded: state >> 8) : 245
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

    private func decoded(_ data: Data) throws -> (width: Int, height: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height, (CGImageSourceGetType(source) as String?) ?? "")
    }

    /// Runs `body` with a saved image and checks the file is never changed.
    private func withImage(width: Int = 600, height: Int = 1300, noise: Bool = true, photo: Bool = false, _ body: (URL, Data) throws -> Void) throws {
        let url = try png(width: width, height: height, noise: noise, photo: photo)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        try body(url, original)
        #expect(try Data(contentsOf: url) == original)
    }

    private func attached(_ outcome: InlineImage.Outcome) throws -> InlineImage.Attachment {
        guard case .attached(let attachment) = outcome else { throw CommandFailure(description: "Expected an inline image, got \(outcome)") }
        return attachment
    }

    @Test func defaultsAreAReducedCopySizedForReading() {
        let options = InlineImage.Options()
        #expect(options.include && options.maximumEdge == 1568 && options.format == .auto)
        #expect(options.quality == 0.8 && options.byteLimit == 1024 * 1024)
    }

    @Test func smallSimpleScreenIsSentAsTheSavedFile() throws {
        try withImage(noise: false) { url, original in
            let sent = try attached(InlineImage.attachment(for: url))
            #expect(sent.data == original && sent.encoding == .png && sent.note == nil)
            #expect(sent.width == 600 && sent.height == 1300 && sent.scale == 1)
        }
    }

    @Test func screenLargerThanTheDefaultEdgeIsDownscaled() throws {
        try withImage(width: 1125, height: 2436, noise: false) { url, _ in
            let sent = try attached(InlineImage.attachment(for: url))
            let image = try decoded(sent.data)
            #expect(sent.encoding == .png && image.type == UTType.png.identifier)
            #expect(image.height == 1568 && sent.height == 1568 && sent.width == image.width)
            #expect(abs(sent.scale - 2436.0 / 1568.0) < 0.01)
            let note = try #require(sent.note)
            #expect(note.contains("downscaled from 1125x2436") && note.contains("must be multiplied by"))
        }
    }

    @Test func autoSwitchesToJpegBeforeShrinkingFurther() throws {
        try withImage(photo: true) { url, original in
            // Too large as PNG at this size, small enough as JPEG.
            let limit = original.count / 3
            let sent = try attached(InlineImage.attachment(for: url, options: .init(byteLimit: limit)))
            let image = try decoded(sent.data)
            #expect(sent.encoding == .jpeg && sent.mimeType == "image/jpeg" && image.type == UTType.jpeg.identifier)
            // The format changed; the size did not.
            #expect(image.width == 600 && image.height == 1300 && sent.scale == 1 && sent.data.count <= limit)
            let note = try #require(sent.note)
            #expect(note.contains("encoded as JPEG at quality 0.8"), "\(note)")
            #expect(!note.contains("must be multiplied"), "\(note)")
        }
    }

    @Test func pngOnlyShrinksInsteadOfLosingQuality() throws {
        try withImage { url, original in
            let limit = original.count / 3
            let sent = try attached(InlineImage.attachment(for: url, options: .init(format: .png, byteLimit: limit)))
            let image = try decoded(sent.data)
            #expect(sent.encoding == .png && image.width < 600 && sent.data.count <= limit)
            #expect(sent.note?.contains("downscaled from 600x1300") == true)
        }
    }

    @Test func jpegIsForcedEvenWhenPngWouldFit() throws {
        try withImage(noise: false) { url, _ in
            let sent = try attached(InlineImage.attachment(for: url, options: .init(format: .jpeg, quality: 0.5)))
            #expect(sent.encoding == .jpeg && sent.width == 600 && sent.note?.contains("quality 0.5") == true)
        }
        try withImage { url, _ in
            let high = try attached(InlineImage.attachment(for: url, options: .init(format: .jpeg, quality: 0.9)))
            let low = try attached(InlineImage.attachment(for: url, options: .init(format: .jpeg, quality: 0.1)))
            #expect(low.data.count < high.data.count)
        }
    }

    @Test func requestedEdgeIsHonouredAndReported() throws {
        try withImage(noise: false) { url, original in
            let sent = try attached(InlineImage.attachment(for: url, options: .init(maximumEdge: 400)))
            let image = try decoded(sent.data)
            #expect(max(image.width, image.height) == 400 && abs(sent.scale - 600.0 / Double(image.width)) < 0.0001)
            #expect(abs(Double(image.width) / Double(image.height) - 600.0 / 1300.0) < 0.02)
            // An edge at or above the saved size asks for the saved file.
            let full = try attached(InlineImage.attachment(for: url, options: .init(maximumEdge: 8192)))
            #expect(full.data == original && full.note == nil)
        }
    }

    @Test func combinedLimitsShrinkOnlyAsFarAsNeeded() throws {
        try withImage { url, _ in
            let sent = try attached(InlineImage.attachment(for: url, options: .init(maximumEdge: 1200, byteLimit: 40_000)))
            #expect(sent.data.count <= 40_000 && sent.height < 1200)
            #expect(sent.note?.contains("downscaled") == true)
        }
    }

    @Test func includeFalseAndImpossibleLimitsOmitWithAReason() throws {
        try withImage { url, _ in
            #expect(try InlineImage.attachment(for: url, options: .init(include: false)) == .omitted("PNG saved; inline image omitted as requested."))
            guard case .omitted(let reason) = try InlineImage.attachment(for: url, options: .init(byteLimit: 16)) else {
                Issue.record("An image was sent above its byte limit"); return
            }
            #expect(reason.contains("could not be reduced to fit"))
            #expect(InlineImage.Outcome.omitted(reason).description["included"] as? Bool == false)
        }
    }

    @Test func fileThatIsNotAnImageIsOmittedWithAReason() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/inline-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-an-image.png")
        try Data(repeating: 7, count: 4096).write(to: url)
        guard case .omitted(let reason) = try InlineImage.attachment(for: url) else { Issue.record("Sent a non-image"); return }
        #expect(reason.contains("could not be read as an image"))
    }

    @Test func requestOptionsAreParsedAndRangeChecked() throws {
        #expect(try MCPTools.imageOptions([:]) == InlineImage.Options())
        let options = try MCPTools.imageOptions(["image_include": .bool(true), "image_max_edge": .int(800), "image_format": .string("jpeg"),
                                                 "image_quality": .double(0.6), "image_max_bytes": .int(500_000)])
        #expect(options == InlineImage.Options(include: true, maximumEdge: 800, format: .jpeg, quality: 0.6, byteLimit: 500_000))
        #expect(try MCPTools.imageOptions(["image_include": .bool(false)]).include == false)
        // Quality also applies to auto, which may choose JPEG.
        #expect(try MCPTools.imageOptions(["image_quality": .double(0.5)]).quality == 0.5)
        for invalid: [String: Value] in [["image_max_edge": .int(8)], ["image_max_edge": .int(100_000)], ["image_max_edge": .double(300.5)],
                                         ["image_max_bytes": .int(10)], ["image_max_bytes": .int(InlineImage.Options.byteRange.upperBound + 1)],
                                         ["image_quality": .double(0)], ["image_quality": .double(1.5)],
                                         ["image_format": .string("png"), "image_quality": .double(0.5)]] {
            #expect(throws: MCPError.self) { _ = try MCPTools.imageOptions(invalid) }
        }
    }

    @Test func onlyImageToolsCarryTheOptionsAndBadOnesStopBeforeCapture() async throws {
        let names = Set(MCPTools.imageFields.map(\.name))
        for definition in MCPTools.definitions {
            let has = !names.isDisjoint(with: definition.fields.map(\.name))
            #expect(has == (definition.imagePath != nil), "\(definition.name)")
        }
        await #expect(throws: MCPError.self) {
            _ = try await MCPTools.call(name: "screenshot", arguments: ["platform": "physical", "device": "fixture", "path": "tmp/x.png", "image_max_edge": .int(1)],
                                        execute: { _ in Issue.record("Captured despite an invalid image option"); return CommandOutput(data: Data()) })
        }
    }

    @Test func toolResultCarriesTheImageAndItsFactsAsData() async throws {
        let url = try png()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func call(_ extra: [String: Value]) async throws -> CallTool.Result {
            var arguments: [String: Value] = ["platform": "physical", "device": "fixture", "path": .string(url.path)]
            arguments.merge(extra) { $1 }
            return try await MCPTools.call(name: "screenshot", arguments: arguments, execute: { command in
                // The image options shape the result only; they never reach the CLI.
                #expect(command == ["screenshot", "--device=fixture", "--", url.path])
                return CommandOutput(data: Data("{\"ok\":true}".utf8))
            })
        }
        func images(_ result: CallTool.Result) -> [(Data, String)] {
            result.content.compactMap { if case .image(let data, let mimeType, _, _) = $0 { return (Data(base64Encoded: data) ?? Data(), mimeType) }; return nil }
        }
        func facts(_ result: CallTool.Result) -> [String: Value]? { result.structuredContent?.objectValue?["inlineImage"]?.objectValue }

        let reduced = try await call(["image_max_edge": .int(260), "image_format": .string("jpeg"), "image_quality": .double(0.4)])
        let sent = images(reduced)
        #expect(sent.count == 1 && sent[0].1 == "image/jpeg")
        let reducedFacts = try #require(facts(reduced))
        #expect(reducedFacts["included"] == .bool(true) && reducedFacts["format"] == .string("jpeg"))
        #expect(reducedFacts["height"] == .int(260) && reducedFacts["bytes"] == .int(sent[0].0.count))
        // A whole-number scale arrives as an integer in JSON.
        #expect(reducedFacts["scale"] == .int(5) || reducedFacts["scale"] == .double(5), "\(String(describing: reducedFacts["scale"]))")
        // The operation's own result is still there beside it.
        #expect(reduced.structuredContent?.objectValue?["result"]?.objectValue?["ok"] == .bool(true))

        let omitted = try await call(["image_include": .bool(false)])
        #expect(images(omitted).isEmpty && facts(omitted)?["included"] == .bool(false))
    }

    @Test func toolsWithoutAnImageReportNoInlineImage() async throws {
        let result = try await MCPTools.call(name: "doctor", arguments: [:], execute: { _ in CommandOutput(data: Data("[]".utf8)) })
        #expect(result.structuredContent?.objectValue?["inlineImage"] == nil)
    }
}
