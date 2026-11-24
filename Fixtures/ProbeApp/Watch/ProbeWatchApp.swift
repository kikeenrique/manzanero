import os
import SwiftUI

/// The watchOS probe (docs/probe-app.md#watchos-probe): what reached the app,
/// so Manzanero's watch commands (touch, `crown`, `type` by the on-screen
/// keyboard, `scroll --search`) can be checked on a watch without opening
/// any of the wearer's apps. It shows nothing but its own controls.
@main
struct ProbeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            if ProbeCrownListView.isRequested {
                ProbeCrownListView()
            } else {
                ProbeWatchView()
            }
        }
    }
}

/// `-ProbeCrownList YES`: forty rows and nothing bound to the crown, so the
/// crown scrolls the list as it scrolls any app's. Which rows moved is read
/// from the rows' frames in the tree (docs/probe-app.md#watchos-probe).
struct ProbeCrownListView: View {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeCrownList") }

    var body: some View {
        List {
            ForEach(1...40, id: \.self) { row in
                Text("Row \(row)")
                    .accessibilityIdentifier("probe.watch.crownlist.row.\(row)")
            }
        }
        .navigationTitle("Crown list")
    }
}

/// What the app received, in order; each event also goes to the unified log,
/// category `watch`.
@MainActor
@Observable
final class WatchRecord {
    private(set) var count = 0
    private(set) var last = "none"
    private(set) var touch = "none"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "probe.watch", category: "watch")

    func note(_ event: String) {
        count += 1
        last = event
        logger.info("watch \(self.count, privacy: .public) \(event, privacy: .public)")
    }

    /// A tap on the touch pad, as fractions of the pad's size.
    func noteTouch(_ location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        touch = String(format: "%.3f,%.3f", location.x / size.width, location.y / size.height)
        note("touch:\(touch)")
    }
}

struct ProbeWatchView: View {
    @State private var record = WatchRecord()
    @State private var text = ""
    /// The Digital Crown's value, low sensitivity: 200 of `crown`'s units
    /// make 1.0 (docs/other-families.md). The list itself does not scroll
    /// with the crown on a watchOS 27.2 simulator, so the crown is read here.
    @State private var crown = 0.0
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                readout("probe.watch.last", "Last", record.last)
                readout("probe.watch.count", "Count", String(record.count))
                readout("probe.watch.crown", "Crown", String(format: "%.3f", crown))
                HStack {
                    Button("A") { record.note("button:a") }
                        .accessibilityIdentifier("probe.watch.button.a")
                    Button("B") { record.note("button:b") }
                        .accessibilityIdentifier("probe.watch.button.b")
                }
                // No insets: the square fills its row, whose whole cell is
                // what the tree reports as the pad's frame.
                touchPad
                    .listRowInsets(EdgeInsets())
                readout("probe.watch.touch", "Touch", record.touch)
                TextField("Text", text: $text)
                    .accessibilityIdentifier("probe.watch.text.field")
                readout("probe.watch.text.value", "Text", text)
            }
            // Thirty rows, more than fit: something for the crown and for
            // `scroll --search` to reach.
            Section {
                ForEach(1...30, id: \.self) { row in
                    Button("Row \(row)") { record.note("row:\(row)") }
                        .accessibilityIdentifier("probe.watch.row.\(row)")
                }
            }
        }
        .navigationTitle("Probe")
        .focusable()
        .focused($focused)
        .digitalCrownRotation($crown, from: -100_000, through: 100_000, by: nil, sensitivity: .low,
                              isContinuous: true, isHapticFeedbackEnabled: false)
        .onAppear { focused = true }
    }

    /// A square that reports where a tap landed in it.
    private var touchPad: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.gray.opacity(0.35))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    record.noteTouch(location, in: geometry.size)
                }
                // The tree reports a list row's whole cell as the element's
                // frame; with the row's insets removed (above) that cell is
                // the square, which the readings are fractions of.
                .accessibilityElement()
                .accessibilityLabel("Touch pad")
                .accessibilityIdentifier("probe.watch.pad")
        }
        .frame(height: 80)
    }

    /// One labelled line whose accessibility value is the reading.
    private func readout(_ identifier: String, _ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .font(.footnote)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}
