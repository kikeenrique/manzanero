import Foundation
import Testing
@testable import Manzanero

struct DirectPhysicalInputTests {
    func details(version: String? = "651.32", mode: String = "enabled", hardware: String? = nil) throws -> Data {
        let fixture = CoreDeviceInputTests()
        var root = try #require(try JSONSerialization.jsonObject(with: fixture.details(mode: mode, hardware: hardware)) as? [String: Any])
        var info = try #require(root["info"] as? [String: Any])
        info["version"] = version
        root["info"] = info
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test func exactIdentityVersionAndButtonPlanPrecedeOneDirectDispatch() throws {
        let input = try CoreDeviceInputTests().input(["button", "home"])
        var queries = 0, dispatches = 0
        let bytes = try DirectPhysicalInput.execute(input, query: { plan in
            queries += 1
            #expect(plan.executable == "/usr/bin/xcrun")
            #expect(plan.arguments.contains("details"))
            return try details()
        }, send: { button in
            dispatches += 1
            #expect(button == .init(uuid: CoreDeviceInputTests().uuid, version: "651.32", usage: 64, holdMicroseconds: 80_000))
        })
        #expect(queries == 1 && dispatches == 1)
        let result = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-direct")
        #expect(result["verified"] as? Bool == false)
        #expect(result["releaseVerified"] as? Bool == false)
    }

    @Test func invalidReadinessIdentityAndVersionNeverSendInput() throws {
        let input = try CoreDeviceInputTests().input(["button", "home"])
        for metadata in [try details(mode: "disabled"), try details(hardware: "other"), try details(version: nil), try details(version: "1.bad"), try details(version: "")] {
            #expect(throws: CommandFailure.self) {
                try DirectPhysicalInput.execute(input, query: { _ in metadata }, send: { _ in Issue.record("Invalid metadata dispatched input") })
            }
        }
        var sends = 0
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalInput.execute(input, query: { _ in try details() }, send: { _ in sends += 1; throw CommandFailure(description: "fixture failure") })
        }
        #expect(sends == 1)
        let touch = try CoreDeviceInputTests().input(["tap", "0.5", "0.5"])
        #expect(throws: CommandFailure.self) {
            try DirectPhysicalInput.execute(touch, query: { _ in Issue.record("Unavailable operation queried device"); return Data() }, send: { _ in Issue.record("Unavailable operation dispatched input") })
        }
    }

    @Test func defaultPhysicalButtonDryRunUsesDirectBackendWithoutQueries() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried device"); return Data() })
        let output = try await service.execute(["physical", CoreDeviceInputTests().udid, "button", "home"], dryRun: true)
        let result = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(result["backend"] as? String == "coredevice-direct")
        #expect(result["executable"] == nil)
    }

    @Test func processRunnersRejectNonAppleControllersBeforeSpawn() async throws {
        for name in ["axe", "manzanero-idevice", "manzanero-coredevice", "manzanero-video", "unrecognized-controller"] {
            #expect(throws: CommandFailure.self) { try ToolRunner().run([name], executable: "/usr/bin/env") }
            #expect(throws: CommandFailure.self) { try ToolRunner().run([], executable: "/project/tmp/bin/\(name)") }
            await #expect(throws: CommandFailure.self) {
                try await StreamingToolRunner().run(executable: "/usr/bin/env", arguments: [name], timeout: 1) { _ in Issue.record("Disallowed controller produced output") }
            }
        }
        try DeviceExecutablePolicy.validate("/usr/bin/xcrun", arguments: ["devicectl", "list", "devices"])
        #expect(try ToolRunner().run([], executable: "/usr/bin/true").isEmpty)
    }
}
