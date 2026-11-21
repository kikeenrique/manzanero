import Foundation

/// `type` on an Apple Watch: keyboard events do not reach watchOS, but the
/// keyboard watchOS shows for a text field can be typed on by its keys. Its
/// keys are not in the app's tree: the app holds a remote element whose
/// process (`QuickboardViewService`) draws the keyboard, and that process's
/// tree lists every key with its label and frame (seen on a watchOS 27.2
/// simulator, 2026-11-21; docs/other-families.md). Each character is typed
/// by reading the keys, switching page or case when its key is not showing,
/// and tapping the key; Done is tapped at the end, because the app receives
/// the text only then.
enum WatchKeyboard {
    struct Key: Equatable {
        let label: String
        /// The key's centre, normalized in the current interface.
        let x: Double
        let y: Double
    }

    /// The characters of the numbers and symbols pages (watchOS 27.2's
    /// English QWERTY keyboard; the symbols page is reached from the
    /// numbers page and repeats its last row). Accents are not typed: their
    /// long-press popup is drawn but is not in the keyboard's tree.
    static let numbersPage = Set("1234567890-/:;()$&@\".,?!'")
    static let symbolsPage = Set("[]{}#%^*+=_\\|~<>€£¥•")
    static let switchKeys = ["shift", "numbers", "symbols", "letters"]

    /// Refuses, before anything is sent, a text this keyboard cannot type.
    static func validate(_ text: String) throws {
        guard !text.isEmpty else { throw CommandFailure.usage("type needs a text; no input sent.") }
        for (offset, character) in text.enumerated() {
            let plain = character.isASCII && (character.isLetter || character.isNumber)
            guard plain || character == " " || numbersPage.contains(character) || symbolsPage.contains(character) else {
                let marks = String(numbersPage.union(symbolsPage).filter { !$0.isNumber }.sorted())
                throw CommandFailure.unsupported("An Apple Watch is typed on through its on-screen keyboard, which this tool drives for ASCII letters, digits, space and \(marks); '\(character)' (character \(offset + 1)) is not one of them (accented letters and emoji are not typed). No input sent.")
            }
        }
    }

    /// The label of the key that types a character.
    static func label(for character: Character) -> String {
        switch character {
        case " ": "space"
        case "&": "ampersand"
        default: String(character)
        }
    }

    /// The switch key to tap when a character's key is not showing: shift
    /// for a letter in the other case, letters, numbers or symbols for the
    /// other page. A symbol from the letters page goes through numbers.
    static func switchKey(for character: Character, showing: Set<String>) -> String? {
        if character.isLetter { return showing.contains("letters") ? "letters" : (showing.contains("shift") ? "shift" : nil) }
        if character == " " { return nil }
        if symbolsPage.contains(character), showing.contains("symbols") { return "symbols" }
        return showing.contains("numbers") ? "numbers" : nil
    }

    /// The process drawing the keyboard: the app's visible remote element.
    static func keyboardProcess(_ nodes: [AccessibilitySnapshot.Node]) -> Int32? {
        nodes.first { $0.externalProcessReference == true && $0.visible == true && $0.processIdentifier != nil }?.processIdentifier
    }

    /// The visible keys and buttons of the keyboard's tree by label.
    static func keys(_ nodes: [AccessibilitySnapshot.Node], bounds: AccessibilityDisplay.Bounds) -> [String: Key] {
        var keys: [String: Key] = [:]
        for node in nodes where node.visible == true {
            guard case .string(let label)? = node.label, let frame = node.frame, frame.width > 0, frame.height > 0, keys[label] == nil else { continue }
            keys[label] = Key(label: label, x: (frame.x + frame.width / 2 - bounds.x) / bounds.width,
                              y: (frame.y + frame.height / 2 - bounds.y) / bounds.height)
        }
        return keys
    }

    /// Types `text` and taps Done. `read` returns the keyboard's keys now;
    /// `tap` taps one key. Returns the number of taps.
    static func type(_ text: String, read: () throws -> [String: Key], tap: (Key) throws -> Void) throws -> (taps: Int, submitted: Bool) {
        var taps = 0
        func refuse(_ reason: String) -> CommandFailure {
            CommandFailure(.targetUnresolved, "\(reason) \(taps == 0 ? "No input sent." : "\(taps) key(s) were tapped before it: inspect the field before retrying.")",
                           inputSent: taps == 0 ? .none : .possible)
        }
        for (offset, character) in text.enumerated() {
            try Task.checkCancellation()
            let wanted = label(for: character)
            var keys = try read()
            var switches = 0
            while keys[wanted] == nil {
                guard switches < 3, let name = switchKey(for: character, showing: Set(keys.keys)), let key = keys[name] else {
                    throw refuse("The watch keyboard shows no key for '\(character)' (character \(offset + 1)).")
                }
                try tap(key)
                taps += 1
                switches += 1
                keys = try read()
            }
            try tap(keys[wanted]!)
            taps += 1
        }
        guard let done = try read()["Done"] else { return (taps, false) }
        try tap(done)
        return (taps + 1, true)
    }
}
