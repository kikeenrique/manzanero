import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import MCP
import Testing
@testable import Manzanero

struct NativeVideoTests {
    @available(macOS 26.0, *)
    @Test func decodedPixelsAreCopiedBeforeSourceReuse() throws {
        let context = CIContext()
        let source = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 64, height: 64)))
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        source.withUnsafeBuffer { context.render(CIImage(color: .init(red: 1, green: 0, blue: 0)).cropped(to: bounds), to: $0) }
        let copy = try source.withUnsafeBuffer { try NativeVideoFrame.copy($0, context: context) }
        source.withUnsafeBuffer { context.render(CIImage(color: .init(red: 0, green: 0, blue: 1)).cropped(to: bounds), to: $0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        copy.withUnsafeBuffer { context.render(CIImage(cvPixelBuffer: $0), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
        #expect(pixel[0] > 200 && pixel[2] < 40)
        let unsupported = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_OneComponent8), size: .init(width: 64, height: 64)))
        #expect(throws: CommandFailure.self) { try unsupported.withUnsafeBuffer { try NativeVideoFrame.copy($0, context: context) } }
    }

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

    @available(macOS 26.0, *)
    func packet(_ time: UInt64 = 0, pixels: CVReadOnlyPixelBuffer) -> NativeVideoFrame {
        NativeVideoFrame(nanoseconds: time, pixels: pixels)
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
        #expect(args == ["record", "--device=phone", "--backend=coredevice", "--", "tmp/native.mp4", "2", "h264"])
        guard case .record(let command) = try request(args) else { Issue.record("record_screen is not a recording request"); return }
        #expect(command.native)
        #expect(throws: CommandFailure.self) { try command.command(staging: URL(fileURLWithPath: "tmp/unused")) }
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).run(args, dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("AVFoundation"))
        #expect(throws: CommandFailure.self) {
            try RecordingCommand(physical: false, device: RecordingCommandTests().simulator, output: "tmp/no.mp4", seconds: "2", codec: nil, backend: "coredevice")
        }
    }

    @available(macOS 26.0, *)
    @Test(arguments: ["h264", "hevc"])
    func encodesStaticAndChangingFramesForRequestedDuration(_ codec: String) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/native-video-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CIContext()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func pixels(_ color: CIColor, width: Int = 64) throws -> CVReadOnlyPixelBuffer {
            let pixel = try CVMutablePixelBuffer(.init(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: width, height: 63)))
            pixel.withUnsafeBuffer { context.render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: 63)), to: $0) }
            return CVReadOnlyPixelBuffer(pixel)
        }
        let red = try pixels(CIColor(red: 1, green: 0, blue: 0))
        let blue = try pixels(CIColor(red: 0, green: 0, blue: 1))
        for changing in [false, true] {
            let path = root.appendingPathComponent("\(changing).mp4")
            let encoder = try NativeVideoEncoder(destination: path, seconds: 1, codec: codec)
            try await encoder.consume(packet(pixels: red))
            if changing { try await encoder.consume(packet(500_000_000, pixels: blue)) }
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
        try await invalid.consume(packet(pixels: red))
        await #expect(throws: CommandFailure.self) { try await invalid.consume(packet(100, pixels: pixels(CIColor(red: 0, green: 0, blue: 0), width: 32))) }
        await invalid.cancel()
        for times: [UInt64] in [[1], [0, 0], [0, 1_000_000_000]] {
            let invalidTime = try NativeVideoEncoder(destination: root.appendingPathComponent("time-\(UUID().uuidString).mp4"), seconds: 1, codec: codec)
            do {
                for time in times { try await invalidTime.consume(packet(time, pixels: red)) }
                Issue.record("Invalid frame timeline was accepted")
            } catch { #expect(error is CommandFailure) }
            await invalidTime.cancel()
        }
    }
}
