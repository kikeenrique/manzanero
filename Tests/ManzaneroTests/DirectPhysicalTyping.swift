import AppleDeviceBridge
import Foundation
import MCP
import Testing
@testable import Manzanero

struct DirectPhysicalTypingTests {
    /// The fixed US table `type` used before layouts: the oracle for the `us`
    /// layout, which must give exactly the same schedule for ASCII.
    static func formerStroke(_ byte: UInt8) -> (usage: UInt64, shift: Bool)? {
        switch byte {
        case 97...122: return (UInt64(byte - 97 + 4), false)
        case 65...90: return (UInt64(byte - 65 + 4), true)
        case 49...57: return (UInt64(byte - 49 + 30), false)
        case 48: return (39, false)
        case 9: return (43, false)
        case 10: return (40, false)
        case 32: return (44, false)
        default: break
        }
        if let index = Array("!@#$%^&*()".utf8).firstIndex(of: byte) { return (UInt64(30 + index), true) }
        let codes: [UInt64] = [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56]
        for (characters, shift) in [("-=[]\\;'`,./", false), ("_+{}|:\"~<>?", true)] {
            if let index = Array(characters.utf8).firstIndex(of: byte) { return (codes[index], shift) }
        }
        return nil
    }

    static func formerSamples(_ text: String) -> [ADCKeyboardSample] {
        var result: [ADCKeyboardSample] = []
        func append(_ usage: UInt64, _ state: UInt64) {
            result.append(ADCKeyboardSample(nanoseconds: UInt64(result.count) * 10_000_000, usage: usage, state: state))
        }
        for byte in text.utf8 {
            guard let key = formerStroke(byte) else { return [] }
            if key.shift { append(225, 1) }
            append(key.usage, 1)
            append(key.usage, 2)
            if key.shift { append(225, 2) }
        }
        return result
    }

    static func samples(_ text: String, _ layout: String = "us") throws -> [ADCKeyboardSample] {
        try KeyboardLayout.named(layout).samples(text)
    }

    static func strokes(_ character: Character, _ layout: String) throws -> [KeyboardLayout.Stroke] {
        try #require(try KeyboardLayout.named(layout).strokes[character])
    }

    @Test func usLayoutGivesTheFormerScheduleForEveryASCIICharacter() throws {
        let ascii = String((32...126).map { Character(Unicode.Scalar($0)) }) + "\t\n"
        for character in ascii {
            let expected = Self.formerSamples(String(character))
            #expect(!expected.isEmpty)
            #expect(try Self.samples(String(character)).elementsEqual(expected) { $0.usage == $1.usage && $0.state == $1.state && $0.nanoseconds == $1.nanoseconds },
                    "\(character.debugDescription)")
        }
        let text = String(repeating: ascii, count: 5)
        #expect(try Self.samples(text).elementsEqual(Self.formerSamples(text)) { $0.usage == $1.usage && $0.state == $1.state && $0.nanoseconds == $1.nanoseconds })
    }

    @Test func releasesModifiersBetweenCharactersAndBoundsWorstCaseSchedule() throws {
        let schedule = try Self.samples("Aa!")
        #expect(schedule.map(\.usage) == [225, 4, 4, 225, 4, 4, 225, 30, 30, 225])
        #expect(schedule.map(\.state) == [1, 1, 2, 2, 1, 2, 1, 1, 2, 2])
        #expect(schedule.map(\.nanoseconds) == (0..<10).map { UInt64($0) * 10_000_000 })
        let maximum = try Self.samples(String(repeating: "A", count: 512))
        #expect(maximum.count == 2048)
        #expect(maximum.last?.nanoseconds == 20_470_000_000)
        var pressed: Set<UInt64> = []
        for sample in maximum {
            if sample.state == 1 { #expect(pressed.insert(sample.usage).inserted) }
            else { #expect(pressed.remove(sample.usage) != nil) }
        }
        #expect(pressed.isEmpty)
        // The bridge's own check accepts the new usages, Non-US \ (100) and Left
        // Option (226): stopped at once, a valid schedule returns 1, an invalid one 2.
        for (text, layout) in [("é", "us"), ("º", "spanish-iso")] {
            let samples = try Self.samples(text, layout)
            #expect(samples.contains { $0.usage == (text == "º" ? 100 : 226) })
            #expect(samples.withUnsafeBufferPointer {
                ADCRunKeyboardSchedule($0.baseAddress, $0.count, { 1 }, { _, _ in Issue.record("Stopped schedule sent a key") })
            } == 1)
        }
    }

    @Test func layoutsMapTheirOwnKeys() throws {
        typealias Stroke = KeyboardLayout.Stroke
        // German QWERTZ: Y and Z swap, ß sits on the US minus key, ö on the semicolon key.
        #expect(try Self.strokes("z", "german") == [Stroke(usage: 28)] && Self.strokes("y", "german") == [Stroke(usage: 29)])
        #expect(try Self.strokes("ß", "german") == [Stroke(usage: 45)] && Self.strokes("ö", "german") == [Stroke(usage: 51)])
        #expect(try Self.strokes("Ö", "german") == [Stroke(usage: 51, shift: true)])
        #expect(try Self.strokes("@", "german") == [Stroke(usage: 15, option: true)])
        // Spanish – ISO: ñ on the semicolon key; < on HID 53 and º on 100, as
        // the iOS runtime's file has them and the simulator typed them.
        #expect(try Self.strokes("ñ", "spanish-iso") == [Stroke(usage: 51)])
        #expect(try Self.strokes("<", "spanish-iso") == [Stroke(usage: 53)] && Self.strokes("º", "spanish-iso") == [Stroke(usage: 100)])
        // Latin American is one of the layouts whose ISO and ANSI tables differ on
        // HID 53 and 100; the simulator typed the ISO ones (< on 53, | on 100).
        #expect(try Self.strokes("<", "latin-american") == [Stroke(usage: 53)] && Self.strokes("|", "latin-american") == [Stroke(usage: 100)])
        #expect(KeyboardLayout.keyboardType == 41)
        // French AZERTY: a is on the US Q key.
        #expect(try Self.strokes("a", "french") == [Stroke(usage: 20)])
        // Option characters in US.
        #expect(try Self.strokes("ß", "us") == [Stroke(usage: 22, option: true)])
    }

    @Test func deadKeysComposeAndCheckTheirOwnOutput() throws {
        typealias Stroke = KeyboardLayout.Stroke
        // US: Option+E is the acute dead key.
        #expect(try Self.strokes("é", "us") == [Stroke(usage: 8, option: true), Stroke(usage: 8)])
        #expect(try Self.strokes("É", "us") == [Stroke(usage: 8, option: true), Stroke(usage: 8, shift: true)])
        // Spanish – ISO: the acute key right of ñ, then the letter.
        #expect(try Self.strokes("á", "spanish-iso") == [Stroke(usage: 52), Stroke(usage: 4)])
        #expect(try Self.samples("á", "spanish-iso").map(\.usage) == [52, 52, 4, 4])
        // German: the circumflex dead key left of 1 (HID 53), then the letter.
        #expect(try Self.strokes("ê", "german").count == 2)
        // A decomposed character asks for the same strokes as its precomposed form.
        #expect(try Self.samples("e\u{301}", "us").map(\.usage) == Self.samples("é", "us").map(\.usage))
        // Text mixing dead keys, Shift and Option types character by character.
        let mixed = try Self.samples("Ñandú ¿Qué? €5 «ü»", "spanish-iso")
        #expect(mixed.count > 0 && mixed.count <= KeyboardLayout.sampleLimit)
    }

    @Test func buildsTablesFromAnyTranslator() {
        // A two-key fake layout: code 0 types "a" ("A" with Shift); code 14 with
        // Option is a dead key (state 7) that makes 0 into "á" and 49 (space) into "´".
        let table = KeyboardLayout.table { code, modifiers, state in
            defer { if state != 7 { state = 0 } }
            if state == 7 {
                state = 0
                return code == 0 ? "á" : code == 49 ? "´" : "´?"
            }
            switch (code, modifiers) {
            case (0, 0): return "a"
            case (0, 2): return "A"
            case (14, 8): state = 7; return ""
            case (49, _): return " "
            case (24, 0): return "\u{1b}"
            default: return ""
            }
        }
        typealias Stroke = KeyboardLayout.Stroke
        #expect(table["a"] == [Stroke(usage: 4)] && table["A"] == [Stroke(usage: 4, shift: true)])
        #expect(table["á"] == [Stroke(usage: 8, option: true), Stroke(usage: 4)])
        #expect(table["´"] == [Stroke(usage: 8, option: true), Stroke(usage: 44)])
        // Space wins over Shift/Option spaces; control output and two-character output are not typeable.
        #expect(table[" "] == [Stroke(usage: 44)] && table["\u{1b}"] == nil && table.count == 5)
    }

    @Test func namesMatchIgnoringCaseAndPunctuation() throws {
        #expect(KeyboardLayout.slug("com.apple.keylayout.US") == "us")
        #expect(KeyboardLayout.slug("com.apple.keylayout.Spanish-ISO") == "spanish-iso")
        #expect(KeyboardLayout.slug("com.apple.keylayout.USInternational-PC") == "us-international-pc")
        #expect(KeyboardLayout.slug("com.apple.keylayout.SwissFrench") == "swiss-french")
        #expect(KeyboardLayout.slug("com.apple.keylayout.German-DIN-2137") == "german-din-2137")
        let sources = KeyboardLayout.available()
        #expect(sources.count > 100 && sources.map(\.name) == sources.map(\.name).sorted())
        for name in ["Spanish - ISO", "spanish-iso", "SPANISHISO", "com.apple.keylayout.Spanish-ISO"] {
            #expect(KeyboardLayout.match(name, in: sources)?.identifier == "com.apple.keylayout.Spanish-ISO", "\(name)")
        }
        #expect(KeyboardLayout.match("spanish", in: sources)?.identifier == "com.apple.keylayout.Spanish")
        #expect(KeyboardLayout.match("", in: sources) == nil && KeyboardLayout.match("klingon", in: sources) == nil)
    }

    @Test func refusesNamingTheFirstCharacterAndSetValue() throws {
        let failure = try #require(throws: CommandFailure.self) { try Self.samples("año → mañana", "spanish-iso") }
        #expect(failure.code == .usage && failure.inputSent == .none)
        #expect(failure.description.hasPrefix("The spanish-iso keyboard layout cannot type '→' (U+2192), character 5 of the text"))
        #expect(failure.description.contains("set-value"))
        let control = try #require(throws: CommandFailure.self) { try Self.samples("a\rb") }
        #expect(control.description.contains("cannot type (U+000D), character 2"))
        let empty = try #require(throws: CommandFailure.self) { try Self.samples("") }
        #expect(empty.description == "Typing requires 1...512 characters; no input sent.")
        // 512 dead-key characters are within the character limit but need 3072 events.
        let long = try #require(throws: CommandFailure.self) { try Self.samples(String(repeating: "é", count: 512)) }
        #expect(long.description.hasPrefix("Typing this text in the us layout needs 3072 keyboard events; at most 2048"))
        let unknown = try #require(throws: CommandFailure.self) { try KeyboardLayout.named("klingon") }
        #expect(unknown.description == "Unknown keyboard layout 'klingon'. List the available names with `manzanero keyboard-layouts`; no input sent.")
    }

    @Test(arguments: ["", "→", "😀", "a\0b", "a\rb"])
    func invalidTextNeverQueriesOrSends(_ text: String) {
        let input = CoreDeviceInput(device: "fixture", operation: "type", operands: [text])
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTyping.execute(input, query: { _ in Issue.record("Invalid text queried"); return Data() },
                send: { _ in Issue.record("Invalid text sent") })
        }
    }

    @Test func validatesBeforeOneDispatchAndDoesNotEchoTextOrReplay() throws {
        let input = CoreDeviceInput(device: CoreDeviceInputTests().udid, operation: "type", operands: ["synthetic"])
        var queries = 0, sends = 0
        let query: (DeviceCommand) throws -> Data = { _ in queries += 1; return try DirectPhysicalInputTests().details() }
        let output = try DirectPhysicalTyping.execute(input, query: query, send: { sequence in
            sends += 1
            #expect(queries == 1 && sequence.uuid == CoreDeviceInputTests().uuid && sequence.version == "651.32")
            #expect(sequence.samples.count == 18)
        })
        #expect(sends == 1)
        let receipt = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(receipt["layout"] as? String == "us" && receipt["characterCount"] as? Int == 9)
        #expect(receipt["layoutIdentifier"] as? String == "com.apple.keylayout.US")
        #expect((receipt["deviceLayout"] as? [String: Any])?["status"] as? String == "not-read")
        #expect(receipt["insertionVerified"] as? Bool == false && receipt["releaseVerified"] as? Bool == false)
        #expect(String(decoding: output, as: UTF8.self).contains("synthetic") == false)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTyping.execute(input, query: query, send: { _ in sends += 1; throw CommandFailure(description: "fixture") })
        }
        #expect(sends == 2)
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalTyping.execute(input, query: { _ in try DirectPhysicalInputTests().details(mode: "disabled") },
                send: { _ in Issue.record("Disabled device sent text") })
        }
        // A non-US layout: the German schedule for "zß" and its receipt.
        let german = CoreDeviceInput(device: CoreDeviceInputTests().udid, operation: "type", operands: ["zß", "german"])
        let germanOutput = try DirectPhysicalTyping.execute(german, query: query, send: { sequence in
            #expect(sequence.samples.map(\.usage) == [28, 28, 45, 45])
        })
        let germanReceipt = try #require(try JSONSerialization.jsonObject(with: germanOutput) as? [String: Any])
        #expect(germanReceipt["layout"] as? String == "german" && germanReceipt["characterCount"] as? Int == 2)
    }

    @Test func mcpAndExplicitDefaultDryRunsDoNotQueryOrExposeText() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "type_text" })
        let args = try tool.command(["platform": "physical", "device": .string(CoreDeviceInputTests().udid), "text": "synthetic"])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried"); return Data() })
        // The MCP form and the CLI spelling of the same command.
        for arguments in [args, ["type", "synthetic", "--device", CoreDeviceInputTests().udid]] {
            let output = try await service.run(arguments, dryRun: true)
            let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["backend"] as? String == "coredevice-direct" && plan["operation"] as? String == "type")
            #expect(plan["layout"] as? String == "us" && plan["sampleCount"] as? Int == 18)
            #expect((plan["deviceLayoutCheck"] as? [String: Any])?["status"] as? String == "not-read")
            #expect(plan["clipboardArguments"] == nil && plan["executable"] == nil)
            #expect(String(decoding: output.data, as: UTF8.self).contains("synthetic") == false)
        }
        // The MCP layout field reaches the same validation.
        let spanish = try tool.command(["device": .string(CoreDeviceInputTests().udid), "text": "año", "layout": "Spanish - ISO"])
        #expect(spanish.contains("--layout=Spanish - ISO"))
        let plan = try #require(try JSONSerialization.jsonObject(with: await service.run(spanish, dryRun: true).data) as? [String: Any])
        #expect(plan["layout"] as? String == "spanish-iso" && plan["characterCount"] as? Int == 3)
        let refused = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await service.run(try tool.command(["device": .string(CoreDeviceInputTests().udid), "text": "año ж"]), dryRun: true)
        })
        #expect(refused.description.hasPrefix("The us keyboard layout cannot type 'ж'"))
        let list = try #require(MCPTools.definitions.first { $0.name == "list_keyboard_layouts" })
        #expect(try list.command([:]) == ["keyboard-layouts"] && list.readOnly)
    }

    @Test func listsLayoutsWithoutADevice() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Listing queried a device"); return Data() })
        let output = try await service.execute(.keyboardLayouts)
        let list = try #require(try JSONSerialization.jsonObject(with: output.data) as? [[String: String]])
        #expect(list.contains { $0["name"] == "spanish-iso" && $0["identifier"] == "com.apple.keylayout.Spanish-ISO" })
        #expect(list.contains { $0["name"] == "us" } && list.allSatisfy { $0["localizedName"]?.isEmpty == false })
        await #expect(throws: CommandFailure.self) { _ = try await service.execute(.keyboardLayouts, dryRun: true) }
    }

    @Test func simulatorLayoutCheckParsesTheInputMode() throws {
        #expect(DeviceKeyboardLayout.hardwareLayout("es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO") == "Spanish - ISO")
        #expect(DeviceKeyboardLayout.hardwareLayout("es_419@sw=QWERTY-Spanish;hw=Automatic;ml=120") == "Automatic")
        #expect(DeviceKeyboardLayout.hardwareLayout("emoji@sw=Emoji") == nil && DeviceKeyboardLayout.hardwareLayout("en_US") == nil)
        let only = try PropertyListSerialization.data(fromPropertyList: ["KeyboardsCurrentAndNext": ["fr_FR@sw=AZERTY;hw=French"]], format: .xml, options: 0)
        #expect(DeviceKeyboardLayout.inputMode(only) == "fr_FR@sw=AZERTY;hw=French")
        #expect(DeviceKeyboardLayout.inputMode(Data("not a plist".utf8)) == nil)
        let french = try KeyboardLayout.named("french")
        let matched = try DeviceKeyboardLayout.simulator(.success(only), layout: french, sources: KeyboardLayout.available())
        #expect(matched["status"] as? String == "matches")
        let failure = try #require(throws: CommandFailure.self) {
            try DeviceKeyboardLayout.simulator(.success(only), layout: try KeyboardLayout.named("us"), sources: KeyboardLayout.available())
        }
        #expect(failure.code == .usage && failure.inputSent == .none && failure.description.contains("--layout french"))
        let unknown = try PropertyListSerialization.data(fromPropertyList: ["KeyboardLastUsed": "xx@hw=Martian"], format: .xml, options: 0)
        let unmatched = try DeviceKeyboardLayout.simulator(.success(unknown), layout: french, sources: KeyboardLayout.available())
        #expect(unmatched["status"] as? String == "not-checked" && unmatched["deviceLayout"] as? String == "Martian")
        let empty = try DeviceKeyboardLayout.simulator(.success(Data()), layout: french, sources: [])
        #expect(empty["status"] as? String == "not-checked")
    }
}
