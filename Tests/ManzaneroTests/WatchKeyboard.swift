import Foundation
import Testing
@testable import Manzanero

/// `type` on an Apple Watch against a model of watchOS 27.2's keyboard as
/// it was read on a simulator: a letters page that starts capitalised and
/// drops to lowercase after one letter, shift, a numbers page and a symbols
/// page reached from it.
struct WatchKeyboardTests {
    final class Model {
        var numbers = false
        var symbols = false
        var upper = true
        var text = ""
        var tapped: [String] = []
        var submitted = false

        var keys: [String: WatchKeyboard.Key] {
            let letters = "QWERTYUIOPASDFGHJKLZXCVBNM".map { upper ? String($0) : $0.lowercased() }
            let symbolKeys: [String] = "[]{}#%^*+=_\\|~<>€£¥•.,?!'".map(String.init) + ["numbers", "letters"]
            let numberKeys: [String] = "1234567890-/:;()$@\".,?!'".map(String.init) + ["ampersand", "symbols", "letters"]
            let letterKeys: [String] = letters + ["shift", "numbers"]
            let page = symbols ? symbolKeys : (numbers ? numberKeys : letterKeys)
            return Dictionary(uniqueKeysWithValues: (page + ["space", "Done", "delete"]).map { ($0, WatchKeyboard.Key(label: $0, x: 0.5, y: 0.5)) })
        }

        func tap(_ key: WatchKeyboard.Key) {
            tapped.append(key.label)
            switch key.label {
            case "shift": upper.toggle()
            case "numbers": numbers = true; symbols = false
            case "symbols": symbols = true; numbers = false
            case "letters": numbers = false; symbols = false
            case "space": text += " "
            case "ampersand": text += "&"
            case "Done": submitted = true
            case "delete": break
            default:
                text += key.label
                if key.label.first?.isLetter == true { upper = false }
            }
        }
    }

    @Test func textIsTypedKeyByKeyWithCaseAndPageSwitchesThenDone() throws {
        let model = Model()
        let typed = try WatchKeyboard.type("Bob 42! aB&c", read: { model.keys }, tap: { model.tap($0) })
        #expect(model.text == "Bob 42! aB&c" && model.submitted)
        #expect(typed.taps == model.tapped.count && typed.submitted)
        // "B" is capital already; digits switch to numbers, a letter back, a capital needs shift.
        #expect(model.tapped.prefix(8) == ["B", "o", "b", "space", "numbers", "4", "2", "!"])
        #expect(model.tapped.contains("shift") && model.tapped.last == "Done")
    }

    @Test func aLowercaseFirstLetterPressesShiftFirst() throws {
        let model = Model()
        _ = try WatchKeyboard.type("ok", read: { model.keys }, tap: { model.tap($0) })
        #expect(model.tapped == ["shift", "o", "k", "Done"] && model.text == "ok")
    }

    @Test func symbolsAreTypedThroughTheNumbersPage() throws {
        let model = Model()
        _ = try WatchKeyboard.type("a[1]#€x", read: { model.keys }, tap: { model.tap($0) })
        #expect(model.text == "a[1]#€x" && model.submitted)
        // A symbol from the letters page goes through numbers; a digit from
        // symbols goes back to numbers; a letter goes back to letters.
        #expect(model.tapped == ["shift", "a", "numbers", "symbols", "[", "numbers", "1", "symbols", "]", "#", "€", "letters", "x", "Done"])
    }

    @Test(arguments: ["Gómez", "🍏", "a\u{2192}b", "x§y", ""])
    func whatTheKeyboardCannotTypeIsRefusedBeforeAnyTap(_ text: String) {
        #expect(throws: CommandFailure.self) { try WatchKeyboard.validate(text) }
    }

    @Test func aMissingKeyMidwayReportsThatInputWasSent() throws {
        let model = Model()
        var reads = 0
        let failure = try #require(throws: CommandFailure.self) {
            _ = try WatchKeyboard.type("ab", read: {
                reads += 1
                // The keyboard goes away after the first letter.
                return reads > 2 ? [:] : model.keys
            }, tap: { model.tap($0) })
        }
        #expect(failure.inputSent == .possible && failure.description.contains("inspect the field"))
    }

    @Test func labelsAndSwitchKeys() {
        #expect(WatchKeyboard.label(for: " ") == "space" && WatchKeyboard.label(for: "&") == "ampersand" && WatchKeyboard.label(for: "x") == "x")
        #expect(WatchKeyboard.switchKey(for: "a", showing: ["A", "shift", "numbers"]) == "shift")
        #expect(WatchKeyboard.switchKey(for: "a", showing: ["1", "letters"]) == "letters")
        #expect(WatchKeyboard.switchKey(for: "1", showing: ["a", "shift", "numbers"]) == "numbers")
        #expect(WatchKeyboard.switchKey(for: "#", showing: ["a", "shift", "numbers"]) == "numbers")
        #expect(WatchKeyboard.switchKey(for: "#", showing: ["1", "symbols", "letters"]) == "symbols")
        #expect(WatchKeyboard.switchKey(for: "1", showing: ["#", "numbers", "letters"]) == "numbers")
    }
}
