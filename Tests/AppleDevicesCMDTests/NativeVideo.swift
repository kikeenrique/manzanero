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

    func packet(_ time: UInt64 = 0, jpeg: Data = Data([0xff, 0xd8, 0xff, 0xd9])) -> TimedVideoFrame {
        TimedVideoFrame(nanoseconds: time, jpeg: jpeg)
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
        #expect(throws: CommandFailure.self) { try command.command(staging: URL(fileURLWithPath: "tmp/unused")) }
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
        for times: [UInt64] in [[1], [0, 0], [0, 1_000_000_000]] {
            let invalidTime = try NativeVideoEncoder(destination: root.appendingPathComponent("time-\(UUID().uuidString).mp4"), seconds: 1, codec: codec)
            do {
                for time in times { try await invalidTime.consume(packet(time, jpeg: red)) }
                Issue.record("Invalid frame timeline was accepted")
            } catch { #expect(error is CommandFailure) }
            await invalidTime.cancel()
        }
    }
}
