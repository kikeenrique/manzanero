import Foundation
import ProbeAnalysis
import ProbeCore

/// Reads the probe's accessibility readouts out of `manzanero physical <UDID> tree` output.
///
/// The tree is a JSON object with a `nodes` array; each node may carry `identifier` and
/// `value` scalars (Sources/Manzanero/AccessibilitySnapshot.swift). The probe puts its
/// summary and last-gesture JSON in the `value` of `probe.touch.summary` and
/// `probe.touch.last-gesture` (docs/probe-app.md).
public enum ProbeTree {
    public static let summaryIdentifier = "probe.touch.summary"
    public static let lastGestureIdentifier = "probe.touch.last-gesture"
    public static let resetIdentifier = "probe.touch.reset"

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
        let summaries = values(for: summaryIdentifier)
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
        let pid = (root["application"] as? [String: Any])?["pid"] as? Int
        let portrait = summary.size.count == 2 && summary.size[1] > summary.size[0]
        return Observation(readback: ProbeReadback(summary: summary, lastGesture: lastGesture), pid: pid, portrait: portrait)
    }

    /// The `status` of a Manzanero JSON receipt, if stdout is one.
    public static func receiptStatus(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
    }
}
