import Foundation
import Vision

struct ScreenText: Encodable, Sendable {
    struct DeadlineExceeded: Error, CustomStringConvertible, Sendable {
        var description: String { "Vision OCR recognition deadline exceeded; cancellation requested and recognition task drained. Native cancellation is cooperative." }
    }

    struct Region: Encodable, Sendable {
        let text: String
        let confidence: Float
        /// Normalized image coordinates, with origin at the top left.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let source: String
    let coordinateSpace = "normalized-top-left"
    let regions: [Region]

    /// `clock` measures the deadline; tests inject a manual clock so expiry
    /// does not depend on wall-clock scheduling.
    static func recognize<C: Clock>(path: String, timeout: Duration = .seconds(120), clock: C = ContinuousClock(),
                                    perform: @Sendable @escaping (URL) async throws -> [Region] = recognizeRegions)
        async throws -> ScreenText where C.Duration == Duration {
        try Task.checkCancellation()
        guard timeout > .zero, timeout <= .seconds(300) else {
            throw CommandFailure(.internal, "OCR recognition deadline must be positive and at most 300 seconds.", inputSent: .none)
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CommandFailure.usage("Image is not readable: \(path)")
        }
        let deadline = clock.now.advanced(by: timeout)
        do {
            // Structured scope drains recognition after cancellation. The
            // deadline cannot forcibly stop an unresponsive native request.
            let regions = try await withThrowingTaskGroup(of: [Region].self) { group in
                group.addTask {
                    try await clock.sleep(until: deadline, tolerance: nil)
                    throw DeadlineExceeded()
                }
                group.addTask {
                    try Task.checkCancellation()
                    let regions = try await perform(url)
                    try Task.checkCancellation()
                    guard clock.now < deadline else { throw DeadlineExceeded() }
                    return regions
                }
                defer { group.cancelAll() }
                guard let regions = try await group.next() else { throw CancellationError() }
                return regions
            }
            try Task.checkCancellation()
            return ScreenText(source: url.path, regions: regions)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func recognizeRegions(_ url: URL) async throws -> [Region] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        try Task.checkCancellation()
        let observations = try await request.perform(on: url)
        try Task.checkCancellation()
        return observations.compactMap { observation -> Region? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let frame = observation.boundingBox.cgRect
            return Region(text: candidate.string, confidence: candidate.confidence,
                          x: frame.minX, y: 1 - frame.maxY,
                          width: frame.width, height: frame.height)
        }
    }
}
