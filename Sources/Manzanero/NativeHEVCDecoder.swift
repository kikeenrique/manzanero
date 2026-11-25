import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import VideoToolbox

private struct NativeDecodedOutput<Value: Sendable>: Sendable {
    var status: OSStatus = 0
    var value: Value?
    var invalid = false
    var error: (any Error)?
}

/// Uses public VideoToolbox decoding. Both async/temporal flags are clear, so
/// Apple's contract completes the output handler before decode returns.
@MainActor
final class NativeHEVCDecoder {
    private let width: Int
    private let height: Int
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var parameters: [Data]?
    private var codedDimensions: (Int, Int)?
    private var closed = false
    private var previousTimestamp: UInt32?
    private var ticks: Int64 = 0
    private let context = CIContext()

    init(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000 else {
            // The dimensions are the ones negotiated with the device.
            throw CommandFailure(.transportFailed, "Invalid native HEVC video dimensions.", inputSent: .none)
        }
        self.width = width; self.height = height
    }

    isolated deinit { close() }

    func close() {
        closed = true
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; parameters = nil; codedDimensions = nil
    }

    func decode(_ unit: MediaHEVCAccessUnit, emitJPEG: Bool = true) throws -> Data? {
        let context = context
        return try decodeOutput(unit) { image in
            guard emitJPEG else { return nil }
            guard let jpeg = context.jpegRepresentation(of: CIImage(cvPixelBuffer: image), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]),
                  jpeg.count <= 8 * 1024 * 1024 else {
                throw CommandFailure(.toolFailed, "Native HEVC decoder produced invalid JPEG output.", inputSent: .none)
            }
            return jpeg
        }
    }

    /// Decodes one access unit (every unit must be decoded to keep references)
    /// and, when `emit`, returns the top-left `crop` pixels of the picture as
    /// JPEG at `quality`. The stream pads the screen to its negotiated size on
    /// the right and bottom (1125×2436 to 1136×2448 on an iPhone 13 mini), and
    /// the coded picture adds rows below that.
    func decodeFrameJPEG(_ unit: MediaHEVCAccessUnit, emit: Bool, crop: (width: Int, height: Int), quality: Double) throws -> Data? {
        let context = context
        let width = min(crop.width, width), height = min(crop.height, height)
        return try decodeOutput(unit) { image in
            guard emit else { return nil }
            let picture = CIImage(cvPixelBuffer: image)
            // Core Image's origin is the bottom left, so the top rows are kept.
            let visible = picture.cropped(to: CGRect(x: 0, y: picture.extent.height - CGFloat(height),
                                                     width: CGFloat(width), height: CGFloat(height)))
            let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            guard let jpeg = context.jpegRepresentation(of: visible, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options),
                  !jpeg.isEmpty, jpeg.count <= 8 * 1024 * 1024 else {
                throw CommandFailure(.toolFailed, "Native HEVC decoder produced invalid JPEG output.", inputSent: .none)
            }
            return jpeg
        }
    }

    /// The decoded picture's pixels, or its top-left `crop` pixels.
    func decodePixels(_ unit: MediaHEVCAccessUnit, emit: Bool, crop: (width: Int, height: Int)? = nil) throws -> CVReadOnlyPixelBuffer? {
        let context = context
        return try decodeOutput(unit) { image in
            guard emit else { return nil }
            return try NativeVideoFrame.copy(image, context: context, crop: crop)
        }
    }

    private func decodeOutput<Value: Sendable>(_ unit: MediaHEVCAccessUnit,
        transform: @escaping @Sendable (CVPixelBuffer) throws -> Value?) throws -> Value? {
        try Task.checkCancellation()
        guard !closed else { throw closedFailure }
        guard unit.parameterSets.count == (unit.codec == .h264 ? 2 : 3), unit.parameterSets.allSatisfy({ (2...65_535).contains($0.count) }),
              !unit.nals.isEmpty, unit.nals.count <= 256 else { throw failure("invalid access unit", stream: true) }
        var available = 8 * 1024 * 1024
        for nal in unit.nals {
            guard nal.count >= 2, nal.count + 4 <= available else { throw failure("oversized access unit", stream: true) }
            available -= nal.count + 4
        }
        if parameters == nil {
            guard unit.randomAccess else { throw failure("initial picture is not random access", stream: true) }
            try configure(unit.parameterSets, codec: unit.codec)
        } else if parameters != unit.parameterSets { throw failure("parameter sets changed during capture", stream: true) }
        guard let session, let format else { throw closedFailure }
        if let previousTimestamp {
            let delta = unit.timestamp &- previousTimestamp
            guard delta > 0, delta < 0x80000000 else { throw failure("reordered or repeated presentation timestamp", stream: true) }
            ticks += Int64(delta)
        }
        previousTimestamp = unit.timestamp
        let bytes = unit.lengthPrefixed
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block), "allocate sample")
        guard let block else { throw failure("missing sample allocation") }
        try bytes.withUnsafeBytes { pointer in
            try check(CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count), "copy sample")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: ticks, timescale: 90_000), decodeTimeStamp: .invalid)
        var size = bytes.count, sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "create sample")
        guard let sample else { throw failure("missing sample") }
        let result = Mutex(NativeDecodedOutput<Value>())
        guard let codedDimensions else { throw failure("coded dimensions are unavailable") }
        let width = codedDimensions.0, height = codedDimensions.1
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == 0, let image else { result.withLock { $0.status = status }; return }
            guard CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else {
                result.withLock { $0.invalid = true }; return
            }
            do {
                let value = try transform(image)
                result.withLock { $0.value = value }
            } catch { result.withLock { $0.error = error } }
        }
        try check(status, "decode sample")
        let output = result.withLock { $0 }
        try check(output.status, "output sample")
        guard !output.invalid else { throw failure("invalid decoded dimensions") }
        if let error = output.error { throw error }
        try Task.checkCancellation()
        return output.value
    }

    private func configure(_ sets: [Data], codec: MediaHEVCAccessUnit.Codec) throws {
        var description: CMFormatDescription?
        let sizes = sets.map(\.count)
        // One contiguous copy, so every set's pointer stays valid for the call.
        let joined = sets.reduce(Data(), +)
        let status = joined.withUnsafeBytes { raw -> OSStatus in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            var offset = 0
            let pointers = sizes.map { size -> UnsafePointer<UInt8> in defer { offset += size }; return base + offset }
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        try check(status, "read parameter sets")
        guard let description else { throw failure("missing format description") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard Self.acceptsCodedDimensions(Int(dimensions.width), Int(dimensions.height), negotiatedWidth: width, negotiatedHeight: height) else {
            throw failure("coded dimensions \(dimensions.width)x\(dimensions.height) differ from negotiated \(width)x\(height)", stream: true)
        }
        var decoder: VTDecompressionSession?
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &decoder), "create decoder")
        guard let decoder else { throw failure("missing decoder") }
        parameters = sets; format = description; session = decoder
        codedDimensions = (Int(dimensions.width), Int(dimensions.height))
    }

    /// The tested device codes 2448 negotiated rows as 2464 rows: bounded
    /// upward padding to a 32-pixel boundary, preserving actual pixels.
    /// An iPhone Duo streaming its inner display (2026-11-25) negotiated
    /// 1408 × 2048, its outer display's size, and coded 1408 × 2016: the
    /// inner display fitted into that frame. So a coded size may also be
    /// smaller, by at most a sixteenth on each side; every later step takes
    /// the decoded picture's own size. The iPhone 17 Pro Max (2026-11-25)
    /// negotiated 1328 × 2880, already on a 32-pixel boundary, and coded
    /// 2896 rows: one more 16-pixel block. So a larger coded size is padding
    /// when it is whole 16-pixel blocks and at most 32 pixels more.
    nonisolated static func acceptsCodedDimensions(_ width: Int, _ height: Int, negotiatedWidth: Int, negotiatedHeight: Int) -> Bool {
        func fits(_ coded: Int, _ negotiated: Int) -> Bool {
            let padded = coded <= (negotiated + 31) / 32 * 32 || (coded % 16 == 0 && coded <= negotiated + 32)
            return padded && coded >= negotiated - negotiated / 16
        }
        return (1...8192).contains(width) && (1...8192).contains(height) && width * height <= 20_000_000 &&
            (1...8192).contains(negotiatedWidth) && (1...8192).contains(negotiatedHeight) &&
            fits(width, negotiatedWidth) && fits(height, negotiatedHeight)
    }

    /// A VideoToolbox or Core Media step that failed is `tool-failed`; `stream`
    /// marks data from the device that is not what was negotiated
    /// (`transport-failed`). Decoding sends no input either way.
    private func failure(_ detail: String, stream: Bool = false) -> CommandFailure {
        CommandFailure(stream ? .transportFailed : .toolFailed, "Native HEVC decoder: \(detail).", inputSent: .none)
    }
    /// Use after `close()` is a caller error in this process.
    private var closedFailure: CommandFailure { CommandFailure(.internal, "Native HEVC decoder: decoder is closed.", inputSent: .none) }
    private func check(_ status: OSStatus, _ action: String) throws {
        if status != 0 { throw failure("\(action) failed (OSStatus \(status))") }
    }
}
