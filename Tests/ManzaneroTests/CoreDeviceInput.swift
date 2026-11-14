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

    @Test func validatesBeforeNativeDispatchAndPlansUnquantizedCoordinates() throws {
        let tap = try input(["tap", "0.25", "0.75"])
        let plan = try tap.actionPlan(uuid, surface: "257")
        #expect(plan.executable == "/usr/bin/env")
        #expect(plan.arguments.suffix(4) == ["cd_uhid_tap", "257", "0.25", "0.75"])
        let drag = try input(["drag", "0", "1", "1", "0", "0.5"])
        #expect(try drag.actionPlan(uuid, surface: "257").arguments.suffix(7) == ["cd_uhid_swipe", "257", "0", "1", "1", "0", "0.5"])
        let lock = try input(["button", "lock"])
        #expect(try lock.actionPlan(uuid, surface: nil).arguments.suffix(4) == ["cd_button_click", "12", "48", "0.4"])
        #expect(try input(["type", "text"]).operation == "type")
        for op in [["tap", "nan", "0"], ["tap", "1.1", "0"], ["drag", "0", "0", "1", "1", "0"], ["type", "é"], ["button", "unknown"]] {
            #expect(throws: CommandFailure.self) { try input(op) }
        }
    }

    @Test func rejectsAmbiguousDescriptorsAndMismatchedIdentity() throws {
        let line = "connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"\n"
        #expect(try CoreDeviceInput.touchscreen(Data(line.utf8)) == "257")
        for value in ["", line + line, line.replacingOccurrences(of: "0x101", with: "0x0"), line.replacingOccurrences(of: "0x101", with: "0xNOTHEX"), line.replacingOccurrences(of: "0x101", with: "0x101ZZ")] {
            #expect(throws: CommandFailure.self) { try CoreDeviceInput.touchscreen(Data(value.utf8)) }
        }
        #expect(try CoreDeviceInput.resolve(details(), requested: udid) == uuid)
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.resolve(details(), requested: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") }
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.resolve(details(hardware: "different"), requested: udid) }
    }

    @Test func disabledModeStopsBeforeHelperAndFailureIsNeverRetried() throws {
        let tap = try input(["tap", "0.5", "0.5"])
        var calls = 0
        #expect(throws: CommandFailure.self) {
            try tap.execute { _ in
                calls += 1
                #expect(calls == 1)
                return try details(mode: "disabled")
            }
        }
        #expect(calls == 1)
        calls = 0
        #expect(throws: CommandFailure.self) {
            try tap.execute { plan in
                calls += 1
                if calls == 1 { return try details() }
                if calls == 2 { return Data("connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"".utf8) }
                #expect(plan.arguments.contains("cd_uhid_tap"))
                throw CommandFailure(description: "synthetic action failure")
            }
        }
        #expect(calls == 3)
    }

    @Test func successfulDispatchKeepsUnverifiedReceiptAndMCPBackendRouting() async throws {
        let button = try input(["button", "home"])
        let output = try button.execute { plan in
            if plan.arguments.contains("details") { return try details() }
            #expect(plan.arguments.suffix(4) == ["cd_button_click", "12", "64", "0.08"])
            return Data()
        }
        let result = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-ipb")
        #expect(result["verified"] as? Bool == false)
        let tool = try #require(MCPTools.definitions.first { $0.name == "tap" })
        let args = try tool.command(["platform": "physical", "device": .string(udid), "x": 0.25, "y": 0.75, "backend": "coredevice"])
        #expect(try CoreDeviceInput.parse(args)?.operands == ["0.25", "0.75"])
        let dry = try await CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() }).execute(args, dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("coredevice-direct"))
    }

    @Test func nativeHelperTimeoutReturnsAnErrorInsteadOfSuccess() throws {
        let start = ContinuousClock.now
        #expect(throws: CommandFailure.self) { try ToolRunner().run(["10"], executable: "/bin/sleep", timeout: 0.05) }
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(try ToolRunner().run([], executable: "/usr/bin/true", timeout: 1).isEmpty)
    }

    @Test func nativeKeyboardDiscoveryAndKeyPlan() throws {
        let descriptors = Data("connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"\nconnectedDescriptor[1] serviceID:0x200 string:\"CoreDevice keyboard\"".utf8)
        #expect(try CoreDeviceInput.surface(descriptors, role: .keyboard) == "512")
        let key = try input(["key", "backspace"])
        #expect(try key.actionPlan(uuid, surface: "512").arguments.suffix(4) == ["cd_key", "512", "42", "0.08"])
        #expect(throws: CommandFailure.self) { try input(["key", "unknown"]) }
        #expect(throws: CommandFailure.self) { try CoreDeviceInput.surface(Data("connectedDescriptor[0] serviceID:0x101 string:\"CoreDevice touchscreen(nil)\"".utf8), role: .keyboard) }
    }

    @Test func unicodePastePreservesLiteralUTF8AndOrdersDiscoveryCopyThenOnePaste() throws {
        let text = "--literal 'ñ' 🙂 中文; $(touch sentinel)\n"
        let paste = try input(["paste", text])
        var phases: [String] = []
        let output = try paste.execute(copy: { plan, bytes in
            phases.append("copy")
            #expect(plan.arguments.prefix(4) == ["devicectl", "device", "pasteboard", "copy"])
            #expect(!plan.arguments.contains(text))
            #expect(bytes == Data(text.utf8))
            return Data("{\"info\":{\"outcome\":\"success\"}}".utf8)
        }) { plan in
            if plan.arguments.contains("details") { phases.append("identity"); return try details() }
            if plan.arguments.contains("cd_connected_descriptors_async_raw") {
                phases.append("discover")
                return Data("connectedDescriptor[1] serviceID:0x200 string:\"CoreDevice keyboard\"".utf8)
            }
            phases.append("paste")
            #expect(plan.arguments.suffix(2) == ["cd_paste", "512"])
            return Data()
        }
        #expect(phases == ["identity", "discover", "copy", "paste"])
        let result = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["clipboard"] as? String == "replaced")
        #expect(result["insertionVerified"] as? Bool == false)
        #expect(!String(decoding: output, as: UTF8.self).contains(text))
    }

    @Test func pasteFailuresDoNotRetryOrHidePartialClipboardEffects() throws {
        for failure in ["disabled", "discovery", "copy", "copy-reply", "paste"] {
            let paste = try input(["paste", "é🙂"])
            var copies = 0, pastes = 0
            do {
                _ = try paste.execute(copy: { _, _ in
                    copies += 1
                    if failure == "copy" { throw CommandFailure(description: "fixture copy failed") }
                    return Data((failure == "copy-reply" ? "{}" : "{\"info\":{\"outcome\":\"success\"}}").utf8)
                }) { plan in
                    if plan.arguments.contains("details") { return try details(mode: failure == "disabled" ? "disabled" : "enabled") }
                    if plan.arguments.contains("cd_connected_descriptors_async_raw") {
                        if failure == "discovery" { return Data() }
                        return Data("connectedDescriptor[1] serviceID:0x200 string:\"CoreDevice keyboard\"".utf8)
                    }
                    pastes += 1
                    throw CommandFailure(description: "fixture paste failed")
                }
                Issue.record("Expected paste failure")
            } catch {
                if failure == "paste" { #expect(String(describing: error).contains("Clipboard was replaced")) }
                if failure.hasPrefix("copy") { #expect(String(describing: error).contains("Paste was not sent")) }
            }
            #expect(copies == (["disabled", "discovery"].contains(failure) ? 0 : 1))
            #expect(pastes == (failure == "paste" ? 1 : 0))
        }
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
        #expect(try CoreDeviceInput.parse(key.command(["device": .string(udid), "key": "backspace", "backend": "coredevice"]))?.operation == "key")
    }

    @Test func subprocessStdinPreservesBinaryAndUnicodeBytesWithoutShellEvaluation() throws {
        let bytes = Data("\0ñ🙂 '$(touch sentinel)'\n\t".utf8)
        #expect(try ToolRunner().run([], executable: "/bin/cat", timeout: 1, inputData: bytes) == bytes)
        #expect(throws: CommandFailure.self) { try ToolRunner().run([], executable: "/bin/cat", interactive: true, inputData: bytes) }
    }
}
