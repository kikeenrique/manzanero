import os
import SwiftUI

/// The tvOS probe: reports which Siri Remote command the app received, so
/// Manzanero's `remote` can be checked without opening anyone's own apps
/// (docs/probe-app.md#tvos-probe). Separate from the iOS probe; it shares
/// no state with it.
@main
struct ProbeTVApp: App {
    var body: some Scene {
        WindowGroup {
            // `-ProbeVideo YES`: Apple's player on a silent movie of the
            // probe's own (ProbeTVVideo.swift).
            if UserDefaults.standard.bool(forKey: "ProbeVideo") { ProbeTVVideoView() } else { ProbeTVView() }
        }
    }
}

/// What the app received, in the order it arrived.
@MainActor
@Observable
final class RemoteRecord {
    private(set) var count = 0
    private(set) var last = "none"
    private(set) var counts: [String: Int] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe.tv", category: "remote")

    static let kinds = ["up", "down", "left", "right", "select", "select-long", "menu", "play-pause"]

    func note(_ kind: String, detail: String? = nil) {
        count += 1
        counts[kind, default: 0] += 1
        last = detail.map { "\(kind):\($0)" } ?? kind
        logger.info("remote \(self.count, privacy: .public) \(self.last, privacy: .public)")
    }

    /// The URLs the app was opened with (scheme `manzanero-probe-tv`): `none`,
    /// or the count and the last one. Kept apart from the remote's counts.
    private(set) var url = "none"
    private var urls = 0

    func noteURL(_ opened: URL) {
        urls += 1
        url = "\(urls) \(opened.absoluteString)"
        logger.info("url \(self.url, privacy: .public)")
    }

    /// `up=1 down=0 …`, one entry per kind in a fixed order.
    var summary: String {
        Self.kinds.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
    }
}

struct ProbeTVView: View {
    @State private var record = RemoteRecord()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 60) {
                controls
                // Forty rows, more than fit: something off screen to scroll to.
                List(1...40, id: \.self) { row in
                    Button("Row \(row)") { record.note("select", detail: "row-\(row)") }
                        .accessibilityIdentifier("probe.tv.row.\(row)")
                }
                .frame(width: 500)
            }
            // Thirty columns in a strip that moves sideways.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 30) {
                    ForEach(1...30, id: \.self) { column in
                        Button("Col \(column)") { record.note("select", detail: "col-\(column)") }
                            .accessibilityIdentifier("probe.tv.col.\(column)")
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(height: 110)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: record.note("up")
            case .down: record.note("down")
            case .left: record.note("left")
            case .right: record.note("right")
            @unknown default: record.note("move-unknown")
            }
        }
        // Menu is recorded and kept: leave the probe with the Home button.
        .onExitCommand { record.note("menu") }
        .onPlayPauseCommand { record.note("play-pause") }
        .onOpenURL { record.noteURL($0) }
    }

    private var controls: some View {
        VStack(spacing: 24) {
            Text("Probe TV").font(.title3)
            HStack(spacing: 40) {
                ForEach(["a", "b", "c"], id: \.self) { name in
                    Button("Button \(name.uppercased())") { record.note("select", detail: name) }
                        .accessibilityIdentifier("probe.tv.button.\(name)")
                }
            }
            // Two buttons that share one label, to choose between by position.
            HStack(spacing: 40) {
                ForEach([1, 2], id: \.self) { twin in
                    Button("Twin") { record.note("select", detail: "twin-\(twin)") }
                        .accessibilityIdentifier("probe.tv.twin.\(twin)")
                }
            }
            // A long press of select, which a button's own action does not report.
            Text("Hold")
                .padding(20)
                .focusable()
                .onLongPressGesture(minimumDuration: 1) { record.note("select-long") }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("probe.tv.hold")
            TextField("Text", text: $text)
                .accessibilityIdentifier("probe.tv.text.field")
                .frame(width: 800)
            readout("probe.tv.text.value", "Text", text)
            readout("probe.tv.last", "Last", record.last)
            readout("probe.tv.count", "Count", String(record.count))
            readout("probe.tv.summary", "Summary", record.summary)
            readout("probe.tv.url", "URL", record.url)
        }
    }

    /// One labelled line whose accessibility value is the reading.
    private func readout(_ identifier: String, _ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}
