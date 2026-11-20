import AudioToolbox
import Foundation

/// Decodes a device's system audio, one RTP payload at a time, with the
/// public AudioToolbox converter (docs/recording.md#sound). An iPhone 13 mini
/// sends AAC-ELD at 48 kHz in stereo, 480 samples (10 ms) a packet, each
/// payload one access unit with nothing around it; while the device plays
/// nothing every payload is the same four bytes.
final class NativeAudioDecoder {
    static let sampleRate = 48_000.0
    static let channels = 2
    static let framesPerPacket = 480

    private var converter: AudioConverterRef?
    /// The packet being decoded, for the converter's input callback.
    private var pending: [UInt8] = []
    private var description = AudioStreamPacketDescription()
    private var consumed = true

    init() throws {
        var input = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 0, mReserved: 0)
        var output = Self.pcmFormat
        guard AudioConverterNew(&input, &output, &converter) == noErr, converter != nil else {
            throw CommandFailure(.toolFailed, "The Mac has no decoder for the device's audio (AAC-ELD, 48 kHz, stereo).", inputSent: .none)
        }
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    /// 16-bit signed interleaved samples, what `decode` returns.
    static var pcmFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    }

    /// One packet's samples: 480 frames of two channels. A payload the
    /// decoder refuses throws; the caller writes silence for it.
    func decode(_ payload: [UInt8]) throws -> [Int16] {
        guard let converter, !payload.isEmpty else { throw CommandFailure(.transportFailed, "An empty audio packet.", inputSent: .none) }
        pending = payload
        consumed = false
        var samples = [Int16](repeating: 0, count: Self.framesPerPacket * Self.channels)
        var packets = UInt32(Self.framesPerPacket)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(Self.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, count, data, descriptions, context in
                guard let context else { return kAudio_ParamError }
                let decoder = Unmanaged<NativeAudioDecoder>.fromOpaque(context).takeUnretainedValue()
                // One packet for each call to `decode`; then "no more for now".
                guard !decoder.consumed else { count.pointee = 0; return 1 }
                decoder.consumed = true
                decoder.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(decoder.pending.count))
                decoder.pending.withUnsafeMutableBytes { bytes in
                    data.pointee.mNumberBuffers = 1
                    data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(NativeAudioDecoder.channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
                }
                withUnsafeMutablePointer(to: &decoder.description) { descriptions?.pointee = $0 }
                count.pointee = 1
                return noErr
            }, context, &packets, &list, nil)
        }
        // 1 is the callback's own "no more for now" after a packet was taken.
        guard status == noErr || status == 1 else {
            throw CommandFailure(.transportFailed, "The audio decoder refused a packet (OSStatus \(status)).", inputSent: .none)
        }
        return Array(samples.prefix(Int(packets) * Self.channels))
    }
}
