import AVFoundation
import AVKit
import CoreText
import os
import SwiftUI

/// `-ProbeVideo YES`: Apple's own player (`AVPlayerViewController`) playing
/// a movie the probe makes for itself, so seeking, the player's tree and a
/// capture of a player can be measured without anyone's streaming app
/// (docs/probe-app.md#a-silent-video). The movie has no sound track: the
/// room the Apple TV is in stays quiet. Each frame shows its own time in
/// large figures, so a screenshot reads the position, and the position is
/// also logged (category `video`) and kept as an accessibility value
/// (`probe.tv.video.time`).
enum ProbeTVVideo {
    static let seconds = 600
    static let framesPerSecond: Int32 = 4
    static let size = CGSize(width: 1280, height: 720)
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe.tv", category: "video")

    /// The movie, made once into Caches; later launches reuse it.
    static func movie() async throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = caches.appendingPathComponent("probe-video-v1-\(seconds)s.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = caches.appendingPathComponent("probe-video-partial.mov")
        try? FileManager.default.removeItem(at: partial)
        try await Task.detached(priority: .userInitiated) { try write(to: partial) }.value
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    private static func write(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(framesPerSecond)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            draw(frame: frame, into: buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A grey frame, never black, with the time as `mm:ss.f` and a bar.
    private static func draw(frame: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(red: 0.18, green: 0.2, blue: 0.24, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let seconds = Double(frame) / Double(framesPerSecond)
        let share = seconds / Double(Self.seconds)
        context.setFillColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 80, y: 120, width: (size.width - 160) * share, height: 24))
        let text = String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 200, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (size.width - width) / 2, y: 300)
        CTLineDraw(line, context)
    }
}

/// The position, kept for the readout and the log.
@MainActor
@Observable
final class VideoPosition {
    private(set) var reading = "loading"

    func note(_ time: CMTime, rate: Float) {
        let seconds = time.isNumeric ? time.seconds : 0
        reading = String(format: "%.1f rate %.2f", seconds, rate)
        ProbeTVVideo.logger.info("video \(self.reading, privacy: .public)")
    }

    func fail(_ error: any Error) {
        reading = "failed"
        ProbeTVVideo.logger.error("video failed \(String(describing: error), privacy: .public)")
    }
}

struct ProbeTVVideoView: View {
    @State private var player: AVPlayer?
    @State private var position = VideoPosition()

    var body: some View {
        ZStack {
            if let player {
                PlayerController(player: player, position: position)
                    .ignoresSafeArea()
            } else {
                Text("Making the probe's video…")
            }
        }
        .task {
            do {
                let player = AVPlayer(url: try await ProbeTVVideo.movie())
                // No sound track, and muted besides: the room stays quiet.
                player.isMuted = true
                self.player = player
                player.play()
            } catch {
                position.fail(error)
            }
        }
    }
}

/// Apple's player, with the position as a label in its content overlay,
/// which carries the accessibility value `probe.tv.video.time`.
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let position: VideoPosition

    @MainActor
    final class Coordinator {
        var observer: Any?
        weak var label: UILabel?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        let label = UILabel()
        label.text = "Video"
        label.textColor = .clear
        label.isAccessibilityElement = true
        label.accessibilityLabel = "Video time"
        label.accessibilityIdentifier = "probe.tv.video.time"
        label.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        controller.contentOverlayView?.addSubview(label)
        context.coordinator.label = label
        let coordinator = context.coordinator
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak player] time in
            MainActor.assumeIsolated {
                position.note(time, rate: player?.rate ?? 0)
                coordinator.label?.accessibilityValue = position.reading
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        if let observer = coordinator.observer { controller.player?.removeTimeObserver(observer) }
    }
}
