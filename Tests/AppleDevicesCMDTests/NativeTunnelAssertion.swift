import AppleDeviceBridge
import Foundation
import Testing
import XPC
@testable import AppleDevicesCMD

struct NativeTunnelAssertionTests {
    private func reply(token: xpc_object_t? = xpc_uuid_create([UInt8](repeating: 1, count: 16)), address: String? = "fd12::1") -> xpc_object_t {
        let root = xpc_dictionary_create(nil, nil, 0), response = xpc_dictionary_create(nil, nil, 0), info = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(response, "assertionIdentifier", token)
        if let address { xpc_dictionary_set_string(info, "tunnelIPAddress", address) }
        xpc_dictionary_set_value(response, "info", info)
        xpc_dictionary_set_value(root, "response", response)
        return root
    }

    private func validate(_ root: xpc_object_t?, capacity: Int = 128) -> (Int32, String) {
        var address = [CChar](repeating: 120, count: capacity)
        var error = [CChar](repeating: 0, count: 256)
        let status = ADCValidateTunnelAssertionReply(root.map { Unmanaged.passUnretained($0).toOpaque() }, &address, address.count, &error, error.count)
        return (status, String(decoding: address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    @Test func assertionResponseRequiresTypedOpaqueTokenAndBoundedAddress() {
        let valid = validate(reply())
        #expect(valid.0 == 0 && valid.1 == "fd12::1")
        for root in [nil, reply(token: nil), reply(token: xpc_string_create("not-uuid")), reply(address: nil), reply(address: ""), reply(address: String(repeating: "a", count: 128)), xpc_string_create("wrong")] {
            let result = validate(root)
            #expect(result.0 != 0 && result.1.isEmpty)
        }
        #expect(validate(reply(), capacity: 3).0 != 0)
        let error = reply()
        xpc_dictionary_set_value(error, "error", xpc_dictionary_create(nil, nil, 0))
        #expect(validate(error).0 != 0)
    }

    @Test func rejectedOrPreCancelledTargetsClearOutputsWithoutDaemonRequests() {
        for (device, cancelled) in [("alias", false), ("00000000-0000000000000001", true)] {
            var address = [CChar](repeating: 120, count: 128), error = [CChar](repeating: 0, count: 512)
            var owner = UnsafeMutableRawPointer(bitPattern: 1)
            #expect(ADCOpenNativeTunnelAssertion(device, { cancelled ? 1 : 0 }, &address, address.count, &owner, &error, error.count) != 0)
            #expect(owner == nil && address[0] == 0)
        }
        #expect(ADCCloseNativeTunnelAssertion(nil, nil, 0) == 0)
    }

    @Test func wrapperRequiresFreshPairedPhysicalHardwareBeforeDaemonAccess() {
        #expect(throws: CommandFailure.self) { try NativeTunnelAssertion(device: "alias", details: Data("{}".utf8)) }
        #expect(throws: CommandFailure.self) { try NativeTunnelAssertion(device: "00000000-0000000000000001", details: Data("{}".utf8)) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLEDEVICES_NATIVE_TUNNEL_DEVICE"] != nil))
    func explicitLiveAssertionAcquiresAndReleasesWithoutPairingOrRSDConnection() throws {
        let device = try #require(ProcessInfo.processInfo.environment["APPLEDEVICES_NATIVE_TUNNEL_DEVICE"])
        let plan = try CoreDeviceInput(device: device, operation: "tree", operands: []).identityPlan()
        let details = try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
        let assertion = try NativeTunnelAssertion(device: device, details: details)
        defer { assertion.close() }
        let release = assertion.close()
        #expect(assertion.close().status == release.status)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/native-tunnel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let metadata: [String: Any] = ["device": device, "address": assertion.address, "assertionAcquired": true,
            "releaseConfirmed": release.confirmed, "releaseStatus": release.status, "releaseDiagnostic": release.diagnostic ?? "",
            "pairingInitiated": false, "rsdConnectionStarted": false, "deviceInputSent": false]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        #expect(release.confirmed)
    }
}
