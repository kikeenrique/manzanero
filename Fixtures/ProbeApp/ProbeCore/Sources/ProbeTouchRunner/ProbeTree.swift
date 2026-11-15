import Foundation
import ProbeAnalysis
import ProbeCore

/// Reads the probe's accessibility readouts out of `manzanero physical <UDID> tree` output.
///
/// The tree is a JSON object with a `nodes` array; each node may carry `identifier` and
/// `value` scalars (Sources/Manzanero/AccessibilitySnapshot.swift). The probe puts its
/// summary, last-gesture and recent-gestures JSON in the `value` of `probe.touch.summary`,
/// `probe.touch.last-gesture` and `probe.touch.recent-gestures` (docs/probe-app.md).
///
/// A node may also carry `nativeAttributes`, string metadata copied from native attributes
/// `5003`, `5004` and `3003`. On one phone `3003` held the owning app's bundle identifier
/// (`com.apple.Preferences` for Settings); the runner reads it from the summary node as an
/// identity check, and treats its absence as "not checked".
public enum ProbeTree {
    public static let summaryIdentifier = "probe.touch.summary"
    public static let lastGestureIdentifier = "probe.touch.last-gesture"
    public static let recentGesturesIdentifier = "probe.touch.recent-gestures"
    public static let resetIdentifier = "probe.touch.reset"
    /// The native attribute key observed to hold the owning app's bundle identifier.
    public static let bundleIDAttribute = "3003"

    public struct Observation: Sendable, Equatable {
        public var readback: ProbeReadback
        /// The application PID the tree reports, for the record.
        public var pid: Int?
        /// Interface size from the summary is portrait (height above width).
        public var portrait: Bool
    }

    public static func observe(_ data: Data) throws -> Observation {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else {
            throw RunnerError("tree output is not a JSON object with a nodes array")
        }
        func values(for identifier: String) -> [Any?] {
            nodes.filter { $0["identifier"] as? String == identifier }.map { $0["value"] }
        }
        let summaryNodes = nodes.filter { $0["identifier"] as? String == summaryIdentifier }
        let summaries = summaryNodes.map { $0["value"] }
        guard !summaries.isEmpty else {
            throw RunnerError("probe.touch.summary is not in the tree: the probe app is not the foreground app at the display centre")
        }
        guard summaries.count == 1, let text = summaries[0] as? String else {
            throw RunnerError("expected exactly one probe.touch.summary with a string value, found \(summaries.count)")
        }
        let decoder = JSONDecoder()
        let summary: SummaryReadout
        do { summary = try decoder.decode(SummaryReadout.self, from: Data(text.utf8)) } catch {
            throw RunnerError("probe.touch.summary value is not a v\(probeFormatVersion) summary: \(error)")
        }
        var lastGesture: LastGestureReadout?
        if let gestureText = values(for: lastGestureIdentifier).first as? String {
            lastGesture = try? decoder.decode(LastGestureReadout.self, from: Data(gestureText.utf8))
        }
        // Exactly one element, as for the summary; otherwise the readout is not used.
        var recentGestures: RecentGesturesReadout?
        let recentValues = values(for: recentGesturesIdentifier)
        if recentValues.count == 1, let recentText = recentValues[0] as? String {
            recentGestures = try? decoder.decode(RecentGesturesReadout.self, from: Data(recentText.utf8))
        }
        let bundleID = (summaryNodes[0]["nativeAttributes"] as? [String: Any])?[bundleIDAttribute] as? String
        let pid = (root["application"] as? [String: Any])?["pid"] as? Int
        let portrait = summary.size.count == 2 && summary.size[1] > summary.size[0]
        return Observation(readback: ProbeReadback(summary: summary, lastGesture: lastGesture,
                                                   recentGestures: recentGestures, bundleID: bundleID),
                           pid: pid, portrait: portrait)
    }

    /// The foreground identity check: nil when it passes or cannot be made (attribute absent),
    /// otherwise the reason to stop.
    public static func identityProblem(_ readback: ProbeReadback, expected: String) -> String? {
        guard let observed = readback.bundleID, observed != expected else { return nil }
        return "probe.touch.summary belongs to \(observed) (nativeAttributes \(bundleIDAttribute)), not the expected \(expected): another app or another build of the probe is in the foreground"
    }

    /// The `status` of a Manzanero JSON receipt, if stdout is one.
    public static func receiptStatus(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
    }
}
