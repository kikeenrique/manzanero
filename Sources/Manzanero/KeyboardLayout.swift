import AppleDeviceBridge
import Carbon.HIToolbox
import Foundation
import Synchronization

/// A hardware-keyboard layout and the HID strokes that type each character it
/// can produce: plain, Shift, Option, Shift+Option, and one dead key followed
/// by one key. Built from the macOS layout of the same name through the Text
/// Input Sources API and `UCKeyTranslate`; the iOS 27.2 runtime ships the same
/// tables (docs/keyboard-layouts.md). The caller names the layout; nothing
/// here reads or guesses the device's.
struct KeyboardLayout: Sendable {
    /// One key press: a Keyboard/Keypad usage with Left Shift and Left Option held around it.
    struct Stroke: Hashable, Sendable {
        let usage: UInt64
        var shift = false
        var option = false
    }

    /// One installed layout: the name people type, the macOS input-source
    /// identifier and the host's localized name.
    struct Source: Sendable, Equatable {
        let name: String
        let identifier: String
        let localizedName: String
    }

    static let defaultName = "us"
    static let environmentVariable = "MANZANERO_KEYBOARD_LAYOUT"
    static let identifierPrefix = "com.apple.keylayout."
    static let shiftUsage: UInt64 = 225
    static let optionUsage: UInt64 = 226
    static let tabUsage: UInt64 = 43
    static let returnUsage: UInt64 = 40
    /// Text length and the largest schedule sent at once: today's worst case
    /// (512 shifted ASCII characters, 2048 events over 20.47 s).
    static let characterLimit = 1...512
    static let sampleLimit = 2048
    /// `UCKeyTranslate`'s keyboard type: ISO (41). The simulator translated
    /// HID 53 in Latin American as the ISO table does (`<`, not the ANSI `|`);
    /// the two types differ only on HID 53 and 100, in 13 layouts.
    static let keyboardType: UInt32 = 41
    /// Modifier states in `UCKeyTranslate`'s form (`EventModifiers >> 8`), in order of preference.
    static let modifierStates: [(shift: Bool, option: Bool, state: UInt32)] = [(false, false, 0), (true, false, 2), (false, true, 8), (true, true, 10)]

    /// HID usage → Mac virtual key code for the main block, by usage. Non-US #
    /// (50), keypad, JIS keys and Caps Lock are not used.
    static let keyCodes: [(usage: UInt64, code: UInt16)] = [
        (4, 0), (5, 11), (6, 8), (7, 2), (8, 14), (9, 3), (10, 5), (11, 4), (12, 34), (13, 38), (14, 40), (15, 37), (16, 46),
        (17, 45), (18, 31), (19, 35), (20, 12), (21, 15), (22, 1), (23, 17), (24, 32), (25, 9), (26, 13), (27, 7), (28, 16), (29, 6),
        (30, 18), (31, 19), (32, 20), (33, 21), (34, 23), (35, 22), (36, 26), (37, 28), (38, 25), (39, 29),
        (44, 49), (45, 27), (46, 24), (47, 33), (48, 30), (49, 42), (51, 41), (52, 39), (53, 50), (54, 43), (55, 47), (56, 44),
        (100, 10),
    ]

    /// Translates one key: Mac key code, modifier state and the dead-key
    /// state, which it updates. Returns the produced text, or nil on failure.
    typealias Translate = (_ code: UInt16, _ modifiers: UInt32, _ deadState: inout UInt32) -> String?

    let source: Source
    let strokes: [Character: [Stroke]]
    private let layoutData: Data

    // MARK: Catalog

    /// The process's installed layouts and built tables. Concurrent Text Input
    /// Sources calls aborted the process (parallel tests), so every Carbon call
    /// (TIS and `UCKeyTranslate`) runs under this lock. Layouts installed after
    /// the first use are not seen until the process restarts.
    private struct Cache {
        var installed: [(source: Source, data: Data)]?
        var layouts: [String: KeyboardLayout] = [:]

        mutating func load() -> [(source: Source, data: Data)] {
            if let installed { return installed }
            let found = KeyboardLayout.installed()
            installed = found
            return found
        }
    }

    private static let carbon = Mutex(Cache())

    /// Every keyboard layout installed on this Mac that carries `uchr` data, by name.
    static func available() -> [Source] {
        carbon.withLock { $0.load().map(\.source) }
    }

    private static func installed() -> [(source: Source, data: Data)] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        var seen = Set<String>()
        var result: [(source: Source, data: Data)] = []
        for input in list {
            guard let identifier = property(input, kTISPropertyInputSourceID, as: CFString.self) as String?,
                  identifier.hasPrefix(identifierPrefix),
                  let data = property(input, kTISPropertyUnicodeKeyLayoutData, as: CFData.self) as Data?,
                  seen.insert(identifier).inserted else { continue }
            let localized = property(input, kTISPropertyLocalizedName, as: CFString.self) as String? ?? identifier
            result.append((Source(name: slug(identifier), identifier: identifier, localizedName: localized), data))
        }
        return result.sorted { $0.source.name < $1.source.name }
    }

    private static func property<Value: AnyObject>(_ input: TISInputSource, _ key: CFString, as: Value.Type) -> Value? {
        guard let pointer = TISGetInputSourceProperty(input, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? Value
    }

    /// Lowercase letters and digits only: `Spanish - ISO`, `Spanish-ISO` and
    /// `spanish-iso` are one name.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `com.apple.keylayout.USInternational-PC` → `us-international-pc`.
    static func slug(_ identifier: String) -> String {
        let base = Array(identifier.hasPrefix(identifierPrefix) ? String(identifier.dropFirst(identifierPrefix.count)) : identifier)
        var words: [String] = []
        var current = ""
        for (index, character) in base.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if character.isUppercase, let previous = current.last {
                let next = index + 1 < base.count ? base[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: "-")
    }

    /// The source a name means, or nil: its normalized letters and digits must
    /// equal those of one layout's name or identifier suffix.
    static func match(_ name: String, in sources: [Source]) -> Source? {
        let key = normalized(name.hasPrefix(identifierPrefix) ? String(name.dropFirst(identifierPrefix.count)) : name)
        guard !key.isEmpty else { return nil }
        return sources.first { normalized($0.name) == key } ?? sources.first { normalized(String($0.identifier.dropFirst(identifierPrefix.count))) == key }
    }

    /// The installed layout with this name, with its character table.
    static func named(_ name: String) throws -> Self {
        try carbon.withLock { cache in
            let installed = cache.load()
            guard !installed.isEmpty else {
                throw CommandFailure(.hostRequirement, "This Mac lists no keyboard layouts through the Text Input Sources API, so typing has no character table; no input sent.", inputSent: .none)
            }
            guard let source = match(name, in: installed.map(\.source)), let data = installed.first(where: { $0.source == source })?.data else {
                throw CommandFailure.usage("Unknown keyboard layout '\(name)'. List the available names with `manzanero keyboard-layouts`; no input sent.")
            }
            if let built = cache.layouts[source.identifier] { return built }
            let layout = Self(source: source, layoutData: data)
            cache.layouts[source.identifier] = layout
            return layout
        }
    }

    /// Builds the table; callers hold `carbon`.
    private init(source: Source, layoutData: Data) {
        self.source = source
        self.layoutData = layoutData
        strokes = layoutData.withUnsafeBytes { raw in
            Self.table(Self.translator(raw))
        }
    }

    private static func translator(_ raw: UnsafeRawBufferPointer) -> Translate {
        let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
        return { code, modifiers, deadState in
            guard let layout else { return nil }
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0,
                                        &deadState, characters.count, &length, &characters)
            return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
        }
    }

    // MARK: Table

    /// The shortest strokes for every character the layout produces: single
    /// keys first (no modifier, Shift, Option, Shift+Option; lower usage
    /// first), then a dead key followed by one key. Tab and LF are not in the
    /// table; `samples` sends them as Tab and Return.
    static func table(_ translate: Translate) -> [Character: [Stroke]] {
        var result: [Character: [Stroke]] = [:]
        var deadKeys: [(stroke: Stroke, state: UInt32)] = []
        for (shift, option, modifiers) in modifierStates {
            for (usage, code) in keyCodes {
                var state: UInt32 = 0
                guard let text = translate(code, modifiers, &state) else { continue }
                let stroke = Stroke(usage: usage, shift: shift, option: option)
                if text.isEmpty, state != 0 {
                    deadKeys.append((stroke, state))
                } else if text.count == 1, let character = text.first, result[character] == nil, isTypeable(character) {
                    result[character] = [stroke]
                }
            }
        }
        for dead in deadKeys {
            for (shift, option, modifiers) in modifierStates {
                for (usage, code) in keyCodes {
                    var state = dead.state
                    guard let text = translate(code, modifiers, &state), text.count == 1, let character = text.first,
                          result[character] == nil, isTypeable(character) else { continue }
                    result[character] = [dead.stroke, Stroke(usage: usage, shift: shift, option: option)]
                }
            }
        }
        return result
    }

    /// Printable output only: no control characters (Tab and LF have their own keys).
    private static func isTypeable(_ character: Character) -> Bool {
        !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    // MARK: Schedule

    /// The strokes for the whole text, each character checked by translating
    /// its strokes again from the state the previous ones left, so the
    /// schedule produces exactly the text on a device with this layout.
    func plan(_ text: String) throws -> [Stroke] {
        guard Self.characterLimit.contains(text.count) else {
            throw CommandFailure.usage("Typing requires 1...512 characters; no input sent.")
        }
        let layoutData = layoutData
        return try Self.carbon.withLock { _ in try layoutData.withUnsafeBytes { raw in
            let translate = Self.translator(raw)
            var state: UInt32 = 0
            var result: [Stroke] = []
            for (index, character) in text.enumerated() {
                let keys: [Stroke]
                if character == "\t" || character == "\n" {
                    keys = [Stroke(usage: character == "\t" ? Self.tabUsage : Self.returnUsage)]
                    state = 0
                } else if let found = strokes[character], Self.replay(found, translate: translate, state: &state) == String(character) {
                    keys = found
                } else {
                    throw refusal(character, position: index + 1)
                }
                result += keys
            }
            let count = result.reduce(0) { $0 + 2 + ($1.shift ? 2 : 0) + ($1.option ? 2 : 0) }
            guard count <= Self.sampleLimit else {
                throw CommandFailure.usage("Typing this text in the \(source.name) layout needs \(count) keyboard events; at most \(Self.sampleLimit) are sent at once (512 plain or Shift characters, fewer with Option or dead keys). Split the text; no input sent.")
            }
            return result
        } }
    }

    private static func replay(_ keys: [Stroke], translate: Translate, state: inout UInt32) -> String? {
        var text = ""
        for key in keys {
            guard let code = keyCodes.first(where: { $0.usage == key.usage })?.code,
                  let output = translate(code, modifierStates.first { $0.shift == key.shift && $0.option == key.option }?.state ?? 0, &state) else { return nil }
            text += output
        }
        return text
    }

    private func refusal(_ character: Character, position: Int) -> CommandFailure {
        let scalars = character.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        let shown = character.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.isWhitespace } ? "" : "'\(character)' "
        return .usage("The \(source.name) keyboard layout cannot type \(shown)(\(scalars)), character \(position) of the text: only characters that layout produces with Shift, Option or one dead key can be typed. For other text use set-value with --id or --label, which replaces a named element's whole value without the keyboard. No input sent.")
    }

    /// The timed HID schedule: Shift and Option bracket each key, every key is
    /// released before the next, 10 ms apart. For US ASCII this is exactly the
    /// schedule of the former fixed table.
    func samples(_ text: String) throws -> [ADCKeyboardSample] {
        var result: [ADCKeyboardSample] = []
        func append(_ usage: UInt64, _ state: UInt64) {
            result.append(ADCKeyboardSample(nanoseconds: UInt64(result.count) * 10_000_000, usage: usage, state: state))
        }
        for key in try plan(text) {
            if key.shift { append(Self.shiftUsage, 1) }
            if key.option { append(Self.optionUsage, 1) }
            append(key.usage, 1)
            append(key.usage, 2)
            if key.option { append(Self.optionUsage, 2) }
            if key.shift { append(Self.shiftUsage, 2) }
        }
        return result
    }

    /// The layout fields of receipts and plans.
    var receiptFields: [String: Any] {
        ["layout": source.name, "layoutIdentifier": source.identifier]
    }
}

/// What the target says about its own hardware-keyboard layout, checked
/// before typing. A physical device's cannot be read. A simulator's is the
/// `hw=` part of its current input mode in `com.apple.keyboard.preferences`:
/// an explicit layout other than the requested one is refused, and
/// `hw=Automatic`, which iOS resolves itself, is reported as not checked.
enum DeviceKeyboardLayout {
    static let preferencesDomain = "com.apple.keyboard.preferences"
    static let relaunchNote = "An app that is already running can keep the layout it had at launch; relaunch it after changing the setting."

    static func physical(_ layout: KeyboardLayout) -> [String: Any] {
        ["status": "not-read",
         "reason": "No Apple tool reads a physical device's hardware-keyboard layout; the text is right only if the device's hardware keyboard layout is \(layout.source.name) (Settings > General > Keyboard > Hardware Keyboard)."]
    }

    /// The arguments of the simulator read (`xcrun` prefix omitted).
    static func simulatorRead(_ uuid: String) -> [String] {
        ["simctl", "spawn", uuid, "defaults", "export", preferencesDomain, "-"]
    }

    static func simulatorPlan(_ layout: KeyboardLayout) -> String {
        "Before input, read the simulator's current input mode (xcrun simctl spawn <UUID> defaults export \(preferencesDomain) -). A hw= layout other than \(layout.source.name) is refused with nothing sent; hw=Automatic, a layout macOS does not ship, or a failed read is reported as not checked."
    }

    /// The input mode of an exported preferences plist: `KeyboardLastUsed`,
    /// else the first of `KeyboardsCurrentAndNext`.
    static func inputMode(_ plist: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        return root["KeyboardLastUsed"] as? String ?? (root["KeyboardsCurrentAndNext"] as? [String])?.first
    }

    /// `es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO` → `Spanish - ISO`.
    static func hardwareLayout(_ mode: String) -> String? {
        guard let attributes = mode.split(separator: "@", maxSplits: 1).dropFirst().first else { return nil }
        for attribute in attributes.split(separator: ";") where attribute.hasPrefix("hw=") {
            return String(attribute.dropFirst(3))
        }
        return nil
    }

    /// The receipt entry for a simulator, or a usage failure when its explicit
    /// layout differs from the requested one.
    static func simulator(_ preferences: Result<Data, any Error>, layout: KeyboardLayout,
                          sources: @autoclosure () -> [KeyboardLayout.Source]) throws -> [String: Any] {
        let plist: Data
        switch preferences {
        case .success(let data): plist = data
        case .failure(let error):
            return ["status": "not-checked", "reason": "The simulator's keyboard preferences could not be read (\(error)); the text is right only if its hardware layout is \(layout.source.name).", "note": relaunchNote]
        }
        guard let mode = inputMode(plist) else {
            return ["status": "not-checked", "reason": "The simulator records no current input mode; the text is right only if its hardware layout is \(layout.source.name).", "note": relaunchNote]
        }
        guard let hardware = hardwareLayout(mode), hardware.caseInsensitiveCompare("Automatic") != .orderedSame else {
            return ["status": "not-checked", "inputMode": mode,
                    "reason": "The current input mode leaves the hardware layout to iOS (hw=Automatic), which is not resolved here; the text is right only if iOS chose \(layout.source.name).", "note": relaunchNote]
        }
        guard let device = KeyboardLayout.match(hardware, in: sources()) else {
            return ["status": "not-checked", "inputMode": mode, "deviceLayout": hardware,
                    "reason": "The simulator's hardware layout '\(hardware)' has no macOS layout of the same name to compare with \(layout.source.name).", "note": relaunchNote]
        }
        guard device.identifier == layout.source.identifier else {
            throw CommandFailure.usage("The simulator's current input mode (\(mode)) uses the \(device.name) hardware keyboard layout, not \(layout.source.name). Pass --layout \(device.name) (MCP layout: \(device.name)), or change the simulator's layout and relaunch the app. No input sent.")
        }
        return ["status": "matches", "inputMode": mode, "deviceLayout": device.name, "note": relaunchNote]
    }
}
