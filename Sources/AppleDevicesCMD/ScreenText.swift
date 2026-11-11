import Foundation
import Vision

struct ScreenText: Encodable {
    struct Region: Encodable {
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

    static func recognize(path: String) async throws -> ScreenText {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CommandFailure(description: "Image is not readable: \(path)")
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let observations = try await request.perform(on: url)
        let regions = observations.compactMap { observation -> Region? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let frame = observation.boundingBox.cgRect
            return Region(text: candidate.string, confidence: candidate.confidence,
                          x: frame.minX, y: 1 - frame.maxY,
                          width: frame.width, height: frame.height)
        }
        return ScreenText(source: url.path, regions: regions)
    }
}
