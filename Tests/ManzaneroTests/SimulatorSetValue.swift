import Foundation
import Testing
@testable import Manzanero

/// `set-value-id` / `set-value-label` on the simulator, against the AX fixture.
struct SimulatorSetValueTests {
    static let uuid = SimulatorDeviceTests.uuid
    typealias Fixture = SimulatorAXFixture

    static func fixture() -> Fixture {
        let fixture = Fixture()
        fixture.elements = [.init(identifier: "probe.text.field", label: "Probe text field")]
        return fixture
    }

    static func run(_ fixture: Fixture, _ operands: [String], dryRun: Bool = false) async throws -> [String: Any] {
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try SimulatorAccessibilityTests.json(await SimulatorAccessibilityTests.service(
            fixture, leases: SimulatorAccessibilityTests.usableLeases(directory)).execute(["simulator", uuid] + operands, dryRun: dryRun))
    }

    @Test func operandsAreAnOptionalPIDASelectorAndText() throws {
        let plain = try #require(try SimulatorInput.parse(["simulator", Self.uuid, "set-value-id", "probe.text.field", "mañana 🚀 中"]))
        let action = try DirectAccessibilitySetValue(plain.coreDeviceInput)
        #expect(action.guards.by == "identifier" && action.guards.text == "probe.text.field" && action.value == "mañana 🚀 中" && action.guards.pid == nil)
        let labelled = try DirectAccessibilitySetValue(#require(try SimulatorInput.parse(["simulator", Self.uuid, "set-value-label", "42", "Field", "x"])).coreDeviceInput)
        #expect(labelled.guards.by == "label" && labelled.guards.pid == 42 && labelled.operation == "set-value")
        let invalid: [([String], String)] = [
            (["set-value-id", "only"], "Usage: set-value-id|set-value-label [positive-pid] <exact-selector> <text>; text is 1...65536 UTF-8 bytes without NUL."),
            (["set-value-id", "1", "2", "3", "4"], "Usage: set-value-id|set-value-label [positive-pid] <exact-selector> <text>; text is 1...65536 UTF-8 bytes without NUL."),
            (["set-value-id", "field", ""], "Native AX set-value text must be 1...65536 UTF-8 bytes without NUL."),
            (["set-value-id", "field", "a\0b"], "Native AX set-value text must be 1...65536 UTF-8 bytes without NUL."),
            (["set-value-id", "field", String(repeating: "é", count: 32769)], "Native AX set-value text must be 1...65536 UTF-8 bytes without NUL."),
            (["set-value-id", "", "x"], "Native AX set-value requires an exact selector of 1...4096 UTF-8 bytes without NUL."),
            (["set-value-id", "0", "field", "x"], "Native AX selector PID must be positive.")
        ]
        for (operands, message) in invalid {
            let failure = try #require(throws: CommandFailure.self) { try SimulatorInput.parse(["simulator", Self.uuid] + operands) }
            #expect(failure.description == message && failure.code == .usage && failure.inputSent == .none)
        }
        // The largest value is accepted.
        #expect(try SimulatorInput.parse(["simulator", Self.uuid, "set-value-id", "f", String(repeating: "é", count: 32768)]) != nil)
    }

    @Test func requestsCarryTheValueAttributeAndLeaveOtherArchivesUnchanged() throws {
        let token = try AccessibilityRequest.Token(pid: 42, objectID: 7)
        func fields(_ data: Data) throws -> [String: AccessibilityArchiveValue] {
            guard case .object("AXPTranslatorRequest", let fields) = try KeyedArchiveInspector.decodeProtocol(data) else {
                throw CommandFailure(description: "not a request")
            }
            return fields
        }
        let settable = try fields(AccessibilityRequest.settable(token))
        #expect(settable["requestType"]?.unsignedInteger == 3 && settable["attributeType"]?.unsignedInteger == 53)
        let set = try fields(AccessibilityRequest.setValue(token, text: "mañana 🚀"))
        #expect(set["requestType"]?.unsignedInteger == 8 && set["attributeType"]?.unsignedInteger == 53)
        guard case .dictionary(let parameters) = set["parameters"] else { Issue.record("no parameters"); return }
        #expect(parameters["value"] == .string("mañana 🚀"))
        // The physical requests keep their attribute type.
        #expect(try fields(AccessibilityRequest.snapshot(token))["attributeType"]?.unsignedInteger == 52)
        for archive in [try AccessibilityRequest.application(pid: 42), try AccessibilityRequest.hit(x: 1, y: 2),
                        try AccessibilityRequest.attributes([53], of: token), try AccessibilityRequest.action(token, action: .press)] {
            #expect(try fields(archive)["attributeType"]?.unsignedInteger == 0)
        }
    }

    @Test func aSettableTargetGetsOneSetValueAndAReadBack() async throws {
        let fixture = Self.fixture()
        let receipt = try await Self.run(fixture, ["set-value-id", "probe.text.field", "mañana 🚀 中"])
        #expect(fixture.setValues == ["mañana 🚀 中"])
        // Selection, application, two snapshots, live state, settable, hit,
        // rechecks, set-value, read-back.
        let kinds = fixture.kinds
        let settable = try #require(kinds.firstIndex(of: 3)), set = try #require(kinds.firstIndex(of: 8))
        #expect(settable < set && kinds.filter { $0 == 8 }.count == 1 && kinds.last == 5)
        #expect(kinds.firstIndex(of: 6).map { $0 > settable && $0 < set } == true)
        #expect(receipt["status"] as? String == "acknowledged" && receipt["valueMatches"] as? Bool == true)
        #expect(receipt["operation"] as? String == "set-value" && receipt["backend"] as? String == "coresimulator-ax")
        #expect(receipt["verified"] as? Bool == false && receipt["requestedUTF8Bytes"] as? Int == 16 && receipt["readBackUTF8Bytes"] as? Int == 16)
        #expect(receipt["platform"] as? String == "simulator")
        #expect((receipt["selector"] as? [String: String]) == ["by": "identifier", "text": "probe.text.field"])
    }

    @Test func aTransformedValueIsReportedNotRefused() async throws {
        let fixture = Self.fixture()
        fixture.transform = { $0.uppercased() }
        let receipt = try await Self.run(fixture, ["set-value-label", "Probe text field", "abc"])
        #expect(fixture.setValues == ["abc"] && receipt["valueMatches"] as? Bool == false && receipt["status"] as? String == "acknowledged")
    }

    @Test func aTargetThatIsNotSettableIsRefusedBeforeAnythingIsSent() async throws {
        let fixture = Self.fixture()
        fixture.settable = false
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.run(fixture, ["set-value-id", "probe.text.field", "x"])
        })
        #expect(failure.code == .targetUnresolved && failure.inputSent == .none && fixture.setValues.isEmpty && !fixture.kinds.contains(8))
        #expect(failure.description.hasPrefix("Native AX set-value: the target does not report a settable value"))
    }

    @Test func aMissingOrHiddenTargetIsRefusedLikePress() async throws {
        let missing = Self.fixture()
        let none = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.run(missing, ["set-value-id", "no.such.field", "x"])
        })
        #expect(none.code == .targetUnresolved && none.inputSent == .none && !missing.kinds.contains(3))
        let hidden = Self.fixture()
        hidden.elements[0].visible = false
        let covered = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.run(hidden, ["set-value-id", "probe.text.field", "x"])
        })
        #expect(covered.code == .preconditionChanged && covered.inputSent == .none && hidden.setValues.isEmpty)
    }

    @Test func aFailureAfterSubmissionIsAnUnknownOutcome() async throws {
        let fixture = Self.fixture()
        fixture.actionResult = nil
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.run(fixture, ["set-value-id", "probe.text.field", "x"])
        })
        #expect(failure.code == .inputOutcomeUnknown && failure.inputSent == .possible && failure.retry == .afterInspection)
        #expect(failure.description.contains("state=submitted, stage=set-value"))
    }

    @Test func setValueTakesTheLease() async throws {
        let fixture = Self.fixture()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var holder = ""
        fixture.onAction = { holder = SimulatorAccessibilityTests.leaseHolder(directory) }
        _ = try await SimulatorAccessibilityTests.service(fixture, leases: SimulatorAccessibilityTests.usableLeases(directory))
            .execute(["simulator", Self.uuid, "set-value-id", "probe.text.field", "x"])
        #expect(holder.contains("set-value-id"))
    }

    @Test func dryRunPlansWithoutLookingTheSimulatorUp() async throws {
        let fixture = Self.fixture()
        let plan = try SimulatorAccessibilityTests.json(await SimulatorAccessibilityTests.service(fixture, state: "Shutdown")
            .execute(["simulator", Self.uuid, "set-value-label", "7", "Field", "héllo"], dryRun: true))
        #expect(plan["operation"] as? String == "set-value" && plan["pid"] as? Int == 7 && plan["requestedUTF8Bytes"] as? Int == 6)
        #expect(plan["deviceLease"] as? String == "simulator UUID" && plan["backend"] as? String == "coresimulator-ax")
        #expect((plan["execution"] as? String)?.contains("type 8, attribute 53") == true)
        #expect(fixture.requests.isEmpty)
    }
}
