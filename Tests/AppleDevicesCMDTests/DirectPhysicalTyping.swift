import AppleDeviceBridge
import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct DirectPhysicalTypingTests {
    @Test func mapsEntirePrintableUSLayoutAndControlKeys() throws {
        // Independent expected HID order: letters, digits and punctuation.
        let groups: [(String, [UInt64], Bool)] = [
            ("abcdefghijklmnopqrstuvwxyz", Array(4...29), false),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZ", Array(4...29), true),
            ("1234567890", Array(30...39), false), ("!@#$%^&*()", Array(30...39), true),
            ("-=[]\\;'`,./", [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56], false),
            ("_+{}|:\"~<>?", [45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56], true),
            (" \t\n", [44, 43, 40], false)]
        for (text, codes, shifted) in groups {
            for (byte, code) in zip(text.utf8, codes) {
                #expect(DirectPhysicalTyping.stroke(byte) == .init(usage: code, shift: shifted))
            }
        }
        for byte in UInt8.min...UInt8.max where !(32...126).contains(byte) && byte != 9 && byte != 10 {
            #expect(DirectPhysicalTyping.stroke(byte) == nil)
        }
    }

    @Test func releasesShiftBetweenCharactersAndBoundsWorstCaseSchedule() throws {
        let schedule = try DirectPhysicalTyping.samples("Aa!")
        #expect(schedule.map(\.usage) == [225, 4, 4, 225, 4, 4, 225, 30, 30, 225])
        #expect(schedule.map(\.state) == [1, 1, 2, 2, 1, 2, 1, 1, 2, 2])
        #expect(schedule.map(\.nanoseconds) == (0..<10).map { UInt64($0) * 10_000_000 })
        let maximum = try DirectPhysicalTyping.samples(String(repeating: "A", count: 512))
        #expect(maximum.count == 2048)
        #expect(maximum.last?.nanoseconds == 20_470_000_000)
        var pressed: Set<UInt64> = []
        for sample in maximum {
            if sample.state == 1 { #expect(pressed.insert(sample.usage).inserted) }
            else { #expect(pressed.remove(sample.usage) != nil) }
        }
        #expect(pressed.isEmpty)
    }

    @Test(arguments: ["", "é", "😀", "a\0b", "a\rb"])
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
        #expect(receipt["layout"] as? String == "US" && receipt["characterCount"] as? Int == 9)
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
        #expect(throws: CommandFailure.self) { try DirectPhysicalTyping.samples(String(repeating: "a", count: 513)) }
    }

    @Test func mcpAndExplicitDefaultDryRunsDoNotQueryOrExposeText() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "type_text" })
        let args = try tool.command(["platform": "physical", "device": .string(CoreDeviceInputTests().udid), "text": "synthetic"])
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried"); return Data() })
        for prefix in [[], ["--physical-backend", "coredevice"]] {
            let output = try await service.execute(prefix + args, dryRun: true)
            let plan = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
            #expect(plan["backend"] as? String == "coredevice-direct" && plan["operation"] as? String == "type")
            #expect(plan["clipboardArguments"] == nil && plan["executable"] == nil)
            #expect(String(decoding: output.data, as: UTF8.self).contains("synthetic") == false)
        }
    }
}
