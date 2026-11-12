import Testing
@testable import AppleDevicesCMD

struct DeviceCommandsTests {
    @Test func physicalLaunchKeepsAllDevicectlOptionsBeforeAppArgument() throws {
        let plan = try #require(try DeviceCommand.parse(["physical", "fixture-phone", "launch", "com.apple.Preferences"]))
        #expect(plan.arguments == ["devicectl", "device", "process", "launch", "--device", "fixture-phone",
            "--timeout", "60", "--json-output", "-", "com.apple.Preferences"])
        #expect(plan.jsonOutput)
    }
}
