import AppleDeviceBridge
import Foundation
import Testing
import XPC
@testable import Manzanero

struct NativeMediaFramesTests {
    @Test(arguments: ["valid", "equivalent-ip", "swapped", "port", "source", "boolean", "oversized", "error", "missing"])
    func negotiatedEndpointsMustMatchOwnedReceiver(mutation: String) {
        let reply = xpc_dictionary_create(nil, nil, 0), output = xpc_dictionary_create(nil, nil, 0)
        let connection = xpc_dictionary_create(nil, nil, 0), config = xpc_dictionary_create(nil, nil, 0)
        let sender = xpc_dictionary_create(nil, nil, 0), receiver = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(sender, "ipv6Address", mutation == "equivalent-ip" ? "fd00:0000:0:0:0:0:0:2" : "fd00::2")
        xpc_dictionary_set_string(receiver, "ipv6Address", "fd00::1")
        xpc_dictionary_set_uint64(sender, "port", 51000)
        xpc_dictionary_set_uint64(receiver, "port", 50000)
        xpc_dictionary_set_uint64(config, "SourcePort", 51000)
        xpc_dictionary_set_value(connection, "sender", sender)
        xpc_dictionary_set_value(connection, "receiver", receiver)
        xpc_dictionary_set_value(connection, "streamConfig", config)
        xpc_dictionary_set_value(output, "connection", connection)
        xpc_dictionary_set_value(reply, "CoreDevice.output", output)
        switch mutation {
        case "swapped": xpc_dictionary_set_string(sender, "ipv6Address", "fd00::1")
        case "port": xpc_dictionary_set_uint64(receiver, "port", 50001)
        case "source": xpc_dictionary_set_uint64(config, "SourcePort", 51001)
        case "boolean": xpc_dictionary_set_bool(sender, "port", true)
        case "oversized": xpc_dictionary_set_uint64(sender, "port", 65536)
        case "error": xpc_dictionary_set_value(reply, "CoreDevice.error", xpc_dictionary_create(nil, nil, 0))
        case "missing": xpc_dictionary_set_value(connection, "sender", nil)
        default: break
        }
        var port: UInt16 = 99, error = [CChar](repeating: 0, count: 512)
        let status = ADCValidateVideoEndpoints(Unmanaged.passUnretained(reply).toOpaque(), "fd00::1", "fd00::2", 50000, &port, &error, error.count)
        let valid = mutation == "valid" || mutation == "equivalent-ip"
        #expect((status == 0) == valid)
        #expect(port == (valid ? 51000 : 0))
    }

    @Test func invalidAndPreCancelledVideoEndpointsHaveNoOwner() {
        for cancelled in [false, true] {
            var owner = UnsafeMutableRawPointer(bitPattern: 1), error = [CChar](repeating: 0, count: 512)
            #expect(ADCCreateVideoPacketSession("invalid", "651.32", "bad", "invalid", "invalid", { cancelled ? 1 : 0 }, &owner, &error, error.count) != 0)
            #expect(owner == nil)
        }
        var cleanup = ADCVideoCleanup()
        #expect(ADCCloseVideoSession(nil, &cleanup, nil, 0) == 0)
        #expect(cleanup.startAttempted == 0 && cleanup.stopAcknowledged == 0)
    }
}
