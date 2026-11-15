import Foundation
import MCP
import Testing
@testable import Manzanero

struct CoreDeviceInputTests {
    let uuid = "11111111-2222-3333-4444-555555555555"
    let udid = "00000000-0000000000000000"
    func input(_ values: [String]) throws -> CoreDeviceInput {
        try #require(try CoreDeviceInput.parse(["--physical-backend", "coredevice", "physical", udid] + values))
    }
    func details(mode: String = "enabled", id: String? = nil, hardware: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["identifier": id ?? uuid,
            "properties": ["hardware": ["udid": hardware ?? udid], "state": ["developerModeStatus": [mode: [:]]]],
            "deviceProperties": ["ddiServicesAvailable": true]]])
    }

    @Test func validatesBeforeNativeDispatchAndKeepsUnquantizedCoordinates() throws {
        #expect(try input(["tap", "0.25", "0.75"]).operands == ["0.25", "0.75"])
        #expect(try input(["drag", "0", "1", "1", "0", "0.5"]).operands == ["0", "1", "1", "0", "0.5"])
        #expect(try input(["button", "lock"]).operands == ["lock"])
        #expect(try input(["type", "text"]).operation == "type")
        for op in [["tap", "nan", "0"], ["tap", "1.1", "0"], ["drag", "0", "0", "1", "1", "0"], ["type", "é"], ["button", "unknown"]] {
            #expect(throws: CommandFailure.self) { try input(op) }
        }
    }

    @Test func rejectsMismatchedIdentity() throws {
        #expect(try CoreDeviceInput.resolve(details(), requested: udid) == uuid)
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.resolve(details(), requested: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") }
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.resolve(details(hardware: "different"), requested: udid) }
    }

    @Test func mcpTapRoutesToTheDirectBackend() async throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let args = try tool.command(["platform": "physical", "device": .string(udid), "x": 0.25, "y": 0.75])
        #expect(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args))?.operands == ["0.25", "0.75"])
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("coredevice-direct"))
    }

    // The elapsed bound is the subject (the runner must stop the child), and
    // ToolRunner blocks while it waits, so it runs on a thread of its own.
    @Test(.dedicatedThread) func nativeHelperTimeoutReturnsAnErrorInsteadOfSuccess() throws {
        let start = ContinuousClock.now
        #expect(throws: CommandFailure.self) { try ToolRunner().run(["10"], executable: "/bin/sleep", timeout: 0.05) }
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(try ToolRunner().run([], executable: "/usr/bin/true", timeout: 1).isEmpty)
    }

    @Test func namedKeysAreValidated() throws {
        #expect(try input(["key", "backspace"]).operands == ["backspace"])
        #expect(throws: CommandFailure.self) { try input(["key", "unknown"]) }
    }

    @Test func pasteBoundsAndMCPRoutingKeepExplicitClipboardSemantics() async throws {
        for text in ["", "a\0b", String(repeating: "x", count: 65537)] {
            #expect(throws: CommandFailure.self) { try input(["paste", text]) }
        }
        #expect(try input(["paste", String(repeating: "🙂", count: 16384)]).operands[0].utf8.count == 65536)
        #expect(throws: CommandFailure.self) { try input(["paste", String(repeating: "🙂", count: 16385)]) }
        let tool = try #require(MCPTools.definitions.first { $0.name == "paste_text" })
        let text = "ñ🙂"
        let args = try tool.command(["device": .string(udid), "text": .string(text)])
        #expect(try CoreDeviceInput.parse(args)?.operands == [text])
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        let result = try #require(try JSONSerialization.jsonObject(with: dry.data) as? [String: Any])
        #expect(result["stdinUTF8Bytes"] as? Int == text.utf8.count)
        #expect(result["clipboardArguments"] != nil)
        #expect((result["clipboardEffect"] as? String)?.contains("not restored") == true)
        let key = try #require(MCPTools.definitions.first { $0.name == "press_key" })
        #expect(try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(key.command(["device": .string(udid), "key": "backspace"])))?.operation == "key")
    }

    @Test(.dedicatedThread) func subprocessStdinPreservesBinaryAndUnicodeBytesWithoutShellEvaluation() throws {
        let bytes = Data("\0ñ🙂 '$(touch sentinel)'\n\t".utf8)
        #expect(try ToolRunner().run([], executable: "/bin/cat", timeout: 1, inputData: bytes) == bytes)
    }
}
