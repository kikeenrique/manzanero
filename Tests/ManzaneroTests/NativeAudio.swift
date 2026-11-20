import Foundation
import MCP
import Testing
@testable import Manzanero

/// A recording's sound: the decoder and the timeline, with the packet an
/// iPhone 13 mini sends while it plays nothing (four bytes of AAC-ELD).
struct NativeAudioTests {
    /// What the phone sent every 10 ms while silent.
    private static let silentPayload: [UInt8] = [0x00, 0x68, 0x34, 0x00]
    private static let profile = NativeMediaFrames.AudioProfile(payloadType: 101, streamIdentifier: 7, codecType: 0,
                                                                sampleRate: 48_000, channels: 0, packetMilliseconds: 0)

    private static func packet(sequence: UInt16, timestamp: UInt32, payloadType: UInt8 = 101, payload: [UInt8] = silentPayload) -> Data {
        Data([0x80, payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xff),
              UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xff), UInt8(timestamp >> 8 & 0xff), UInt8(timestamp & 0xff), 0, 0, 0, 7] + payload)
    }

    @Test func theSilentPacketDecodesToOnePacketOfSilence() throws {
        let decoder = try NativeAudioDecoder()
        for _ in 0..<3 {
            let samples = try decoder.decode(Self.silentPayload)
            #expect(samples.count == 480 * 2 && samples.allSatisfy { abs(Int($0)) < 8 })
        }
        #expect(throws: CommandFailure.self) { try decoder.decode([]) }
    }

    @Test func timeFollowsThePacketsOwnTimestampsFromTheFirstArrival() throws {
        var track = try NativeAudioTrack(profile: Self.profile)
        // The first packet arrives 30 ms into the movie; the next two are
        // 10 ms apart by their timestamps, whenever they arrive.
        let first = track.accept(Self.packet(sequence: 1, timestamp: 1000), nanoseconds: 30_000_000)
        let second = track.accept(Self.packet(sequence: 2, timestamp: 1480), nanoseconds: 95_000_000)
        let third = track.accept(Self.packet(sequence: 3, timestamp: 1960), nanoseconds: 96_000_000)
        #expect(first.map(\.nanoseconds) == [30_000_000] && second.map(\.nanoseconds) == [40_000_000] && third.map(\.nanoseconds) == [50_000_000])
        #expect(first[0].samples.count == 960)
        #expect(track.receipt.packets == 3 && track.receipt.lost == 0 && abs(track.receipt.seconds - 0.03) < 0.0001)
    }

    @Test func aLostPacketBecomesSilenceAndALateOneIsDropped() throws {
        var track = try NativeAudioTrack(profile: Self.profile)
        _ = track.accept(Self.packet(sequence: 1, timestamp: 0), nanoseconds: 0)
        // Two packets are missing before this one.
        let after = track.accept(Self.packet(sequence: 4, timestamp: 1440), nanoseconds: 31_000_000)
        #expect(after.count == 2 && after[0].samples.count == 960 * 2 && after[0].nanoseconds == 10_000_000 && after[1].nanoseconds == 30_000_000)
        #expect(track.receipt.lost == 2)
        // One of the missing ones arrives after all: too late for the movie.
        #expect(track.accept(Self.packet(sequence: 2, timestamp: 480), nanoseconds: 32_000_000).isEmpty)
        // A gap of more than two seconds is not filled: time starts again.
        let later = track.accept(Self.packet(sequence: 900, timestamp: 1920 + 48_000 * 3), nanoseconds: 3_500_000_000)
        #expect(later.count == 1 && later[0].nanoseconds == 3_500_000_000)
    }

    @Test func otherDatagramsGiveNothingAndARefusedPayloadIsSilence() throws {
        var track = try NativeAudioTrack(profile: Self.profile)
        // A sender report, and another stream's payload type.
        #expect(track.accept(Data([0x81, 0xc8, 0, 6] + [UInt8](repeating: 0, count: 24)), nanoseconds: 0).isEmpty)
        #expect(track.accept(Self.packet(sequence: 1, timestamp: 0, payloadType: 100), nanoseconds: 0).isEmpty)
        let refused = track.accept(Self.packet(sequence: 1, timestamp: 0, payload: [0xff]), nanoseconds: 0)
        #expect(refused.count == 1 && refused[0].samples.count == 960 && track.receipt.packets == 1)
        // A device that agreed on another rate is refused before any packet.
        #expect(throws: CommandFailure.self) {
            _ = try NativeAudioTrack(profile: .init(payloadType: 104, streamIdentifier: 7, codecType: 0, sampleRate: 24_000, channels: 0, packetMilliseconds: 0))
        }
    }

    @Test func audioIsThePhysicalInProcessBackendsOption() async throws {
        let udid = "00008110-000A11112222801E"
        let native = try RecordingCommand(physical: true, device: udid, output: "tmp/a.mp4", seconds: "2", codec: nil, backend: "coredevice")
        #expect(try native.withAudio(true).audio && !native.withAudio(false).audio)
        let plain = try RecordingCommand(physical: true, device: udid, output: "tmp/a.mp4", seconds: "2", codec: nil, backend: nil)
        #expect(throws: CommandFailure.self) { try plain.withAudio(true) }
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried the device"); return Data() })
        let output = try await service.run(["record", "tmp/a.mp4", "2", "--backend", "coredevice", "--audio", "--device", udid], dryRun: true)
        let plan = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["audio"] as? Bool == true)
        await #expect(throws: CommandFailure.self) { try await service.run(["record", "tmp/a.mp4", "2", "--audio", "--device", udid], dryRun: true) }
        let tool = try #require(MCPTools.definitions.first { $0.name == "record_screen" })
        let args = try tool.command(["platform": "physical", "device": .string(udid), "path": "tmp/a.mp4", "seconds": 2,
                                     "recording_backend": "coredevice", "audio": true])
        #expect(args.contains("--audio") && args.contains("--backend=coredevice"))
    }
}
