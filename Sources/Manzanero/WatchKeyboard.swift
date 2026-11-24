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
    /// How long `type` looks for a keyboard that is still opening: twelve
    /// reads a quarter of a second apart, after the first.
    static let openingReads = 12
    static let openingInterval: Duration = .milliseconds(250)

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

    /// The class watchOS gives a keyboard key, and the one it gives the
    /// Cancel and Done buttons above the keyboard (attribute 5003).
    static let keyClass = "UIAccessibilityElementKBKey"
    static let barButtonClass = "PUICBarButtonItemView"

    /// The language-independent name of a function key, from its identifier
    /// and the page showing. The labels are the keyboard language's (in
    /// German `Umschalt`, `Zahlen`, `Leerzeichen`, `Fertig`), the identifiers
    /// are not: `shift` is shift on the letters page and the symbols key on
    /// the numbers page, `more` the numbers key and then the letters key
    /// (watchOS 27.2 simulator in German, 2026-11-22).
    static func functionKey(identifier: String, page: Page) -> String? {
        switch (identifier, page) {
        case ("space", _): "space"
        case ("delete", _): "delete"
        case ("shift", .letters): "shift"
        case ("shift", .numbers): "symbols"
        case ("shift", .symbols): "numbers"
        case ("more", .letters): "numbers"
        case ("more", _): "letters"
        default: nil
        }
    }

    enum Page { case letters, numbers, symbols }

    /// The page showing: symbols when `[` is a key, numbers when `1` is.
    static func page(labels: Set<String>) -> Page {
        labels.contains("[") ? .symbols : labels.contains("1") ? .numbers : .letters
    }

    /// The visible keys and buttons of the keyboard's tree, by the names
    /// `type` uses: a character key by its character, a function key by
    /// `functionKey`, the one key with neither a one-character label nor an
    /// identifier as `ampersand` (its label is the language's word for it),
    /// and the rightmost bar button as `Done`. Labels fill in what those
    /// leave out, so an English keyboard's own words still name its keys.
    static func keys(_ nodes: [AccessibilitySnapshot.Node], bounds: AccessibilityDisplay.Bounds) -> [String: Key] {
        func text(_ scalar: AccessibilitySnapshot.Scalar?) -> String? { if case .string(let value)? = scalar { value } else { nil } }
        return keys(nodes.map { Entry(label: text($0.label), identifier: text($0.identifier), frame: $0.frame, visible: $0.visible,
                                      className: $0.nativeAttributes?["5003"]) }, bounds: bounds)
    }

    /// What `keys` reads of a tree node: from a live snapshot (a simulator)
    /// or from a tree command's JSON (a physical watch).
    struct Entry: Equatable {
        let label: String?
        let identifier: String?
        let frame: AccessibilitySnapshot.Frame?
        let visible: Bool?
        let className: String?
    }

    /// A tree command's result as entries, with the display's bounds.
    static func entries(tree: Data) throws -> (entries: [Entry], bounds: AccessibilityDisplay.Bounds) {
        guard let root = try JSONSerialization.jsonObject(with: tree) as? [String: Any],
              let display = (root["display"] as? [String: Any])?["bounds"] as? [String: Any],
              let width = (display["width"] as? NSNumber)?.doubleValue, let height = (display["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0, let nodes = root["nodes"] as? [[String: Any]] else {
            throw CommandFailure(.transportFailed, "The watch's accessibility tree could not be read for its keyboard. No input sent.", inputSent: .none)
        }
        let bounds = AccessibilityDisplay.Bounds(x: (display["x"] as? NSNumber)?.doubleValue ?? 0, y: (display["y"] as? NSNumber)?.doubleValue ?? 0,
                                                 width: width, height: height)
        let entries = nodes.map { node -> Entry in
            let frame = (node["frame"] as? [String: Any]).flatMap { f -> AccessibilitySnapshot.Frame? in
                guard let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
                      let w = (f["width"] as? NSNumber)?.doubleValue, let h = (f["height"] as? NSNumber)?.doubleValue else { return nil }
                return AccessibilitySnapshot.Frame(x: x, y: y, width: w, height: h)
            }
            return Entry(label: node["label"] as? String, identifier: node["identifier"] as? String, frame: frame,
                         visible: node["visible"] as? Bool, className: (node["nativeAttributes"] as? [String: String])?["5003"])
        }
        return (entries, bounds)
    }

    /// Whether entries show a keyboard: at least one key of the keyboard's
    /// own class. An app's button labelled `A` is not a key.
    static func showsKeyboard(_ entries: [Entry]) -> Bool {
        entries.contains { $0.className == keyClass && $0.visible == true }
    }

    static func keys(_ entries: [Entry], bounds: AccessibilityDisplay.Bounds) -> [String: Key] {
        func centre(_ frame: AccessibilitySnapshot.Frame, _ name: String) -> Key {
            Key(label: name, x: (frame.x + frame.width / 2 - bounds.x) / bounds.width, y: (frame.y + frame.height / 2 - bounds.y) / bounds.height)
        }
        let shown = entries.filter { $0.visible == true && ($0.frame?.width ?? 0) > 0 && ($0.frame?.height ?? 0) > 0 }
        let page = page(labels: Set(shown.compactMap(\.label)))
        var keys: [String: Key] = [:]
        for entry in shown {
            guard let frame = entry.frame, let identifier = entry.identifier,
                  let name = functionKey(identifier: identifier, page: page), keys[name] == nil else { continue }
            keys[name] = centre(frame, name)
        }
        let worded = shown.filter { $0.className == keyClass && $0.identifier == nil && ($0.label?.count ?? 0) > 1 }
        if worded.count == 1, let frame = worded[0].frame, keys["ampersand"] == nil { keys["ampersand"] = centre(frame, "ampersand") }
        if let done = shown.filter({ $0.className == barButtonClass }).max(by: { ($0.frame?.x ?? 0) < ($1.frame?.x ?? 0) }),
           let frame = done.frame, keys["Done"] == nil {
            keys["Done"] = centre(frame, "Done")
        }
        for entry in shown {
            guard let label = entry.label, let frame = entry.frame, keys[label] == nil else { continue }
            keys[label] = centre(frame, label)
        }
        return keys
    }

    /// Types `text` and taps Done. `read` returns the keyboard's keys now;
    /// `tap` taps one key. Returns the number of taps.
    static func type(_ text: String, read: () throws -> [String: Key], tap: (Key) throws -> Void) throws -> (taps: Int, submitted: Bool) {
        var taps = 0
        for (offset, character) in text.enumerated() {
            try Task.checkCancellation()
            var keys = try read()
            var switches = 0
            while true {
                let (key, done) = try next(character, offset: offset, keys: keys, switches: switches, taps: taps)
                try tap(key)
                taps += 1
                if done { break }
                switches += 1
                keys = try read()
            }
        }
        guard let done = try read()["Done"] else { return (taps, false) }
        try tap(done)
        return (taps + 1, true)
    }

    /// The same, for reads and taps that suspend (a physical watch).
    static func type(_ text: String, read: () async throws -> [String: Key], tap: (Key) async throws -> Void,
                     isolation: isolated (any Actor)? = #isolation) async throws -> (taps: Int, submitted: Bool) {
        var taps = 0
        for (offset, character) in text.enumerated() {
            try Task.checkCancellation()
            var keys = try await read()
            var switches = 0
            while true {
                let (key, done) = try next(character, offset: offset, keys: keys, switches: switches, taps: taps)
                try await tap(key)
                taps += 1
                if done { break }
                switches += 1
                keys = try await read()
            }
        }
        guard let done = try await read()["Done"] else { return (taps, false) }
        try await tap(done)
        return (taps + 1, true)
    }

    /// The next key to tap for `character`: the character's own key (done)
    /// or a page switch, at most three switches.
    static func next(_ character: Character, offset: Int, keys: [String: Key], switches: Int, taps: Int) throws -> (key: Key, done: Bool) {
        let wanted = label(for: character)
        if let key = keys[wanted] { return (key, true) }
        guard switches < 3, let name = switchKey(for: character, showing: Set(keys.keys)), let key = keys[name] else {
            throw CommandFailure(.targetUnresolved,
                "The watch keyboard shows no key for '\(character)' (character \(offset + 1)). \(taps == 0 ? "No input sent." : "\(taps) key(s) were tapped before it: inspect the field before retrying.")",
                inputSent: taps == 0 ? .none : .possible)
        }
        return (key, false)
    }
}
