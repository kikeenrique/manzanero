import AVFoundation
import CoreImage
import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct NativeVideoTests {
    @Test func recordingReservationsRejectDuplicateUUIDsAndReleaseForReuse() async throws {
        let sessions = NativeRecordingSessions()
        try await sessions.begin("ABCD")
        await #expect(throws: CommandFailure.self) { try await sessions.begin("abcd") }
        try await sessions.begin("other-device")
        await sessions.end("abcd")
        try await sessions.begin("ABCD")
        await sessions.end("ABCD")
        await sessions.end("other-device")
    }

    func packet(_ time: UInt64 = 0, jpeg: Data = Data([0xff, 0xd8, 0xff, 0xd9])) -> Data {
        var length = UInt32(jpeg.count).bigEndian
        var timestamp = time.bigEndian
        var data = Data("ADV1".utf8)
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
        data.append(jpeg)
        return data
    }

    @Test func framingSurvivesEverySplitAndNonzeroDataIndices() throws {
        let bytes = packet() + packet(500_000_000)
        for split in 0...bytes.count {
            var parser = TimedVideoFrames(maximumNanoseconds: 1_000_000_000)
            let padded = Data([0]) + bytes
            let frames = try parser.feed(padded[1..<(split + 1)]) + parser.feed(padded[(split + 1)...])
            try parser.finish()
            #expect(frames.map(\.nanoseconds) == [0, 500_000_000])
            #expect(frames.map(\.jpeg) == [Data([0xff, 0xd8, 0xff, 0xd9]), Data([0xff, 0xd8, 0xff, 0xd9])])
        }
        var parser = TimedVideoFrames(maximumNanoseconds: 1_000_000_000)
        var times: [UInt64] = []
        for byte in bytes { times += try parser.feed(Data([byte])).map(\.nanoseconds) }
        try parser.finish()
        #expect(times == [0, 500_000_000])
    }

    @Test func rejectsCorruptOrUnboundedFrameStreams() throws {
        var badMagic = packet(); badMagic[0] = 0
        var excessive = packet(); excessive.replaceSubrange(4..<8, with: [0xff, 0xff, 0xff, 0xff])
        for bytes in [badMagic, excessive, packet(1), packet() + packet(), packet() + packet(1_000_000_000), packet(jpeg: Data([0, 0, 0, 0]))] {
            var parser = TimedVideoFrames(maximumNanoseconds: 1_000_000_000)
            #expect(throws: CommandFailure.self) { try parser.feed(bytes) }
        }
        for end in 0..<packet().count {
            var parser = TimedVideoFrames(maximumNanoseconds: 1_000_000_000)
            _ = try parser.feed(packet().prefix(end))
            #expect(throws: CommandFailure.self) { try parser.finish() }
        }
    }

    @Test func tunnelSelectionRequiresMatchingIdentityAndUniqueActivePrefix() throws {
        let identity = CoreDeviceInputTests()
        let mask = Array(repeating: UInt8(255), count: 8) + Array(repeating: UInt8(0), count: 8)
        let host = NativeMediaEndpoint.Interface(name: "utun4", address: "fd00:1234::2", mask: mask, up: true)
        func inventory(_ address: String = "fd00:1234::1", state: String = "connected", duplicate: Bool = false) throws -> Data {
            let device: [String: Any] = ["identifier": identity.uuid, "connectionProperties": ["tunnelState": state, "tunnelIPAddress": address]]
            return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": duplicate ? [device, device] : [device]]])
        }
        let selected = try NativeMediaEndpoint.resolve(details: identity.details(), inventory: inventory(), requested: identity.udid, interfaces: [host])
        #expect(selected.uuid == identity.uuid)
        #expect(selected.host == host.address)
        for interfaces in [[], [host, host], [.init(name: "en0", address: host.address, mask: mask, up: true)], [.init(name: "utun4", address: host.address, mask: mask, up: false)], [.init(name: "utun4", address: "fd00:4321::2", mask: mask, up: true)]] {
            #expect(throws: CommandFailure.self) { try NativeMediaEndpoint.resolve(details: identity.details(), inventory: inventory(), requested: identity.udid, interfaces: interfaces) }
        }
        for snapshot in [try inventory("invalid"), try inventory(state: "disconnected"), try inventory(duplicate: true)] {
            #expect(throws: CommandFailure.self) { try NativeMediaEndpoint.resolve(details: identity.details(), inventory: snapshot, requested: identity.udid, interfaces: [host]) }
        }
        #expect(throws: CommandFailure.self) { try NativeMediaEndpoint.resolve(details: identity.details(mode: "disabled"), inventory: inventory(), requested: identity.udid, interfaces: [host]) }
        #expect(throws: CommandFailure.self) { try NativeMediaEndpoint.resolve(details: identity.details(hardware: "different"), inventory: inventory(), requested: identity.udid, interfaces: [host]) }
    }

    @Test func nativeRecordingRoutingIsExplicitAndDryRunDoesNotQueryDevice() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "record_screen" })
        let args = try tool.command(["platform": "physical", "device": "phone", "path": "tmp/native.mp4", "seconds": 2, "recording_backend": "coredevice"])
        let command = try #require(try RecordingCommand.parse(args))
        #expect(command.native)
        #expect(command.command(staging: URL(fileURLWithPath: "tmp/unused")).arguments.contains("--timed-stdout"))
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("AVFoundation"))
        #expect(throws: CommandFailure.self) { try RecordingCommand.parse(["--recording-backend", "coredevice", "simulator", RecordingCommandTests().simulator, "record", "tmp/no.mp4", "2"]) }
    }

    @available(macOS 26.0, *)
    @Test(arguments: ["h264", "hevc"])
    func encodesStaticAndChangingFramesForRequestedDuration(_ codec: String) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/native-video-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CIContext()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func jpeg(_ color: CIColor, width: Int = 64) throws -> Data {
            try #require(context.jpegRepresentation(of: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: 63)), colorSpace: space))
        }
        let red = try jpeg(CIColor(red: 1, green: 0, blue: 0))
        let blue = try jpeg(CIColor(red: 0, green: 0, blue: 1))
        for changing in [false, true] {
            let path = root.appendingPathComponent("\(changing).mp4")
            let encoder = try NativeVideoEncoder(destination: path, seconds: 1, codec: codec)
            try await encoder.consume(packet(jpeg: red))
            if changing { try await encoder.consume(packet(500_000_000, jpeg: blue)) }
            #expect(try await encoder.finish() == (changing ? 2 : 1))
            let artifact = try await VideoArtifact.inspect(path)
            #expect(abs(artifact.duration - 1) < 0.02)
            #expect(artifact.width == 64 && artifact.height == 64)
            #expect(artifact.codec == (codec == "h264" ? "avc1" : "hvc1"))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: path))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for (time, expectBlue) in [(0.0, false), (0.5, changing)] {
                // Static streams have no sample at 0.5; their frame persists.
                if changing || time == 0 {
                    let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
                    var pixel = [UInt8](repeating: 0, count: 4)
                    context.render(CIImage(cgImage: frame.image), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8, colorSpace: space)
                    #expect(expectBlue ? pixel[2] > 200 && pixel[0] < 40 : pixel[0] > 200 && pixel[2] < 40, "codec=\(codec), changing=\(changing), time=\(time), actual=\(frame.actualTime.seconds), RGBA=\(pixel)")
                }
            }
        }
        let invalid = try NativeVideoEncoder(destination: root.appendingPathComponent("invalid.mp4"), seconds: 1, codec: codec)
        try await invalid.consume(packet(jpeg: red))
        await #expect(throws: CommandFailure.self) { try await invalid.consume(packet(100, jpeg: jpeg(CIColor(red: 0, green: 0, blue: 0), width: 32))) }
        await invalid.cancel()
        let malformed = try NativeVideoEncoder(destination: root.appendingPathComponent("malformed.mp4"), seconds: 1, codec: codec)
        await #expect(throws: CommandFailure.self) { try await malformed.consume(packet()) }
        await malformed.cancel()
        let truncated = try NativeVideoEncoder(destination: root.appendingPathComponent("truncated.mp4"), seconds: 1, codec: codec)
        try await truncated.consume(packet(jpeg: red))
        try await truncated.consume(Data("ADV".utf8))
        await #expect(throws: CommandFailure.self) { try await truncated.finish() }
        await truncated.cancel()
    }
}
