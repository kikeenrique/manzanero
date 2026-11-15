import AppleDeviceBridge
import Foundation
import Testing
import XPC
@testable import Manzanero

struct RSDDirectoryConnectionTests {
    private let hardware = "00000000-0000000000000001"

    private func fixture(port: String = "51000", encrypted: Bool = false) -> xpc_object_t {
        let root = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(root, "MessageType", "Handshake")
        let properties = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(properties, "UniqueDeviceID", hardware)
        xpc_dictionary_set_value(root, "Properties", properties)
        let services = xpc_dictionary_create(nil, nil, 0)
        let service = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(service, "Port", port)
        let options = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(options, "UsesRemoteXPC", true)
        xpc_dictionary_set_bool(options, "EncryptSocketData", encrypted)
        xpc_dictionary_set_value(service, "Properties", options)
        xpc_dictionary_set_value(services, "com.apple.accessibility.axAuditDaemon.remoteAXService", service)
        xpc_dictionary_set_value(root, "Services", services)
        return root
    }

    private func validate(_ message: xpc_object_t?, expected: String? = nil) -> (Int32, UInt16, String) {
        var port: UInt16 = 123
        var error = [CChar](repeating: 0, count: 1024)
        let status = ADCValidateRSDHandshake(message.map { Unmanaged.passUnretained($0).toOpaque() }, expected ?? hardware,
            &port, &error, error.count)
        return (status, port, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    @Test func directoryRequiresMatchingHardwareAndExactSupportedService() {
        let result = validate(fixture())
        #expect(result.0 == 0 && result.1 == 51000)
        for message in [fixture(encrypted: true), xpc_dictionary_create(nil, nil, 0), xpc_string_create("wrong")] {
            let result = validate(message)
            #expect(result.0 != 0 && result.1 == 0 && result.2.contains("no AX connection started"))
        }
        #expect(validate(nil).0 != 0)
        #expect(validate(fixture(), expected: "00000000-0000000000000002").0 != 0)
        #expect(validate(fixture(), expected: "alias").0 != 0)
        let missing = fixture()
        xpc_dictionary_set_value(missing, "Services", nil)
        #expect(validate(missing).0 != 0)
    }

    @Test func malformedPortsFlagsAndOversizedInventoryAreRejected() {
        for port in ["", "0", "65536", "-1", "+123", "123456", "12x"] {
            #expect(validate(fixture(port: port)).0 != 0)
        }
        let root = fixture()
        let services = xpc_dictionary_get_dictionary(root, "Services")!
        let service = xpc_dictionary_get_dictionary(services, "com.apple.accessibility.axAuditDaemon.remoteAXService")!
        let properties = xpc_dictionary_get_dictionary(service, "Properties")!
        xpc_dictionary_set_string(properties, "UsesRemoteXPC", "true")
        #expect(validate(root).0 != 0)
        xpc_dictionary_set_bool(properties, "UsesRemoteXPC", true)
        xpc_dictionary_set_value(properties, "EncryptSocketData", nil)
        #expect(validate(root).0 != 0)
        xpc_dictionary_set_bool(properties, "EncryptSocketData", false)
        for index in 0..<4096 { xpc_dictionary_set_value(services, "fixture.\(index)", xpc_dictionary_create(nil, nil, 0)) }
        #expect(validate(root).0 != 0)
    }

    @Test func invalidSwiftIdentityAndAddressFailBeforeTCP() {
        #expect(throws: CommandFailure.self) { try RSDDirectoryConnection(tunnelAddress: "fd12::1", port: 1, expectedUDID: "alias") }
        #expect(throws: CommandFailure.self) { try RSDDirectoryConnection(tunnelAddress: "::1", port: 1, expectedUDID: hardware) }
        #expect(throws: CommandFailure.self) { try RSDDirectoryConnection(tunnelAddress: "fd12::1", port: 0, expectedUDID: hardware) }
    }

    @Test func networkBootstrapRejectsInvalidOrCancelledTargetsBeforeCreation() throws {
        var address = try RSDPortDiscovery.socketAddress("fd12::1", port: 12345)
        var owner = UnsafeMutableRawPointer(bitPattern: 1)
        var port: UInt16 = 123
        var error = [CChar](repeating: 0, count: 512)
        let cancelled = withUnsafePointer(to: &address) {
            ADCOpenRSDDirectoryNetwork($0, MemoryLayout<sockaddr_in6>.size, hardware, "11111111-1111-1111-1111-111111111111",
                0x0100000000000006, { 1 }, &port, &owner, &error, error.count)
        }
        #expect(cancelled != 0 && owner == nil && port == 0)
        #expect(ADCOpenRSDDirectoryNetwork(nil, 0, hardware, "11111111-1111-1111-1111-111111111111",
            0x0100000000000006, { 0 }, &port, &owner, &error, error.count) != 0)
        #expect(owner == nil && port == 0)
    }

    @Test func localHostIdentityNeverFallsBackToARemoteDeviceUUID() throws {
        let uuid = "11111111-1111-1111-1111-111111111111"
        #expect(try RSDDirectoryConnection.localPeerUUID(in: Data("Local device\n\tUUID: \(uuid)\nRemote device\n\tUUID: 22222222-2222-2222-2222-222222222222".utf8)) == uuid)
        for text in ["", "Remote device\n\tUUID: \(uuid)", "Local device\n\tUUID: invalid\nRemote device\n\tUUID: \(uuid)"] {
            #expect(throws: CommandFailure.self) { try RSDDirectoryConnection.localPeerUUID(in: Data(text.utf8)) }
        }
    }
}
