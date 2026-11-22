import Foundation

/// A device's audio stream turned into timed samples for a movie
/// (docs/recording.md#sound). The first packet is put where it arrived on
/// the movie's timeline; from there time follows the packets' own RTP
/// timestamps, 48 000 to the second, so the network's jitter does not reach
/// the sound. A packet that was lost becomes silence of its length, and one
/// the decoder refuses becomes silence too.
struct NativeAudioTrack {
    struct Receipt: Sendable, Equatable {
        var packets = 0
        /// Packets missing between two that arrived, by their timestamps.
        var lost = 0
        var refused = 0
        var seconds = 0.0
        /// RTCP receiver reports sent for the stream, and why none were, if none.
        var receiverReportsSent: UInt64 = 0
        var reportsNote: String?
        /// Sound streams started again after a recording's restart.
        var restarts = 0
    }

    /// The stream's receiver reports, which the media session sends.
    mutating func reports(sent: UInt64, note: String?) {
        receipt.receiverReportsSent = sent
        receipt.reportsNote = note
    }

    /// Samples and where they begin on the movie's timeline.
    struct Piece {
        let samples: [Int16]
        let nanoseconds: UInt64
    }

    /// A gap longer than this is not filled: the timeline starts again at
    /// the next packet's arrival.
    static let longestFilledGap = 2 * Int(NativeAudioDecoder.sampleRate)

    private let payloadType: UInt8
    private var decoder: NativeAudioDecoder
    private var anchor: (timestamp: UInt32, nanoseconds: UInt64)?
    private var next: UInt32 = 0
    /// Where the last piece ended on the movie's timeline.
    private var end: UInt64 = 0
    private(set) var receipt = Receipt()

    /// A recording restarted its session (docs/recording-recovery.md): the
    /// new sound stream has timestamps of its own, so its first packet
    /// starts a new timeline where it arrives, never before the last piece
    /// ended, and decoding starts afresh. The time between is a gap.
    mutating func restart() throws {
        anchor = nil
        decoder = try NativeAudioDecoder()
        receipt.restarts += 1
    }

    init(profile: NativeMediaFrames.AudioProfile) throws {
        guard profile.sampleRate == Int(NativeAudioDecoder.sampleRate) else {
            throw CommandFailure(.transportFailed, "The device agreed on audio at \(profile.sampleRate) Hz, which this recorder does not decode (48000 Hz AAC-ELD only).", inputSent: .none)
        }
        payloadType = profile.payloadType
        decoder = try NativeAudioDecoder()
    }

    /// In whole numbers: computed in floating point and truncated, about one
    /// 480-sample piece in 58 came out a nanosecond before the previous
    /// piece's end, the movie writer skipped it, and the sound ran ahead of
    /// the picture by 1.7% (the iPhone 13 mini, 2026-11-21).
    private func time(_ timestamp: UInt32, from anchor: (timestamp: UInt32, nanoseconds: UInt64)) -> UInt64 {
        anchor.nanoseconds + Self.nanoseconds(frames: UInt64(timestamp &- anchor.timestamp))
    }

    /// The length of `frames` samples at 48 kHz, exactly: 480 are 10 ms.
    static func nanoseconds(frames: UInt64) -> UInt64 {
        frames * 1_000_000_000 / UInt64(NativeAudioDecoder.sampleRate)
    }

    /// Whole samples at 48 kHz in `nanoseconds`, rounded down: the length of
    /// silence that fills a gap without passing the next piece's start.
    static func frames(nanoseconds: UInt64) -> Int {
        Int(nanoseconds * UInt64(NativeAudioDecoder.sampleRate) / 1_000_000_000)
    }

    /// One datagram of the stream, arrived `nanoseconds` after the movie's
    /// first picture. Sender reports and anything that is not this stream's
    /// payload give nothing.
    mutating func accept(_ datagram: Data, nanoseconds: UInt64) -> [Piece] {
        guard let packet = MediaRTPPacket(datagram, payloadType: payloadType) else { return [] }
        var pieces: [Piece] = []
        var start = anchor ?? (packet.timestamp, max(nanoseconds, end))
        if anchor == nil { next = packet.timestamp }
        let ahead = packet.timestamp &- next
        // A packet from before the one expected: late or repeated.
        guard ahead < 0x8000_0000 else { return [] }
        if ahead > 0 {
            if Int(ahead) <= Self.longestFilledGap {
                receipt.lost += Int(ahead) / NativeAudioDecoder.framesPerPacket
                pieces.append(Piece(samples: [Int16](repeating: 0, count: Int(ahead) * NativeAudioDecoder.channels), nanoseconds: time(next, from: start)))
            } else {
                start = (packet.timestamp, max(nanoseconds, end))
            }
        }
        anchor = start
        let silence = [Int16](repeating: 0, count: NativeAudioDecoder.framesPerPacket * NativeAudioDecoder.channels)
        var samples = silence
        do { samples = try decoder.decode(Array(packet.payload)) } catch { receipt.refused += 1 }
        if samples.isEmpty { samples = silence }
        let at = time(packet.timestamp, from: start)
        pieces.append(Piece(samples: samples, nanoseconds: at))
        end = at + Self.nanoseconds(frames: UInt64(samples.count / NativeAudioDecoder.channels))
        next = packet.timestamp &+ UInt32(samples.count / NativeAudioDecoder.channels)
        receipt.packets += 1
        receipt.seconds += Double(samples.count / NativeAudioDecoder.channels) / NativeAudioDecoder.sampleRate
        return pieces
    }
}
