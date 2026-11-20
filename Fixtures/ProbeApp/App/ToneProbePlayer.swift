import AVFoundation

/// The tone probe (docs/probe-app.md#tone-probe): launched with
/// `-ProbeTone YES`, the app plays four rising beeps over and over while it
/// is in front, so that a recording with sound has something known to hold.
/// It plays through the silent switch, and only with that argument. The
/// sound is made here, as a WAV in memory, and played by `AVAudioPlayer`:
/// a first version on `AVAudioEngine` started without an error and was not
/// heard.
@MainActor
final class ToneProbePlayer {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeTone") }
    /// The beeps, in hertz: A, C sharp, E and the A above.
    static let notes = [440.0, 554.37, 659.25, 880.0]
    static let sampleRate = 44_100
    static let beepSeconds = 0.2, gapSeconds = 0.1, restSeconds = 0.4
    static let level = 0.5

    private var player: AVAudioPlayer?

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
            print("probe.tone playing, output volume \(session.outputVolume)")
        } catch {
            print("probe.tone failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
