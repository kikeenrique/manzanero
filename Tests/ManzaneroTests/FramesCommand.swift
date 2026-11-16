import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers
@testable import Manzanero

struct FramesCommandTests {
    static let device = CLIParserTests.device
    static let ms: UInt64 = 1_000_000

    /// A fresh directory under ./tmp that the test removes afterwards.
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/frames-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A small real JPEG of the given size.
    static func jpeg(width: Int = 40, height: Int = 80, shade: UInt8 = 128) throws -> Data {
        var pixels = [UInt8](repeating: shade, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func command(_ directory: URL, count: Int = 10, seconds: Double? = nil, interval: Int = 0, overwrite: Bool = false) -> FramesCommand {
        FramesCommand(device: Self.device, directory: directory, count: count, seconds: seconds, intervalMilliseconds: interval, overwrite: overwrite)
    }

    @Test func defaultsDependOnWhetherADurationIsGiven() throws {
        guard case .frames(let plain) = try request(["frames", "tmp/f", "--device", Self.device]) else { Issue.record("not frames"); return }
        #expect(plain.count == 10 && plain.seconds == nil && plain.intervalMilliseconds == 0 && !plain.overwrite)
        guard case .frames(let timed) = try request(["frames", "tmp/f", "--seconds", "5", "--interval", "500", "--device", Self.device]) else { Issue.record("not frames"); return }
        #expect(timed.count == FramesCommand.maximumCount && timed.seconds == 5 && timed.intervalMilliseconds == 500)
    }

    @Test(arguments: [["--count", "0"], ["--count", "1001"], ["--count", "2.5"], ["--seconds", "0.4"], ["--seconds", "301"],
                      ["--seconds", "nan"], ["--interval", "-1"], ["--interval", "60001"], ["--interval", "x"]])
    func outOfRangeOptionsAreUsageErrors(_ options: [String]) throws {
        let failure = try #require(throws: CommandFailure.self) { try request(["frames", "tmp/f", "--device", Self.device] + options) }
        #expect(failure.code == .usage && failure.inputSent == .none)
    }

    @Test func simulatorsAreReferredToScreenshotBeforeAnyContact() throws {
        let failure = try #require(throws: CommandFailure.self) { try request(["frames", "tmp/f", "--simulator", CLIParserTests.simulator]) }
        #expect(failure.code == .unsupportedOperation && failure.description.contains("screenshot"))
        let dashed = try #require(throws: CommandFailure.self) { try request(["frames", "--device", Self.device, "--", "-f"]) }
        #expect(dashed.code == .usage)
    }

    @Test func requestTakesTheLeaseRouteAndRunsUnderTheSignalScope() throws {
        let parsed = try request(["frames", "tmp/f", "--device", Self.device])
        #expect(parsed.signalContext == "frame capture")
        #expect(parsed.addressed?.operation == "frames" && parsed.addressed?.platform == "physical")
        // Not an observation: a pending handoff pauses it, like a recording.
        #expect(!CommandService.observationOperations.contains("frames"))
    }

    @Test func dryRunPlansWithoutQueryingTheDeviceOrTouchingTheDirectory() async throws {
        try await withDirectoryAsync { root in
            let target = root.appendingPathComponent("planned")
            let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
            let output = try await service.run(["frames", target.path, "--count", "3", "--device", Self.device], dryRun: true)
            let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["operation"] as? String == "frames" && plan["count"] as? Int == 3)
            #expect(plan["minimumSpacingMilliseconds"] as? Int == 33 && plan["backend"] as? String == "coredevice-videotoolbox")
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func withDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/frames-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @Test func directoryIsCreatedOrMustBeEmptyUnlessOverwriting() throws {
        try withDirectory { root in
            let fresh = root.appendingPathComponent("new")
            try command(fresh).prepareDirectory()
            #expect(FileManager.default.fileExists(atPath: fresh.path))
            try command(fresh).prepareDirectory() // empty: accepted
            try Data("x".utf8).write(to: fresh.appendingPathComponent("other.txt"))
            let busy = try #require(throws: CommandFailure.self) { try command(fresh).prepareDirectory() }
            #expect(busy.code == .usage && busy.description.contains("--overwrite"))
            try command(fresh, overwrite: true).prepareDirectory()
            let orphan = try #require(throws: CommandFailure.self) { try command(root.appendingPathComponent("missing/child")).prepareDirectory() }
            #expect(orphan.description.contains("parent must exist"))
            let file = root.appendingPathComponent("file")
            try Data().write(to: file)
            #expect(throws: CommandFailure.self) { try command(file, overwrite: true).prepareDirectory() }
        }
    }

    @Test func framesFollowTheIntervalGridAndStopAtTheCount() throws {
        try withDirectory { root in
            var run = FrameRun(command: command(root, count: 3, interval: 500), started: 0)
            let frame = try Self.jpeg()
            #expect(run.wants(at: 1_000 * Self.ms))
            #expect(try run.save(frame, at: 1_000 * Self.ms) == nil)
            #expect(!run.wants(at: 1_499 * Self.ms))
            // Due at 1500 ms; a late delivery does not move the next one.
            #expect(run.wants(at: 1_620 * Self.ms))
            #expect(try run.save(frame, at: 1_620 * Self.ms) == nil)
            #expect(!run.wants(at: 1_999 * Self.ms) && run.wants(at: 2_000 * Self.ms))
            #expect(run.stopReason(at: 2_000 * Self.ms) == nil)
            #expect(try run.save(frame, at: 2_010 * Self.ms) == nil)
            #expect(run.stopReason(at: 2_011 * Self.ms) == .count)
            #expect(run.entries.map(\.file) == ["frame-0001.jpg", "frame-0002.jpg", "frame-0003.jpg"])
            #expect(run.entries.map(\.offsetMilliseconds) == [0, 620, 1010])
            #expect(run.entries.allSatisfy { $0.width == 40 && $0.height == 80 && $0.bytes == frame.count })
            #expect(run.firstFrameDelayMilliseconds == 1000)
            #expect(try Data(contentsOf: root.appendingPathComponent("frame-0002.jpg")) == frame)
        }
    }

    @Test func everyFrameIsKeptAtLeastTheMinimumSpacingApart() throws {
        try withDirectory { root in
            var run = FrameRun(command: command(root, count: 10), started: 0)
            _ = try run.save(Self.jpeg(), at: 0)
            #expect(!run.wants(at: 32 * Self.ms) && run.wants(at: 33 * Self.ms))
        }
    }

    @Test func durationCountsFromTheFirstFrameAndBytesAreBudgeted() throws {
        try withDirectory { root in
            let frame = try Self.jpeg()
            var timed = FrameRun(command: command(root, count: 1000, seconds: 2), started: 0)
            #expect(timed.stopReason(at: 50_000 * Self.ms) == nil) // no first frame yet
            _ = try timed.save(frame, at: 3_000 * Self.ms)
            #expect(timed.stopReason(at: 4_999 * Self.ms) == nil && timed.stopReason(at: 5_000 * Self.ms) == .duration)
            var budget = FrameRun(command: command(root, count: 10, overwrite: true), started: 0, byteLimit: frame.count * 2 + 1)
            #expect(try budget.save(frame, at: 0) == nil && budget.save(frame, at: 100 * Self.ms) == nil)
            #expect(try budget.save(frame, at: 200 * Self.ms) == .byteLimit)
            #expect(budget.entries.count == 2 && budget.totalBytes == frame.count * 2)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("frame-0003.jpg").path))
            var invalid = FrameRun(command: command(root, count: 10, overwrite: true), started: 0)
            #expect(throws: CommandFailure.self) { _ = try invalid.save(Data("not a jpeg".utf8), at: 300 * Self.ms) }
            #expect(throws: CommandFailure.self) { _ = try invalid.save(Data(), at: 300 * Self.ms) }
            #expect(invalid.entries.isEmpty)
        }
    }

    @Test func indexListsEveryFrameAndAnInterruptedRunSaysSo() throws {
        try withDirectory { root in
            var run = FrameRun(command: command(root, count: 5, interval: 100), started: 0)
            _ = try run.save(Self.jpeg(shade: 10), at: 400_123_456)
            _ = try run.save(Self.jpeg(shade: 200), at: 500_200_000)
            try run.writeIndex(status: "interrupted", stopReason: .interrupted)
            let data = try Data(contentsOf: root.appendingPathComponent(FramesCommand.indexName))
            let index = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(index["status"] as? String == "interrupted" && index["stopReason"] as? String == "interrupted")
            #expect(index["frameCount"] as? Int == 2 && index["lastFrame"] as? String == root.appendingPathComponent("frame-0002.jpg").path)
            let frames = try #require(index["frames"] as? [[String: Any]])
            #expect(frames.map { $0["file"] as? String } == ["frame-0001.jpg", "frame-0002.jpg"])
            // One decimal, written without binary noise.
            #expect(String(decoding: data, as: UTF8.self).contains("\"offsetMilliseconds\" : 100.1"))
            #expect(String(decoding: data, as: UTF8.self).contains("\"firstFrameDelayMilliseconds\" : 400.1"))
        }
    }

    @Test func savedFramesAreCroppedToTheDisplayWhenTheStreamHoldsIt() {
        let phone = DirectTouchDisplay(portraitPoints: 1125, height: 2436, scale: 3)
        #expect(FramesCommand.visibleSize(display: phone, stream: (1136, 2448)) == (1125, 2436))
        // A display larger than the stream keeps the whole negotiated picture.
        let large = DirectTouchDisplay(portraitPoints: 2048, height: 2732, scale: 2)
        #expect(FramesCommand.visibleSize(display: large, stream: (1136, 2448)) == (1136, 2448))
    }

    @Test func mcpToolRoutesThroughTheCLIParserAndReturnsTheLastFrame() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "capture_frames" })
        #expect(tool.imagePath == "lastFrame" && tool.imageFromResult && !tool.readOnly)
        let args = try tool.command(["device": "phone", "directory": "tmp/f", "count": 4, "seconds": 2.5, "interval_ms": 250, "overwrite": true])
        #expect(args == ["frames", "--device=phone", "--count=4", "--seconds=2.5", "--interval=250", "--overwrite", "--", "tmp/f"])
        #expect(summary(try request(args)) == ["physical", "phone", "frames", "tmp/f", "--count", "4", "--seconds", "2.5", "--interval", "250", "--overwrite"])
        let plain = try tool.command(["device": "phone", "directory": "-odd"])
        #expect(plain == ["frames", "--device=phone", "--", "-odd"])
        #expect(throws: MCPError.self) { try tool.command(["device": "phone", "directory": "tmp/f", "platform": "simulator"]) }
        #expect(throws: MCPError.self) { try tool.command(["device": "phone", "directory": "tmp/f", "count": 2.5]) }
    }

    @Test func aSavedJPEGTravelsInlineAsJPEG() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("frame-0001.jpg")
            let data = try Self.jpeg(width: 300, height: 600)
            try data.write(to: url)
            guard case .attached(let same) = try InlineImage.attachment(for: url) else { Issue.record("not attached"); return }
            #expect(same.encoding == .jpeg && same.data == data && same.scale == 1 && same.note == nil)
            guard case .attached(let reduced) = try InlineImage.attachment(for: url, options: .init(maximumEdge: 300)) else { Issue.record("not attached"); return }
            #expect(reduced.encoding == .jpeg && reduced.height == 300 && reduced.note?.contains("full-resolution JPEG") == true)
            guard case .attached(let png) = try InlineImage.attachment(for: url, options: .init(format: .png)) else { Issue.record("not attached"); return }
            #expect(png.encoding == .png)
            #expect(try InlineImage.attachment(for: url, options: .init(include: false)) == .omitted("JPEG saved; inline image omitted as requested."))
        }
    }
}
