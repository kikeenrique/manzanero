import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

struct RSDTransportProfileTests {
    @Test func invalidIdentitiesClearProfileWithoutRSDLookup() {
        var profile = ADCRemoteTransportProfile(versionFlags: 123, modeFlags: 123, tlsEnabled: 1)
        var error = [CChar](repeating: 0, count: 512)
        #expect(ADCReadRSDTransportProfile("invalid", "invalid", &profile, &error, error.count) != 0)
        #expect(profile.versionFlags == 0 && profile.modeFlags == 0 && profile.tlsEnabled == -1)
        #expect(ADCReadRSDTransportProfile("invalid", "invalid", nil, &error, error.count) != 0)
        #expect(ADCReadRSDTransportProfileForHardware("invalid", &profile, &error, error.count) != 0)
        #expect(profile.versionFlags == 0 && profile.modeFlags == 0 && profile.tlsEnabled == -1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_RSD_PROFILE_DEVICE"] != nil))
    func explicitLiveProfileChecksHardwareWithoutConnectingOrReadingCredentials() throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_RSD_PROFILE_DEVICE"])
        let remote = try #require(ProcessInfo.processInfo.environment["MANZANERO_RSD_PROFILE_REMOTE_UUID"])
        let input = CoreDeviceInput(device: device, operation: "tree", operands: [])
        _ = try DirectPhysicalInput.identity(input, query: { plan in try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20) })
        var profile = ADCRemoteTransportProfile()
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCReadRSDTransportProfile(remote, device, &profile, &error, error.count)
        guard status == 0 else { throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        var browsed = ADCRemoteTransportProfile()
        guard ADCReadRSDTransportProfileForHardware(device, &browsed, &error, error.count) == 0 else {
            throw CommandFailure(description: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        let matches = browsed.versionFlags == profile.versionFlags && browsed.modeFlags == profile.modeFlags && browsed.tlsEnabled == profile.tlsEnabled
        #expect(matches)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/rsd-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let metadata: [String: Any] = ["device": device, "remoteUUID": remote, "versionFlagsHex": String(profile.versionFlags, radix: 16),
            "modeFlags": profile.modeFlags, "tlsEnabledReported": profile.tlsEnabled, "hardwareOnlyBrowseMatched": matches, "serviceSocketOpened": false, "credentialsRead": false]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        #expect(profile.versionFlags != 0)
        #expect(profile.tlsEnabled == 0 || profile.tlsEnabled == 1)
    }
}
