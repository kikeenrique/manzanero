import Foundation
import Testing
@testable import Manzanero

/// A selector action with `--pid` may run in the process that hosts the
/// display-centre one: the browser around a web page.
struct HostedProcessActionTests {
    typealias Value = AccessibilityArchiveValue

    /// Two processes: `page` holds the display centre, and its snapshot is
    /// rooted at an element of `host` when `hosted` is true.
    final class Session: AccessibilityExchange {
        let page: Int32 = 43, host: Int32 = 42
        var hosted = true
        var remoteClass = "AXRemoteElement"
        var applications: [Int32] = []
        var platform: AccessibilityPlatform { .physical }

        static func token(_ id: UInt64, pid: Int32) -> Value {
            .object(className: "AXPTranslationObject", fields: ["pid": .signed(Int64(pid)), "objectID": .unsigned(id),
                "isApplicationElement": .boolean(id == 1), "didPopuldateAppInfo": .boolean(true),
                "rawElementData": .data(Data([0x91])), "bridgeDelegateToken": .null])
        }
        static func record(_ id: UInt64, pid: Int32, attributes: [String: Value] = [:], children: [Value] = []) -> Value {
            .dictionary(["UIAccessibilitySnapshotKeyElement": token(id, pid: pid),
                "UIAccessibilitySnapshotKeyAttributes": .dictionary(attributes),
                "UIAccessibilitySnapshotKeyChildren": .array(children),
                "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(UInt64(children.count))])
        }

        func start() throws {}
        func application(pid: Int32) throws -> AccessibilityRequest.Token {
            applications.append(pid)
            return try AccessibilityResponse.token(Self.token(1, pid: pid))
        }
        func hit(x: Double, y: Double) throws -> AccessibilityRequest.Token { try AccessibilityResponse.token(Self.token(5, pid: page)) }
        func snapshot(_ token: AccessibilityRequest.Token) throws -> Value {
            let field = Self.record(3, pid: page, attributes: ["2001": .string("Username")])
            guard hosted else { return Self.record(1, pid: page, children: [field]) }
            return Self.record(2, pid: host, attributes: ["5003": .string(remoteClass)], children: [field])
        }
        func attributes(_ attributes: [Int], of token: AccessibilityRequest.Token) throws -> Value { .dictionary([:]) }
        func performAction(_ token: AccessibilityRequest.Token, action: AccessibilityRequest.Action, onSubmission: () -> Void) throws -> Bool { false }
        func close() -> AccessibilitySession.Cleanup { .notSubscribed }
    }

    private func action(pid: Int32?) -> DirectAccessibilityAction {
        DirectAccessibilityAction(guardsFor: "press", by: "label", text: "Address", pid: pid)
    }

    @Test func withoutAPIDOrWithTheCentrePIDTheCentreProcessIsUsedAndNothingIsRead() throws {
        let session = Session()
        #expect(try action(pid: nil).actionProcess(selected: session.page, session: session) == session.page)
        #expect(try action(pid: session.page).actionProcess(selected: session.page, session: session) == session.page)
        #expect(session.applications.isEmpty)
        let json = action(pid: session.page).applicationJSON(session.page, centre: session.page, platform: .physical)
        #expect(json["selection"] as? String == "explicit-pid+centre-hit-test" && json["hostedPid"] == nil)
    }

    @Test func theHostOfTheCentreProcessIsAccepted() throws {
        let session = Session()
        #expect(try action(pid: session.host).actionProcess(selected: session.page, session: session) == session.host)
        #expect(session.applications == [session.page])
        let json = action(pid: session.host).applicationJSON(session.host, centre: session.page, platform: .physical)
        #expect(json["pid"] as? Int32 == session.host && json["hostedPid"] as? Int32 == session.page)
        #expect(json["selection"] as? String == "explicit-pid-hosting-centre-hit-test")
    }

    /// `remote sleep` names an Apple TV's system UI process, which draws
    /// Control Centre over the frontmost application and hosts nothing. Only
    /// the process set as the overlay passes; the same PID without it, and
    /// another PID with it, are refused as before.
    @Test func onlyTheOverlayProcessSetByTheCommandPassesTheGuard() throws {
        let session = Session()
        session.hosted = false
        var overlay = action(pid: 77)
        overlay.overlayProcess = 77
        #expect(try overlay.actionProcess(selected: session.page, session: session) == 77)
        #expect(session.applications.isEmpty)
        let json = overlay.applicationJSON(77, centre: session.page, platform: .physical)
        #expect(json["selection"] as? String == "overlay-process" && json["frontmostPid"] as? Int32 == session.page)
        var another = action(pid: 78)
        another.overlayProcess = 77
        for refused in [action(pid: 77), another] {
            let failure = try #require(throws: CommandFailure.self) { try refused.actionProcess(selected: session.page, session: session) }
            #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
        }
        // No operand sets it.
        let parsed = try DirectAccessibilityAction(CoreDeviceInput.validated(device: "00008110-000A11112222801E", operation: "press-id", operands: ["77", "sleep"]))
        #expect(parsed.overlayProcess == nil && parsed.pid == 77)
    }

    /// Any other process is refused before the action: one that hosts
    /// nothing, and one that is not the host of the centre process.
    @Test func aPIDThatDoesNotHostTheCentreProcessIsRefused() throws {
        let plain = Session()
        plain.hosted = false
        let other = Session()
        for (session, pid) in [(plain, plain.host), (other, Int32(77))] {
            let failure = try #require(throws: CommandFailure.self) { try action(pid: pid).actionProcess(selected: session.page, session: session) }
            #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
            #expect(failure.description.contains("requested PID differs from display-centre process and does not host it"))
        }
    }
}
