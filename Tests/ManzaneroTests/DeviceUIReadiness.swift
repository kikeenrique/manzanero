import Foundation
import Testing
@testable import Manzanero

struct DeviceUIReadinessTests {
    func response(_ query: String, power: Any = "activeOn", passcode: Any = false, sinceBoot: Any = true,
                  identity: String? = nil, primary: Any = true, duplicate: Bool = false) throws -> Data {
        let display: [String: Any] = ["primary": primary, "backlightState": power]
        let result: [String: Any] = query == "displays" ? ["displays": duplicate ? [display, display] : [display]] : [
            "deviceIdentifier": identity ?? CoreDeviceInputTests().uuid, "passcodeRequired": passcode, "unlockedSinceBoot": sinceBoot]
        return try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": result])
    }

    /// An input receipt says whether the device was locked afterwards, and a
    /// failed or doubtful read leaves it unknown instead of failing the input.
    @Test func inputReceiptsCarryThePasscodeStateReadAfterwards() throws {
        let uuid = CoreDeviceInputTests().uuid
        let receipt = try JSONSerialization.data(withJSONObject: ["operation": "tap", "status": "dispatched"])
        func annotated(_ query: @escaping (DeviceCommand) throws -> Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: DeviceUIReadiness.annotateInput(receipt, uuid: uuid, query: query)) as? [String: Any])
        }
        let locked = try annotated { plan in
            #expect(plan.arguments == ["devicectl", "device", "info", "lockState", "--device", uuid, "--timeout", "10", "--quiet", "--json-output", "-"])
            return try response("lockState", passcode: true)
        }
        #expect(locked["passcodeRequired"] as? Bool == true && locked["lockNote"] as? String == DeviceUIReadiness.lockNote)
        #expect(locked["status"] as? String == "dispatched")
        let unlocked = try annotated { _ in try response("lockState") }
        #expect(unlocked["passcodeRequired"] as? Bool == false && unlocked["lockNote"] == nil)
        // Unknown, never guessed: a failed query, another device's answer, a number instead of a Boolean.
        for query: (DeviceCommand) throws -> Data in [{ _ in throw CommandFailure(description: "offline") },
                                                       { _ in try response("lockState", passcode: true, identity: UUID().uuidString) },
                                                       { _ in try response("lockState", passcode: 1) }] {
            let unknown = try annotated(query)
            #expect(unknown["passcodeRequired"] is NSNull && unknown["lockNote"] == nil && unknown["status"] as? String == "dispatched")
        }
        // A receipt that already reports the state (wake) is left as it is.
        let own = try JSONSerialization.data(withJSONObject: ["operation": "wake", "passcodeRequired": false])
        #expect(DeviceUIReadiness.annotateInput(own, uuid: uuid) { _ in Issue.record("Queried"); return Data() } == own)
    }

    /// A sleeping phone answers a screenshot with a black image and no
    /// error; the receipt says the display was off.
    @Test func screenshotReceiptsSayWhenTheDisplayWasOff() throws {
        let udid = CoreDeviceInputTests().udid
        let receipt = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["path": "a.png"]])
        func annotated(_ query: @escaping (DeviceCommand) throws -> Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: DeviceUIReadiness.annotateScreenshot(receipt, device: udid, query: query)) as? [String: Any])
        }
        let off = try annotated { plan in
            #expect(plan.arguments == ["devicectl", "device", "info", "displays", "--device", udid, "--timeout", "10", "--quiet", "--json-output", "-"])
            return try response("displays", power: "off")
        }
        #expect(off["displayPower"] as? String == "off" && off["displayNote"] as? String == DeviceUIReadiness.displayOffNote)
        #expect((off["result"] as? [String: String]) == ["path": "a.png"])
        let on = try annotated { _ in try response("displays") }
        #expect(on["displayPower"] as? String == "on" && on["displayNote"] == nil)
        // Unknown, never guessed, and never a failed screenshot.
        for query: (DeviceCommand) throws -> Data in [{ _ in throw CommandFailure(description: "offline") },
                                                       { _ in try response("displays", duplicate: true) },
                                                       { _ in try response("displays", power: "dimmed") }] {
            let unknown = try annotated(query)
            #expect(unknown["displayPower"] as? String == "unknown" && unknown["displayNote"] == nil)
        }
    }

    @Test func observesPowerAndPasscodeWithoutClaimingCurrentUIUnlock() throws {
        let fixture = CoreDeviceInputTests()
        for power in ["activeOn", "off"] {
            let report = try DeviceUIReadiness.observe(details: fixture.details(), device: fixture.udid) { plan in
                #expect(plan.arguments.contains(fixture.uuid))
                #expect(plan.arguments.suffix(5) == ["--timeout", "10", "--quiet", "--json-output", "-"])
                return try response(plan.arguments[3], power: power)
            }
            #expect(report.displayPower == (power == "off" ? "off" : "on"))
            #expect(report.passcodeRequired == false && report.unlockedSinceBoot == true)
            #expect(report.status == (power == "off" ? "needsUserAction" : "observed"))
            #expect(report.actions.isEmpty == (power != "off"))
            #expect(report.limitations.contains { $0.contains("do not prove") })
        }
        let needsPasscode = try DeviceUIReadiness.observe(details: fixture.details(), device: fixture.udid) {
            try response($0.arguments[3], passcode: true, sinceBoot: false)
        }
        #expect(needsPasscode.status == "needsUserAction")
        #expect(needsPasscode.actions.contains { $0.contains("Unlock") })
    }

    @Test(arguments: ["numeric-booleans", "wrong-device", "ambiguous-display", "numeric-primary", "oversized", "query-failure"])
    func malformedObservationsRemainUnknown(_ mutation: String) throws {
        let fixture = CoreDeviceInputTests()
        let report = try DeviceUIReadiness.observe(details: fixture.details(), device: fixture.udid) { plan in
            switch mutation {
            case "query-failure": throw CommandFailure(description: "private diagnostic must not be copied into report")
            case "oversized": return Data(count: 1_048_577)
            default:
                return try response(plan.arguments[3],
                    passcode: mutation == "numeric-booleans" ? 0 : false,
                    sinceBoot: mutation == "numeric-booleans" ? 1 : true,
                    identity: mutation == "wrong-device" ? "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" : nil,
                    primary: mutation == "numeric-primary" ? 1 : true,
                    duplicate: mutation == "ambiguous-display")
            }
        }
        #expect(report.status == "unknown")
        #expect(!report.diagnostics.isEmpty)
        #expect(!report.diagnostics.joined().contains("private diagnostic"))
        if ["numeric-booleans", "wrong-device", "oversized", "query-failure"].contains(mutation) {
            #expect(report.passcodeRequired == nil && report.unlockedSinceBoot == nil)
        }
    }

    @Test func unresolvedIdentityAndCancellationDoNotQuery() throws {
        let report = try DeviceUIReadiness.observe(details: Data("{}".utf8), device: "fixture") { _ in
            Issue.record("UI query without identity"); return Data()
        }
        #expect(report.status == "unknown")
        #expect(report.diagnostics.first?.contains("deviceIdentityUnavailable") == true)
        #expect(throws: CancellationError.self) {
            try DeviceUIReadiness.observe(details: CoreDeviceInputTests().details(), device: CoreDeviceInputTests().udid) { _ in throw CancellationError() }
        }
    }

    @Test func explicitReadinessIncludesUIAndDryRunNeverQueries() async throws {
        let fixture = CoreDeviceInputTests(), details = try fixture.details()
        let service = CommandService(readinessQuery: { _ in details }, uiReadinessQuery: { plan in
            #expect(plan.arguments[3] == "displays" || plan.arguments[3] == "lockState")
            return try response(plan.arguments[3], power: "off")
        })
        let output = try await service.run(["readiness", "--device", fixture.udid])
        let value = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        let ui = try #require(value["ui"] as? [String: Any])
        #expect(ui["displayPower"] as? String == "off")
        #expect(ui["status"] as? String == "needsUserAction")
        let dryService = CommandService(readinessQuery: { _ in Issue.record("Dry run queried details"); return Data() },
            uiReadinessQuery: { _ in Issue.record("Dry run queried UI state"); return Data() })
        let dry = try await dryService.run(["readiness", "--device", fixture.udid], dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("lockState"))
    }
}
