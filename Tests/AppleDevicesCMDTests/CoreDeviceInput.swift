import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

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
        let plan = try tap.actionPlan(uuid, touchscreen: "257")
        #expect(plan.executable == "/usr/bin/env")
        #expect(plan.arguments.suffix(4) == ["cd_uhid_tap", "257", "0.25", "0.75"])
        let drag = try input(["drag", "0", "1", "1", "0", "0.5"])
        #expect(try drag.actionPlan(uuid, touchscreen: "257").arguments.suffix(7) == ["cd_uhid_swipe", "257", "0", "1", "1", "0", "0.5"])
        let lock = try input(["button", "lock"])
        #expect(try lock.actionPlan(uuid, touchscreen: nil).arguments.suffix(4) == ["cd_button_click", "12", "48", "0.4"])
        for op in [["tap", "nan", "0"], ["tap", "1.1", "0"], ["drag", "0", "0", "1", "1", "0"], ["type", "text"], ["button", "unknown"]] {
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
        #expect(String(decoding: dry.data, as: UTF8.self).contains("coredevice-ipb"))
    }

    @Test func nativeHelperTimeoutReturnsAnErrorInsteadOfSuccess() throws {
        let start = ContinuousClock.now
        #expect(throws: CommandFailure.self) { try ToolRunner().run(["10"], executable: "/bin/sleep", timeout: 0.05) }
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(try ToolRunner().run([], executable: "/usr/bin/true", timeout: 1).isEmpty)
    }
}
