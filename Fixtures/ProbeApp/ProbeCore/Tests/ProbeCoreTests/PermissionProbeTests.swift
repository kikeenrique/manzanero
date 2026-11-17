import ProbeCore
import Testing

struct PermissionProbeTests {
    @Test func valueIsSortedJSONWithTheStatusName() {
        #expect(PermissionProbe.value(status: .unknown, requests: 0) == #"{"requests":0,"status":"unknown","v":1}"#)
        #expect(PermissionProbe.value(status: .notDetermined, requests: 1) == #"{"requests":1,"status":"notDetermined","v":1}"#)
        #expect(PermissionProbe.value(status: .denied, requests: 2) == #"{"requests":2,"status":"denied","v":1}"#)
        #expect(PermissionProbe.Status.allCases.map(\.rawValue) == ["unknown", "notDetermined", "denied", "authorized", "provisional", "ephemeral"])
        #expect(PermissionProbe.requestIdentifier == "probe.permission.request")
    }
}
