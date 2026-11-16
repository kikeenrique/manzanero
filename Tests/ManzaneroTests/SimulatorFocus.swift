import Foundation
import Testing
@testable import Manzanero

/// Apple TV focus in trees and waits, against the scripted simulator AX peer.
struct SimulatorFocusTests {
    static let uuid = SimulatorDeviceTests.uuid

    static func service(_ fixture: SimulatorAXFixture, family: String) -> CommandService {
        var environment = SimulatorAccessibilityTests.environment(fixture)
        environment.lookup = { _ in
            var info = SimulatorDeviceTests.info()
            info.family = family
            return info
        }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator command queried CoreDevice"); return Data() })
    }

    static func fixture() -> SimulatorAXFixture {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(id: 2, identifier: "probe.alpha", label: "Alpha"), .init(id: 3, identifier: "probe.bravo", label: "Bravo")]
        return fixture
    }

    @Test func appleTVTreeMarksTheFocusedNode() async throws {
        let fixture = Self.fixture()
        fixture.focusedElement = 3
        let tree = try SimulatorAccessibilityTests.json(await Self.service(fixture, family: "Apple TV").run(["tree", "--simulator", Self.uuid]))
        let nodes = try #require(tree["nodes"] as? [[String: Any]])
        let focused = nodes.filter { $0["focused"] as? Bool == true }
        #expect(focused.count == 1 && focused.first?["identifier"] as? String == "probe.bravo")
        #expect(nodes.filter { $0["focused"] != nil }.count == 1)
        let focus = try #require(tree["focus"] as? [String: Any])
        #expect(focus["nodeId"] as? String == focused.first?["id"] as? String && focus["label"] as? String == "Bravo" && focus["attribute"] as? Int == 19)
        #expect(fixture.attributeQueries == [[19]])
    }

    @Test func noFocusedElementLeavesNodesUnmarked() async throws {
        let fixture = Self.fixture()
        let tree = try SimulatorAccessibilityTests.json(await Self.service(fixture, family: "Apple TV").run(["tree", "--simulator", Self.uuid]))
        #expect((tree["nodes"] as? [[String: Any]] ?? []).allSatisfy { $0["focused"] == nil })
        #expect((tree["focus"] as? [String: Any])?["nodeId"] is NSNull)
    }

    @Test func otherFamiliesReadNoFocus() async throws {
        for family in ["iPhone", "Apple Watch", ""] {
            let fixture = Self.fixture()
            fixture.focusedElement = 3
            let tree = try SimulatorAccessibilityTests.json(await Self.service(fixture, family: family).run(["tree", "--simulator", Self.uuid]))
            #expect(tree["focus"] == nil && fixture.attributeQueries.isEmpty)
            #expect((tree["nodes"] as? [[String: Any]] ?? []).allSatisfy { $0["focused"] == nil })
        }
    }

    @Test(arguments: [(true, "condition-met", "focused"), (false, "timed-out", "not-focused"), (nil, "timed-out", "focus-unknown")] as [(Bool?, String, String)])
    func waitUntilFocusedReadsTheLiveAttribute(_ focused: Bool?, _ status: String, _ reason: String) async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(id: 2, identifier: "probe.alpha", label: "Alpha", focused: focused)]
        let output = try await Self.service(fixture, family: "Apple TV")
            .run(["wait", "--id", "probe.alpha", "--until", "focused", "--timeout", "0", "--simulator", Self.uuid])
        let result = try SimulatorAccessibilityTests.json(output)
        #expect(result["status"] as? String == status && (result["observation"] as? [String: Any])?["reason"] as? String == reason)
        #expect(fixture.attributeQueries == [[27, 32, 28]])
    }

    @Test func otherWaitsKeepTheirLiveAttributes() async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(id: 2, identifier: "probe.alpha", label: "Alpha")]
        _ = try await Self.service(fixture, family: "Apple TV").run(["wait", "--id", "probe.alpha", "--until", "enabled", "--timeout", "0", "--simulator", Self.uuid])
        #expect(fixture.attributeQueries == [[27, 32]])
        let wait = try AccessibilityWait(CoreDeviceInput(device: "phone", operation: "wait-id", operands: ["x", "--until", "focused"]))
        #expect(wait.condition == .focused && wait.conditionJSON["until"] as? String == "focused")
    }

    @Test func focusAttributesAreAcceptedAndOthersStillRefused() throws {
        let token = try AccessibilityRequest.Token(pid: 42, objectID: 1)
        _ = try AccessibilityRequest.attributes([AccessibilityRequest.focusedElementAttribute], of: token)
        _ = try AccessibilityRequest.attributes([27, 32, AccessibilityRequest.focusedAttribute], of: token)
        #expect(throws: CommandFailure.self) { try AccessibilityRequest.attributes([30], of: token) }
    }
}
