import AVFoundation
import os
import SwiftUI

/// The tvOS probe's tone (docs/probe-app.md#a-tone): launched with
/// `-ProbeTone YES`, it plays four rising beeps over and over while it is in
/// front, a sound with no DRM, so that a recording with sound on an Apple TV
/// has something known to hold. The same beeps as the iOS probe's tone, made
/// as a WAV in memory and played by `AVAudioPlayer`. The whole screen is
/// white while the first beep of each round sounds, so that a recording's
/// picture and sound can be lined up. Only with that argument: without it the
/// probe makes no sound, and the room an Apple TV is in stays quiet.
enum ProbeTVTone {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeTone") }
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe.tv", category: "tone")
    /// The beeps, in hertz: A, C sharp, E and the A above.
    static let notes = [440.0, 554.37, 659.25, 880.0]
    static let sampleRate = 44_100
    static let beepSeconds = 0.2, gapSeconds = 0.1, restSeconds = 0.4
    static let level = 0.5

    /// One round: the four beeps with their gaps, then the rest.
    static var roundSeconds: Double { Double(notes.count) * (beepSeconds + gapSeconds) + restSeconds }

    /// Whether the first beep is audible at `position` seconds of playback,
    /// with the output's latency taken off.
    static func firstBeepSounds(at position: Double, outputLatency: Double) -> Bool {
        let heard = position - outputLatency
        let phase = heard - (heard / roundSeconds).rounded(.down) * roundSeconds
        return phase >= 0 && phase < beepSeconds
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
}

/// The player, started and stopped with the app's presence in front.
@MainActor
@Observable
final class ProbeTVTonePlayer {
    private(set) var state = "stopped"
    private var player: AVAudioPlayer?

    /// The position within the current round: a looping player starts
    /// again from 0 every 1.6 s.
    var position: Double { player?.currentTime ?? 0 }
    var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency }
    var isPlaying: Bool { player?.isPlaying == true }

    func start() {
        guard ProbeTVTone.isRequested, player?.isPlaying != true else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: ProbeTVTone.wave())
            player.numberOfLoops = -1
            guard player.play() else { throw NSError(domain: "probe.tv.tone", code: 1) }
            self.player = player
            state = "playing"
            ProbeTVTone.logger.info("probe.tv.tone playing, output latency \(session.outputLatency, privacy: .public)")
        } catch {
            state = "failed"
            ProbeTVTone.logger.error("probe.tv.tone failed \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if state == "playing" { state = "stopped" }
        try? AVAudioSession.sharedInstance().setActive(false)
        ProbeTVTone.logger.info("probe.tv.tone stopped")
    }
}

struct ProbeTVToneView: View {
    @State private var tone = ProbeTVTonePlayer()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.animation) { _ in
            let flash = tone.isPlaying && ProbeTVTone.firstBeepSounds(at: tone.position, outputLatency: tone.outputLatency)
            ZStack {
                (flash ? Color.white : Color(white: 0.25)).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Probe TV tone").font(.title3)
                    Text("Tone: \(tone.state)")
                        .accessibilityElement()
                        .accessibilityLabel("Tone")
                        .accessibilityValue(tone.state)
                        .accessibilityIdentifier("probe.tv.tone")
                    Text("Position: \(String(format: "%.1f", tone.position))")
                        .accessibilityElement()
                        .accessibilityLabel("Tone position")
                        .accessibilityValue(String(format: "%.1f", tone.position))
                        .accessibilityIdentifier("probe.tv.tone.position")
                }
                .foregroundStyle(flash ? .black : .white)
                .padding(40)
            }
        }
        .onAppear { tone.start() }
        .onDisappear { tone.stop() }
        .onChange(of: phase) { _, now in
            if now == .active { tone.start() } else { tone.stop() }
        }
    }
}
