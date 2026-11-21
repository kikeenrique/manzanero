import AVFoundation
import UIKit

/// The tone probe (docs/probe-app.md#tone-probe): launched with
/// `-ProbeTone YES`, the app plays four rising beeps over and over while it
/// is in front, so that a recording with sound has something known to hold.
/// It plays through the silent switch, and only with that argument. The
/// sound is made here, as a WAV in memory, and played by `AVAudioPlayer`:
/// a first version on `AVAudioEngine` started without an error and was not
/// heard. While the first beep of each round sounds, the whole screen is
/// white, so that a recording's picture and sound can be lined up.
@MainActor
final class ToneProbePlayer: NSObject {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeTone") }
    /// The beeps, in hertz: A, C sharp, E and the A above.
    static let notes = [440.0, 554.37, 659.25, 880.0]
    static let sampleRate = 44_100
    static let beepSeconds = 0.2, gapSeconds = 0.1, restSeconds = 0.4
    static let level = 0.5

    /// One round: the four beeps with their gaps, then the rest.
    static var roundSeconds: Double { Double(notes.count) * (beepSeconds + gapSeconds) + restSeconds }

    private var player: AVAudioPlayer?
    /// White over the whole window during the first beep of each round;
    /// not touchable and not in the accessibility tree.
    private let flash: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()
    private var displayLink: CADisplayLink?

    /// Puts the flash over the window; it shows only while the tone plays.
    func attach(to window: UIWindow) {
        guard Self.isRequested else { return }
        flash.frame = window.bounds
        window.addSubview(flash)
    }

    /// Whether the first beep is audible at `position` seconds of playback,
    /// with the output's latency taken off: what the player has reached is
    /// heard that much later.
    static func firstBeepSounds(at position: Double, outputLatency: Double) -> Bool {
        let heard = position - outputLatency
        let phase = heard - (heard / roundSeconds).rounded(.down) * roundSeconds
        return phase >= 0 && phase < beepSeconds
    }

    @objc private func tick() {
        guard let player else { flash.alpha = 0; return }
        flash.superview?.bringSubviewToFront(flash)
        flash.alpha = Self.firstBeepSounds(at: player.currentTime, outputLatency: AVAudioSession.sharedInstance().outputLatency) ? 1 : 0
    }

    /// One round of the beeps as a 16-bit mono WAV file.
    static func wave() -> Data {
        var samples: [Int16] = []
        func silence(_ seconds: Double) { samples += [Int16](repeating: 0, count: Int(seconds * Double(sampleRate))) }
        for note in notes {
            let count = Int(beepSeconds * Double(sampleRate))
            for index in 0..<count {
                // A short fade at each end, so a beep does not click.
                let edge = min(1, Double(min(index, count - index)) / 400)
                samples.append(Int16(sin(2 * Double.pi * note * Double(index) / Double(sampleRate)) * level * edge * Double(Int16.max)))
            }
            silence(gapSeconds)
        }
        silence(restSeconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16)); data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }

    func start() {
        guard Self.isRequested, player?.isPlaying != true else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.wave())
            player.numberOfLoops = -1
            guard player.play() else { throw NSError(domain: "probe.tone", code: 1) }
            self.player = player
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            print("probe.tone playing, output volume \(session.outputVolume), output latency \(session.outputLatency)")
        } catch {
            print("probe.tone failed: \(error)")
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        flash.alpha = 0
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
