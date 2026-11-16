import AppleDeviceBridge
import Foundation
import Synchronization

/// The keystrokes `detect-layout` types and what every layout on this Mac
/// would make of them. The probe is computed from the layout tables: a short
/// greedy sequence of keys, with and without Shift, whose outputs split the
/// layouts into as many groups as possible. Option, Return, Tab, Escape,
/// space, arrows and any key that produces a control character in some
/// layout are never used, and no layout may be left with a pending dead key
/// at the end.
struct LayoutProbe: Sendable, Equatable {
    /// What one layout types for the probe.
    struct Expectation: Sendable, Equatable {
        let layout: KeyboardLayout.Source
        let text: String
    }

    /// Layouts that type the same text for the probe.
    struct Group: Sendable, Equatable {
        let text: String
        let layouts: [KeyboardLayout.Source]
    }

    static let maximumStrokes = 12
    /// Keys a probe may use: letters, digits and the punctuation keys of the
    /// main block, plus the key left of Z (100). Space (44) is left out, as it
    /// ends a word and can start autocorrection or text replacement.
    static let usages: [UInt64] = KeyboardLayout.keyCodes.map(\.usage).filter { $0 != 44 }

    let strokes: [KeyboardLayout.Stroke]
    let expectations: [Expectation]

    var groups: [Group] {
        Dictionary(grouping: expectations, by: \.text)
            .map { Group(text: $0.key, layouts: $0.value.map(\.layout).sorted { $0.name < $1.name }) }
            .sorted { ($0.layouts.count, $0.layouts[0].name) > ($1.layouts.count, $1.layouts[0].name) }
    }

    /// The probe for this Mac's installed layouts, designed once per process
    /// (about a second); the layout list is read once per process anyway.
    static func installed() throws -> Self {
        if let probe = cache.withLock({ $0 }) { return probe }
        let probe = try KeyboardLayout.withInstalledTranslators { design($0) }
        cache.withLock { $0 = probe }
        return probe
    }

    private static let cache = Mutex<LayoutProbe?>(nil)

    /// One layout's progress through a sequence: the text so far and the
    /// dead-key state; nil once a key cannot be translated.
    private struct Progress {
        var text = ""
        var dead: UInt32 = 0
    }

    private static func apply(_ stroke: KeyboardLayout.Stroke, to progress: Progress?, _ translate: KeyboardLayout.Translate) -> Progress? {
        guard var progress, let code = KeyboardLayout.keyCodes.first(where: { $0.usage == stroke.usage })?.code,
              let output = translate(code, stroke.shift ? 2 : 0, &progress.dead),
              !output.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        progress.text += output
        return progress
    }

    /// Sum of squared group sizes: the expected number of layouts left when
    /// the device's layout is drawn from these. Lower splits better.
    private static func score(_ states: [Progress?]) -> Int {
        var counts: [String: Int] = [:]
        for state in states {
            let key = state.map { "\($0.text)\u{0}\($0.dead)" } ?? "\u{1}"
            counts[key, default: 0] += 1
        }
        return counts.values.reduce(0) { $0 + $1 * $1 }
    }

    /// Greedy design. Ties prefer keys that are not letters (no autocorrection
    /// or capitalisation), then no Shift, then the lower usage, so the result
    /// is deterministic for a given set of layouts.
    static func design(_ translators: [(source: KeyboardLayout.Source, translate: KeyboardLayout.Translate)]) -> Self {
        let candidates = [false, true].flatMap { shift in usages.map { KeyboardLayout.Stroke(usage: $0, shift: shift) } }
            .sorted { rank($0) < rank($1) }
        // A key that fails or types a control character in any layout is never used.
        let usable = candidates.filter { stroke in translators.allSatisfy { apply(stroke, to: Progress(), $0.translate) != nil } }
        var states: [Progress?] = translators.map { _ in Progress() }
        var strokes: [KeyboardLayout.Stroke] = []
        func step(_ stroke: KeyboardLayout.Stroke, from states: [Progress?]) -> [Progress?] {
            zip(states, translators).map { apply(stroke, to: $0, $1.translate) }
        }
        var current = score(states)
        while strokes.count < maximumStrokes - 1 {
            var best: (stroke: KeyboardLayout.Stroke, states: [Progress?], score: Int)?
            for stroke in usable {
                let next = step(stroke, from: states)
                let value = score(next)
                if value < (best?.score ?? current) { best = (stroke, next, value) }
            }
            guard let best else { break }
            strokes.append(best.stroke); states = best.states; current = best.score
        }
        // Resolve any pending dead key with the key that splits best among
        // those leaving every layout without one; if none can, drop the last key.
        while states.contains(where: { ($0?.dead ?? 0) != 0 }) {
            var best: (stroke: KeyboardLayout.Stroke, states: [Progress?], score: Int)?
            for stroke in usable {
                let next = step(stroke, from: states)
                guard next.allSatisfy({ ($0?.dead ?? 0) == 0 }) else { continue }
                let value = score(next)
                if value < (best?.score ?? Int.max) { best = (stroke, next, value) }
            }
            if let best {
                strokes.append(best.stroke); states = best.states
            } else {
                strokes.removeLast()
                states = strokes.reduce(translators.map { _ in Progress() }) { step($1, from: $0) }
            }
        }
        let expectations = zip(translators, states).compactMap { entry, state in
            state.map { Expectation(layout: entry.source, text: $0.text) }
        }
        return Self(strokes: strokes, expectations: expectations)
    }

    private static func rank(_ stroke: KeyboardLayout.Stroke) -> (Int, Int, UInt64) {
        ((4...29).contains(stroke.usage) ? 1 : 0, stroke.shift ? 1 : 0, stroke.usage)
    }

    /// The layouts whose expected text equals what arrived (Unicode canonical equivalence).
    func matches(_ typed: String) -> [KeyboardLayout.Source] {
        expectations.filter { $0.text == typed }.map(\.layout).sorted { $0.name < $1.name }
    }

    /// Layouts that match only after undoing one kind of transformation a
    /// field can apply, with its name. Reported as a hint, never as the result.
    func transformedMatches(_ typed: String) -> [(transformation: String, layouts: [String])] {
        let folds: [(String, (String) -> String)] = [
            ("letter case (auto-capitalisation or Caps Lock)", { $0.lowercased() }),
            ("smart quotes or dashes", { text in
                String(text.map { character -> Character in
                    switch character {
                    case "\u{201C}", "\u{201D}", "\u{201E}": "\""
                    case "\u{2018}", "\u{2019}", "\u{201A}": "'"
                    case "\u{2013}", "\u{2014}": "-"
                    default: character
                    }
                })
            }),
        ]
        return folds.compactMap { name, fold in
            let layouts = expectations.filter { fold($0.text) == fold(typed) }.map(\.layout.name).sorted()
            return layouts.isEmpty ? nil : (name, layouts)
        }
    }

    /// The strokes as plain data for plans and receipts: HID usage and Shift.
    var strokeDescriptions: [[String: Any]] {
        strokes.map { ["usage": $0.usage, "shift": $0.shift] }
    }
}

/// `detect-layout`: which hardware-keyboard layout a device applies, found by
/// typing the probe into a named settable text field and reading it back.
struct LayoutDetectionCommand: Sendable, Equatable {
    let platform: Target.Platform
    let device: String
    /// `identifier` or `label`.
    let by: String
    let text: String
    let pid: Int32?
    /// The value set before typing, so the probe never starts a sentence and
    /// the typed part can be cut from what is read back.
    static let prefix = "x"

    init(_ target: Target, selector: SelectorOptions) throws {
        guard !target.identifier.isEmpty, !target.identifier.hasPrefix("-") else {
            throw CommandFailure.usage("Provide a valid device identifier.")
        }
        let text = selector.id ?? selector.label ?? ""
        guard (1...4096).contains(text.utf8.count), !text.contains("\0") else {
            throw CommandFailure.usage("detect-layout requires an exact selector of 1...4096 UTF-8 bytes without NUL.")
        }
        var pid: Int32?
        if let value = selector.pid {
            guard let number = Int32(value), number > 0 else { throw CommandFailure.usage("Native AX selector PID must be positive.") }
            pid = number
        }
        if target.platform == .simulator, UUID(uuidString: target.identifier) == nil {
            throw CommandFailure.usage("Simulator layout detection requires an explicit simulator UUID.")
        }
        self.platform = target.platform
        self.device = target.identifier
        self.by = selector.id != nil ? "identifier" : "label"
        self.text = text
        self.pid = pid
    }

    var target: Target { Target(platform: platform, identifier: device) }
    /// `[pid] <selector>`, the operands the selector operations take.
    var selectorOperands: [String] { (pid.map { [String($0)] } ?? []) + [text] }
    var setValueOperation: String { by == "identifier" ? "set-value-id" : "set-value-label" }

    func plan(_ probe: LayoutProbe) -> [String: Any] {
        let groups = probe.groups
        return ["operation": "detect-layout", "platform": platform.rawValue, "device": device,
                "selector": ["by": by, "text": text], "pid": pid.map { $0 as Any } ?? NSNull(),
                "probe": ["strokes": probe.strokeDescriptions, "keyCount": probe.strokes.count,
                          "layouts": probe.expectations.count, "distinguishableGroups": groups.count,
                          "largestGroup": groups.first.map { $0.layouts.map(\.name) } ?? []] as [String: Any],
                "steps": ["Read the field's value through accessibility (tree).",
                          "set-value the field to '\(Self.prefix)' (the press guards and the settable check apply; focuses it, caret at the end).",
                          "Type the probe's \(probe.strokes.count) keys as HID keyboard events (no Option, Return, Tab, space or arrows).",
                          "Read the field back; the text after '\(Self.prefix)' is compared with what each of \(probe.expectations.count) macOS layouts types.",
                          "Delete what is in the field with that many backspaces and read it again: back to the first value means it was empty; otherwise set-value the first value back and read it once more."],
                "settingsChanged": false, "readOnly": false]
    }
}

/// The detection itself, over injected device operations, so tests can run
/// it without a device. Each closure is one existing operation: a tree read,
/// a guarded set-value and a keyboard schedule at the current focus.
struct LayoutDetection {
    struct Operations: Sendable {
        /// The field's current accessibility value ("" when it has none).
        var read: @Sendable () async throws -> String
        /// Guarded set-value; true when the value read back matched.
        var set: @Sendable (String) async throws -> Bool
        /// Sends keyboard samples at the current focus.
        var keys: @Sendable (KeySchedule) async throws -> Void
        /// The simulator's own setting, when there is one to compare with.
        var deviceSetting: @Sendable () -> [String: Any]? = { nil }
    }

    /// How the field was put back.
    struct Restore: Sendable, Equatable {
        /// unchanged, cleared-to-original, set-value, not-cleared, cleared or failed.
        let status: String
        let confirmed: Bool
        var backspaces: Int? = nil
        var detail: String? = nil

        var fields: [String: Any] {
            var value: [String: Any] = ["status": status, "confirmed": confirmed]
            if let backspaces { value["backspaces"] = backspaces }
            if let detail { value["detail"] = detail }
            return value
        }
    }

    static let backspaceUsage: UInt64 = 42

    /// The value of the one node a tree holds for the selector: "" when it
    /// has no string value. None, or several, is refused before any input.
    static func fieldValue(fromTree data: Data, by: String, text: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else {
            throw CommandFailure(.transportFailed, "The accessibility tree has no node list; no input sent.", inputSent: .none)
        }
        let key = by == "identifier" ? "identifier" : "label"
        let found = nodes.filter { $0[key] as? String == text }
        guard found.count == 1, let node = found.first else {
            throw CommandFailure(.targetUnresolved, "The tree has \(found.count) elements with \(key) '\(text)'; detect-layout needs exactly one. No input sent.", inputSent: .none)
        }
        return node["value"] as? String ?? ""
    }

    /// A keyboard schedule, kept opaque to callers that only pass it on.
    struct KeySchedule: Sendable {
        let samples: [ADCKeyboardSample]
        /// Key-down usages in order, for tests and receipts.
        var usages: [UInt64] { samples.filter { $0.state == 1 }.map(\.usage) }
    }

    /// Where the keys go: a physical device's Indigo keyboard or a simulator's dtuhidd.
    enum Keyboard: Sendable {
        case physical(uuid: String, version: String)
        case simulator(String)
    }

    /// Sends a schedule; blocking, so callers run it off the cooperative pool.
    static func send(_ schedule: KeySchedule, to keyboard: Keyboard, simulator: SimulatorEnvironment) throws {
        try Task.checkCancellation()
        switch keyboard {
        case .physical(let uuid, let version):
            try DirectPhysicalKeyboard.dispatchSequence(.init(uuid: uuid, version: version, samples: schedule.samples))
        case .simulator(let uuid):
            try simulator.keyboard(uuid, schedule.samples)
        }
    }

    static func backspaces(_ count: Int) -> KeySchedule {
        KeySchedule(samples: (0..<count).flatMap { index in
            [ADCKeyboardSample(nanoseconds: UInt64(index * 2) * 10_000_000, usage: backspaceUsage, state: 1),
             ADCKeyboardSample(nanoseconds: UInt64(index * 2 + 1) * 10_000_000, usage: backspaceUsage, state: 2)]
        })
    }

    /// Runs the detection and returns the receipt. Restores the field whatever
    /// happens after the first input, and reports whether that was confirmed.
    static func run(_ command: LayoutDetectionCommand, probe: LayoutProbe, operations: Operations) async throws -> [String: Any] {
        guard !probe.strokes.isEmpty, !probe.expectations.isEmpty else {
            throw CommandFailure(.hostRequirement, "This Mac's keyboard layouts gave no usable probe; no input sent.", inputSent: .none)
        }
        let original = try await operations.read()
        var result: [String: Any] = ["operation": "detect-layout", "platform": command.platform.rawValue, "device": command.device,
                                     "selector": ["by": command.by, "text": command.text], "settingsChanged": false,
                                     "probe": ["strokes": probe.strokeDescriptions, "layoutsCompared": probe.expectations.count,
                                               "distinguishableGroups": probe.groups.count] as [String: Any]]
        var arrived: String?
        var failure: (any Error)?
        do {
            guard try await operations.set(LayoutDetectionCommand.prefix) else {
                throw CommandFailure(.preconditionChanged, "The field did not keep the value '\(LayoutDetectionCommand.prefix)' set through accessibility, so what it shows after typing cannot be compared. Use a plain text field without formatting (the probe app's probe.text.field is the reference).", inputSent: .possible)
            }
            try await operations.keys(KeySchedule(samples: KeyboardLayout.samples(probe.strokes)))
            arrived = try await operations.read()
        } catch {
            failure = error
        }
        // Restore before reporting, whatever happened after the first input.
        // A cancelled caller still gets its field back: the restore runs in a
        // task of its own, which the cancellation does not reach.
        let current = arrived
        let restore = await Task { await restoreField(original: original, current: current, operations: operations) }.value
        result["restore"] = restore.fields
        if let failure {
            if failure is CancellationError || Task.isCancelled {
                FileHandle.standardError.write(Data("Layout detection cancelled; field restore: \(restore.status), confirmed=\(restore.confirmed).\n".utf8))
                throw CancellationError()
            }
            let base = failure as? CommandFailure ?? CommandFailure("\(failure)", wrapping: failure)
            throw CommandFailure(base.code, "\(base.description) Field restore: \(restore.status), confirmed=\(restore.confirmed).",
                                 inputSent: base.inputSent)
        }
        let field = arrived ?? ""
        let typed: String
        if field.hasPrefix(LayoutDetectionCommand.prefix) {
            typed = String(field.dropFirst(LayoutDetectionCommand.prefix.count))
        } else {
            typed = field
            result["prefixMissing"] = true
        }
        result["arrived"] = typed
        let matches = probe.matches(typed)
        switch matches.count {
        case 0:
            result["status"] = "no-match"
            var notes = ["No layout on this Mac types this text for the probe. Autocorrection, auto-capitalisation, smart punctuation, an input method or a field that filters input can change what arrives; use a plain field with those off (the probe app's probe.text.field is the reference)."]
            let hints = probe.transformedMatches(typed)
            if !hints.isEmpty {
                result["matchesAfterUndoing"] = hints.map { ["transformation": $0.transformation, "layouts": $0.layouts] as [String: Any] }
                notes.append("Some layouts match once a field transformation is undone (matchesAfterUndoing); this is a hint, not a result. Repeat in a field without that behaviour.")
            }
            if result["prefixMissing"] != nil { notes.append("The field did not start with '\(LayoutDetectionCommand.prefix)' after typing: the caret was not at the end, or the field rewrote its text.") }
            result["notes"] = notes
        case 1:
            result["status"] = "detected"
            result["layoutOption"] = "--layout \(matches[0].name)"
        default:
            result["status"] = "ambiguous"
            result["notes"] = ["These layouts type the same text for this probe; they may still differ on other keys. Any of them types the probe's characters correctly; pick the one the device is known to use, or test typing a text that differs among them."]
        }
        result["layouts"] = matches.map { ["name": $0.name, "identifier": $0.identifier, "localizedName": $0.localizedName] }
        if let setting = operations.deviceSetting() {
            var compared = setting
            if let name = setting["deviceLayout"] as? String {
                compared["agrees"] = matches.contains { $0.name == name }
            }
            result["deviceSetting"] = compared
        }
        return result
    }

    /// Deletes what the field holds, then compares with the value read first:
    /// equal means the field was empty (an empty field reads as its
    /// placeholder) and is restored. Otherwise the first value is set back.
    static func restoreField(original: String, current: String?, operations: Operations) async -> Restore {
        do {
            let present: String
            if let current { present = current } else { present = try await operations.read() }
            if present == original { return Restore(status: "unchanged", confirmed: true) }
            if !present.isEmpty {
                try await operations.keys(backspaces(present.count))
            }
            let cleared = try await operations.read()
            if cleared == original {
                return Restore(status: "cleared-to-original", confirmed: true, backspaces: present.count)
            }
            // Text the backspaces left behind means they did not all arrive;
            // setting the first value then could write a placeholder as text.
            if !cleared.isEmpty, present.hasPrefix(cleared) || cleared.hasPrefix(LayoutDetectionCommand.prefix) {
                return Restore(status: "not-cleared", confirmed: false, backspaces: present.count,
                               detail: "The field still holds \(cleared.utf8.count) bytes of what was there; restore it by hand (set-value or key backspace).")
            }
            guard !original.isEmpty else {
                return Restore(status: "cleared", confirmed: false, backspaces: present.count,
                               detail: "The field was emptied but reads differently from before; the first value was empty, so nothing was set back.")
            }
            let matched = try await operations.set(original)
            return Restore(status: "set-value", confirmed: matched, backspaces: present.count)
        } catch {
            return Restore(status: "failed", confirmed: false, detail: String(String(describing: error).prefix(2000)))
        }
    }
}
