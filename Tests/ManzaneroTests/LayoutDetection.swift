import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

struct LayoutDetectionTests {
    static let device = CLIParserTests.device
    static let simulator = CLIParserTests.simulator

    // MARK: Request

    @Test func requestValidatesTheSelectorAndTarget() throws {
        let parsed = try request(["detect-layout", "--label", "Field", "--pid", "7", "--simulator", Self.simulator])
        #expect(summary(parsed) == ["simulator", Self.simulator, "detect-layout", "--label", "Field", "--pid", "7"])
        #expect(parsed.signalContext == "layout detection" && parsed.addressed?.operation == "detect-layout")
        #expect(!parsed.isReadOnly && !CommandService.observationOperations.contains("detect-layout"))
        guard case .detectLayout(let detection) = parsed else { Issue.record("not detect-layout"); return }
        #expect(detection.setValueOperation == "set-value-label" && detection.selectorOperands == ["7", "Field"])
        for bad in [["detect-layout", "--device", Self.device], ["detect-layout", "--id", "a", "--label", "b", "--device", Self.device],
                    ["detect-layout", "--id", "a", "--pid", "-2", "--device", Self.device], ["detect-layout", "--id", "a", "--simulator", "phone"]] {
            let failure = try #require(throws: CommandFailure.self) { try request(bad) }
            #expect(failure.code == .usage && failure.inputSent == .none, "\(bad)")
        }
    }

    @Test func mcpToolDefaultsToPhysicalAndParsesLikeTheCLI() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "detect_keyboard_layout" })
        #expect(!tool.readOnly)
        let physical = try tool.command(["device": "phone", "by": "identifier", "text": "probe.text.field"])
        #expect(physical == ["detect-layout", "--device=phone", "--id=probe.text.field"])
        let simulated = try tool.command(["device": .string(Self.simulator), "platform": "simulator", "by": "label", "text": "--odd", "pid": 4])
        #expect(summary(try request(simulated)) == ["simulator", Self.simulator, "detect-layout", "--label", "--odd", "--pid", "4"])
    }

    @Test func dryRunPlansTheProbeWithoutContactingTheDevice() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let output = try await service.run(["detect-layout", "--id", "probe.text.field", "--device", Self.device], dryRun: true)
        let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(plan["operation"] as? String == "detect-layout" && plan["settingsChanged"] as? Bool == false)
        let probe = try #require(plan["probe"] as? [String: Any])
        #expect((probe["keyCount"] as? Int ?? 0) > 0)
    }

    // MARK: Probe design

    /// A fake layout: each usage types the given text (shifted: uppercased);
    /// a usage listed in `dead` types nothing and composes with the next key.
    static func layout(_ name: String, _ keys: [UInt64: String], dead: Set<UInt64> = [], control: Set<UInt64> = [])
        -> (source: KeyboardLayout.Source, translate: KeyboardLayout.Translate) {
        let source = KeyboardLayout.Source(name: name, identifier: KeyboardLayout.identifierPrefix + name, localizedName: name)
        return (source, { code, modifiers, state in
            guard let usage = KeyboardLayout.keyCodes.first(where: { $0.code == code })?.usage else { return nil }
            if control.contains(usage) { return "\u{1B}" }
            if dead.contains(usage), state == 0 { state = 1; return "" }
            let base = keys[usage] ?? "k\(usage)"
            let text = modifiers & 2 != 0 ? base.uppercased() : base
            if state != 0 { state = 0; return "´" + text }
            return text
        })
    }

    @Test func designSplitsLayoutsAndEndsWithoutAPendingDeadKey() throws {
        let us = Self.layout("us", [:])
        let swapped = Self.layout("swapped", [29: "y", 28: "z"])
        let accent = Self.layout("accent", [:], dead: [52])
        let twin = Self.layout("twin", [:])
        let probe = LayoutProbe.design([us, swapped, accent, twin])
        #expect(!probe.strokes.isEmpty && probe.strokes.count <= LayoutProbe.maximumStrokes)
        #expect(probe.strokes.allSatisfy { !$0.option && $0.usage != 44 && $0.usage != 40 && $0.usage != 43 })
        // us and twin type identically; the others are told apart.
        #expect(probe.groups.count == 3)
        #expect(probe.groups.first?.layouts.map(\.name) == ["twin", "us"])
        let accentText = try #require(probe.expectations.first { $0.layout.name == "accent" }?.text)
        #expect(probe.matches(accentText).map(\.name) == ["accent"])
        // Deterministic for the same layouts.
        #expect(LayoutProbe.design([us, swapped, accent, twin]) == probe)
    }

    @Test func aKeyTypingAControlCharacterInAnyLayoutIsNeverUsed() {
        let plain = Self.layout("plain", [:])
        let odd = Self.layout("odd", [47: "!"], control: [53])
        let probe = LayoutProbe.design([plain, odd])
        #expect(!probe.strokes.contains { $0.usage == 53 })
        #expect(probe.groups.count == 2)
        // Ties prefer a key that is not a letter.
        #expect(!(4...29).contains(probe.strokes[0].usage))
    }

    @Test func installedLayoutsSeparateTheCommonOnes() throws {
        let probe = try LayoutProbe.installed()
        let names = Set(probe.expectations.map(\.layout.name))
        guard ["us", "spanish-iso", "german", "french", "british"].allSatisfy(names.contains) else { return } // a host without these layouts
        func text(_ name: String) -> String { probe.expectations.first { $0.layout.name == name }!.text }
        #expect(probe.matches(text("spanish-iso")).map(\.name) == ["spanish-iso"])
        for name in ["us", "german", "french", "british"] {
            let group = probe.matches(text(name)).map(\.name)
            #expect(group.contains(name) && !group.contains("spanish-iso"), "\(name): \(group)")
        }
        #expect(Set(["us", "german", "french", "british", "spanish-iso"].map(text)).count == 5)
        #expect(probe.strokes.count <= LayoutProbe.maximumStrokes && probe.strokes.allSatisfy { !$0.option })
    }

    // MARK: Running against a fake field

    /// A text field: an accessibility value that reads as the placeholder
    /// while empty, set-value, typing that appends what the device's layout
    /// makes of the probe, and backspaces.
    final class Field: Sendable {
        struct State {
            var text: String
            var log: [String] = []
        }
        let state: Mutex<State>
        let placeholder: String
        let arrives: String
        let transform: @Sendable (String) -> String
        let failKeys: Bool

        init(text: String = "", placeholder: String = "text probe", arrives: String, failKeys: Bool = false,
             transform: @escaping @Sendable (String) -> String = { $0 }) {
            state = Mutex(State(text: text)); self.placeholder = placeholder; self.arrives = arrives
            self.failKeys = failKeys; self.transform = transform
        }

        var text: String { state.withLock { $0.text } }
        var log: [String] { state.withLock { $0.log } }

        func operations(setting: [String: Any]? = nil) -> LayoutDetection.Operations {
            let placeholder = placeholder, arrives = arrives, transform = transform, failKeys = failKeys
            nonisolated(unsafe) let setting = setting
            return LayoutDetection.Operations(
                read: { self.state.withLock { $0.log.append("read"); return $0.text.isEmpty ? placeholder : $0.text } },
                set: { value in self.state.withLock { $0.log.append("set \(value)"); $0.text = transform(value); return $0.text == value } },
                keys: { schedule in
                    if failKeys, schedule.usages.contains(where: { $0 != LayoutDetection.backspaceUsage }) {
                        throw CommandFailure(.transportFailed, "keyboard failed", inputSent: .possible)
                    }
                    self.state.withLock {
                        if schedule.usages.allSatisfy({ $0 == LayoutDetection.backspaceUsage }) {
                            $0.log.append("backspace \(schedule.usages.count)")
                            $0.text = String($0.text.dropLast(schedule.usages.count))
                        } else {
                            $0.log.append("type")
                            $0.text = transform($0.text + arrives)
                        }
                    }
                },
                deviceSetting: { setting })
        }
    }

    static func command(_ platform: Target.Platform = .physical) throws -> LayoutDetectionCommand {
        let selector = try SelectorOptions.parse(["--id", "probe.text.field"])
        return try LayoutDetectionCommand(Target(platform: platform, identifier: platform == .physical ? device : simulator), selector: selector)
    }

    static let probe: LayoutProbe = LayoutProbe.design([layout("us", [:]), layout("swapped", [29: "y", 28: "z"]), layout("twin", [:])])
    static func expected(_ name: String) -> String { probe.expectations.first { $0.layout.name == name }!.text }

    @Test func anEmptyFieldIsDetectedAndClearedBackToItsPlaceholder() async throws {
        let field = Field(arrives: Self.expected("swapped"))
        let result = try await LayoutDetection.run(Self.command(), probe: Self.probe, operations: field.operations())
        #expect(result["status"] as? String == "detected" && result["layoutOption"] as? String == "--layout swapped")
        #expect(result["arrived"] as? String == Self.expected("swapped"))
        let restore = try #require(result["restore"] as? [String: Any])
        #expect(restore["status"] as? String == "cleared-to-original" && restore["confirmed"] as? Bool == true)
        #expect(field.text.isEmpty)
        #expect(field.log == ["read", "set x", "type", "read", "backspace \(1 + Self.expected("swapped").count)", "read"])
    }

    @Test func aFieldWithTextGetsItBackBySetValue() async throws {
        let field = Field(text: "mañana", arrives: Self.expected("us"))
        let result = try await LayoutDetection.run(Self.command(), probe: Self.probe, operations: field.operations())
        #expect(result["status"] as? String == "ambiguous")
        #expect((result["layouts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["twin", "us"])
        #expect(result["layoutOption"] == nil)
        let restore = try #require(result["restore"] as? [String: Any])
        #expect(restore["status"] as? String == "set-value" && restore["confirmed"] as? Bool == true)
        #expect(field.text == "mañana")
    }

    @Test func aTransformingFieldIsReportedNotMisidentified() async throws {
        // Capitalises everything it receives, like Caps Lock.
        let field = Field(arrives: Self.expected("swapped"), transform: { $0.uppercased() })
        let failure = try await #require(throws: CommandFailure.self) {
            _ = try await LayoutDetection.run(Self.command(), probe: Self.probe, operations: field.operations())
        }
        // set-value "x" read back as "X": refused before typing, field restored.
        #expect(failure.code == .preconditionChanged && failure.description.contains("Field restore"))
        #expect(!field.log.contains("type"))

        let typed = Field(arrives: Self.expected("swapped").uppercased())
        let result = try await LayoutDetection.run(Self.command(), probe: Self.probe, operations: typed.operations())
        #expect(result["status"] as? String == "no-match" && (result["layouts"] as? [Any])?.isEmpty == true)
        let hints = try #require(result["matchesAfterUndoing"] as? [[String: Any]])
        #expect(hints.first?["layouts"] as? [String] == ["swapped"])
        #expect((result["notes"] as? [String])?.first?.contains("probe.text.field") == true)
    }

    @Test func aFailedKeyboardStillRestoresAndSaysSo() async throws {
        let field = Field(text: "keep", arrives: "", failKeys: true)
        let failure = try await #require(throws: CommandFailure.self) {
            _ = try await LayoutDetection.run(Self.command(), probe: Self.probe, operations: field.operations())
        }
        #expect(failure.code == .transportFailed && failure.inputSent == .possible)
        #expect(failure.description.contains("Field restore: set-value, confirmed=true"))
        #expect(field.text == "keep")
    }

    @Test func aSimulatorSettingIsComparedWithTheResult() async throws {
        let field = Field(arrives: Self.expected("swapped"))
        let setting: [String: Any] = ["status": "explicit", "deviceLayout": "us"]
        let result = try await LayoutDetection.run(Self.command(.simulator), probe: Self.probe, operations: field.operations(setting: setting))
        let compared = try #require(result["deviceSetting"] as? [String: Any])
        #expect(compared["agrees"] as? Bool == false && compared["deviceLayout"] as? String == "us")
    }

    @Test func simulatorSettingNamesOnlyAnExplicitLayout() throws {
        func plist(_ mode: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["KeyboardLastUsed": mode], format: .xml, options: 0)
        }
        let sources = [KeyboardLayout.Source(name: "spanish-iso", identifier: "com.apple.keylayout.Spanish-ISO", localizedName: "Spanish")]
        let explicit = DeviceKeyboardLayout.simulatorSetting(.success(try plist("es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO")), sources: sources)
        #expect(explicit["status"] as? String == "explicit" && explicit["deviceLayout"] as? String == "spanish-iso")
        let automatic = DeviceKeyboardLayout.simulatorSetting(.success(try plist("en_US@sw=QWERTY;hw=Automatic")), sources: sources)
        #expect(automatic["status"] as? String == "automatic" && automatic["deviceLayout"] == nil)
        let unknown = DeviceKeyboardLayout.simulatorSetting(.success(try plist("xx@hw=Klingon")), sources: sources)
        #expect(unknown["status"] as? String == "unknown-layout")
        #expect(DeviceKeyboardLayout.simulatorSetting(.failure(CancellationError()), sources: sources)["status"] as? String == "not-read")
    }

    @Test func theFieldValueComesFromExactlyOneNode() throws {
        func tree(_ nodes: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["nodes": nodes]) }
        let one = try tree([["identifier": "f", "label": "Field", "value": "abc"], ["identifier": "g", "label": "Other"]])
        #expect(try LayoutDetection.fieldValue(fromTree: one, by: "identifier", text: "f") == "abc")
        #expect(try LayoutDetection.fieldValue(fromTree: one, by: "label", text: "Other") == "")
        let twice = try tree([["label": "Field"], ["label": "Field"]])
        let failure = try #require(throws: CommandFailure.self) { try LayoutDetection.fieldValue(fromTree: twice, by: "label", text: "Field") }
        #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
        #expect(throws: CommandFailure.self) { try LayoutDetection.fieldValue(fromTree: one, by: "identifier", text: "missing") }
    }

    @Test func backspacesAreOneKeyPressEach() {
        let schedule = LayoutDetection.backspaces(3)
        #expect(schedule.usages == [42, 42, 42] && schedule.samples.count == 6)
        #expect(schedule.samples.map(\.state) == [1, 2, 1, 2, 1, 2])
    }
}
