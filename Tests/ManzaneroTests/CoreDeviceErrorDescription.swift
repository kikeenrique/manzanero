import AppleDeviceBridge
import Foundation
import Testing
import XPC

struct CoreDeviceErrorDescriptionTests {
    private func describe(_ value: xpc_object_t?, capacity: Int = 2048) -> String {
        var bytes = [CChar](repeating: 0, count: capacity)
        ADCDescribeCoreDeviceError(value.map { Unmanaged.passUnretained($0).toOpaque() }, &bytes, bytes.count)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @Test func preservesBoundedExplanationsAndUnderlyingCodesWithoutArbitraryData() {
        let failure = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(failure, "domain", "fixture.CoreDevice")
        xpc_dictionary_set_int64(failure, "code", 4000)
        let info = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(info, "NSLocalizedDescription", "Connection failed\nInspect transport")
        xpc_dictionary_set_string(info, "privatePairingMaterial", "DO_NOT_PRINT")
        let underlying = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(underlying, "domain", "fixture.Transport")
        xpc_dictionary_set_int64(underlying, "code", 13)
        xpc_dictionary_set_value(info, "NSUnderlyingError", underlying)
        xpc_dictionary_set_value(failure, "userInfo", info)
        let output = describe(failure)
        #expect(output.contains("fixture.CoreDevice 4000") && output.contains("underlying: fixture.Transport 13"))
        #expect(output.contains("Connection failed Inspect transport"))
        #expect(output.contains("DO_NOT_PRINT") == false && output.contains("\n") == false)
        #expect(describe(failure, capacity: 8).utf8.count <= 7)
    }

    @Test func rejectsWrongShapesAndBoundsStringsAndNestedErrors() {
        #expect(describe(nil).contains("unknown Apple socket failure"))
        #expect(describe(xpc_string_create("not a dictionary")).contains("unknown Apple socket failure"))
        let failure = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(failure, "domain", String(repeating: "x", count: 10000))
        xpc_dictionary_set_int64(failure, "code", 1)
        var previous = failure
        for code in 2...6 {
            let nested = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(nested, "domain", "nested\(code)")
            xpc_dictionary_set_int64(nested, "code", Int64(code))
            xpc_dictionary_set_value(previous, "underlyingError", nested)
            previous = nested
        }
        let output = describe(failure)
        #expect(output.contains("nested3 3") && output.contains("nested4") == false)
        #expect(output.utf8.count < 400)
        ADCDescribeCoreDeviceError(nil, nil, 0)
    }
}
