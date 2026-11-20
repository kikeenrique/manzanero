import Foundation
import Testing
@testable import Manzanero

/// Stands in for a device's audit server on a DTX stream: a cursor that goes
/// round a list of elements, announces each one it lands on, answers the
/// label of the element under it only, and records what was activated.
private final class FakeAuditServer: AccessibilitySessionTransport {
    struct Item { let identifier: String?; let label: String; var activates = true }

    let items: [Item]
    private var cursor = -1
    private var outgoing: [AccessibilityDTX] = []
    private var identifier: UInt32 = 1000
    private(set) var pressed: [String] = []
    private(set) var requests: [String] = []
    /// When set, the action request is answered with an error.
    var refusesAction = false

    init(_ items: [Item]) { self.items = items }

    private static func plain(_ value: Any) -> NSDictionary { ["ObjectType": "passthrough", "Value": value] }
    private static func typed(_ type: String, _ fields: [String: Any]) -> NSDictionary {
        ["ObjectType": type, "Value": plain(fields.mapValues { ($0 as? NSDictionary)?["ObjectType"] != nil ? $0 : plain($0) } as NSDictionary)]
    }
    private static func attribute(_ name: String) -> NSDictionary { typed("AXAuditElementAttribute_v1", ["AttributeNameValue_v1": name]) }
    private static func archive(_ object: NSObject) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    private func focus(_ index: Int) -> NSDictionary {
        let item = items[index]
        var element: [String: Any] = ["PlatformElementValue_v1": Data([UInt8(index), 1, 2, 3])]
        if let identifier = item.identifier { element["AccessibilityIdentifier_v1"] = identifier }
        var attributes = [Self.attribute("Label"), Self.attribute("Value")]
        if item.activates { attributes.append(Self.attribute(InspectorPress.activateName)) }
        let section = Self.typed("AXAuditInspectorSection_v1", ["ElementAttributesValue_v1": Self.plain(attributes as NSArray)])
        return Self.typed("AXAuditInspectorFocus_v1", ["ElementValue_v1": Self.typed("AXAuditElement_v1", element),
            "CaptionTextValue_v1": "\(item.label), Button", "InspectorSectionsValue_v1": Self.plain([section] as NSArray)])
    }

    func write(_ message: AccessibilityDTX, until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws {
        guard message.kind == .invocation, let selector = AuditSession.unarchive(message.object) as? String else { return }
        requests.append(selector)
        switch selector {
        case "deviceApiVersion": outgoing.append(try message.reply(object: Self.archive(NSNumber(value: 26))))
        case "deviceInspectorMoveWithOptions:":
            guard !items.isEmpty else { return }
            cursor = (cursor + 1) % items.count
            identifier += 1
            outgoing.append(try AccessibilityDTX.invocation("hostInspectorCurrentElementChanged:", argument: focus(cursor),
                                                            identifier: identifier, expectsReply: false))
        case "deviceElement:valueForAttribute:":
            outgoing.append(try message.reply(object: Self.archive(Self.plain(items[cursor].label))))
        case "deviceElement:performAction:withValue:":
            if refusesAction {
                let reply = try message.reply(object: Self.archive("refused" as NSString))
                outgoing.append(AccessibilityDTX(identifier: reply.identifier, conversation: reply.conversation, channel: reply.channel,
                                                 expectsReply: false, kind: .error, auxiliary: Data(), object: reply.object))
            } else {
                pressed.append(items[cursor].identifier ?? items[cursor].label)
                outgoing.append(try message.reply())
            }
        default: break
        }
    }

    func read(until deadline: ContinuousClock.Instant, cancelled: () -> Bool) throws -> AccessibilityDTX {
        guard !outgoing.isEmpty else { throw CommandFailure(.timeout, "fixture: nothing more from the device", inputSent: .none) }
        return outgoing.removeFirst()
    }

    func close() {}
}

struct InspectorPressTests {
    private static let screen: [FakeAuditServer.Item] = [
        .init(identifier: "probe.tv.button.a", label: "Button A"), .init(identifier: "probe.tv.button.b", label: "Button B"),
        .init(identifier: "probe.tv.twin.1", label: "Twin"), .init(identifier: "probe.tv.twin.2", label: "Twin"),
        .init(identifier: "probe.tv.summary", label: "Summary", activates: false), .init(identifier: nil, label: "Probe TV", activates: false)]

    private static func press(_ by: String, _ text: String, index: Int? = nil,
                              server: FakeAuditServer = FakeAuditServer(screen)) throws -> ([String: Any], FakeAuditServer) {
        let result = try InspectorPress(selector: .init(by: by, text: text, index: index)).execute(session: AuditSession(transport: server))
        return (result, server)
    }

    @Test func theCursorIsWalkedRoundAndTheElementPressedWhenItComesBack() throws {
        let (result, server) = try Self.press("identifier", "probe.tv.button.b")
        #expect(server.pressed == ["probe.tv.button.b"])
        #expect(result["route"] as? String == "inspector" && result["status"] as? String == "accepted" && result["elementsWalked"] as? Int == 6)
        #expect((result["target"] as? [String: Any])?["identifier"] as? String == "probe.tv.button.b")
        // Monitoring is switched on before the first move, and the walk goes round once and on to the target.
        #expect(server.requests.prefix(3) == ["deviceApiVersion", "deviceSetAppMonitoringEnabled:", "deviceInspectorSetMonitoredEventType:"])
        // Six elements, the move that finds the first one again, and one more to the target.
        #expect(server.requests.filter { $0 == "deviceInspectorMoveWithOptions:" }.count == 6 + 1 + 1)
        #expect(server.requests.last == "deviceElement:performAction:withValue:")
    }

    @Test func aLabelIsReadUnderTheCursorAndMustNameOneElement() throws {
        let (result, server) = try Self.press("label", "Button A")
        #expect(server.pressed == ["probe.tv.button.a"] && (result["selector"] as? [String: Any])?["by"] as? String == "label")
        let twins = FakeAuditServer(Self.screen)
        let ambiguous = #expect(throws: InspectorPress.Unavailable.self) { try Self.press("label", "Twin", server: twins) }
        #expect(ambiguous?.description.contains("2 elements") == true && twins.pressed.isEmpty)
        let missing = FakeAuditServer(Self.screen)
        let none = #expect(throws: InspectorPress.Unavailable.self) { try Self.press("identifier", "probe.tv.row.35", server: missing) }
        #expect(none?.description.contains("6 elements and none") == true && missing.pressed.isEmpty)
    }

    @Test func whatTheCursorCannotDoIsSaidBeforeAnythingIsSent() throws {
        for (by, text, index) in [("value", "x", nil as Int?), ("identifier", "probe.tv.twin.1", 1)] {
            let server = FakeAuditServer(Self.screen)
            #expect(throws: InspectorPress.Unavailable.self) { try Self.press(by, text, index: index, server: server) }
            #expect(server.requests.isEmpty)
        }
        // An element with no Activate action, an empty screen, and a device that stops answering.
        let still = FakeAuditServer(Self.screen)
        let inert = #expect(throws: InspectorPress.Unavailable.self) { try Self.press("identifier", "probe.tv.summary", server: still) }
        #expect(inert?.description.contains("no Activate") == true && still.pressed.isEmpty)
        #expect(throws: InspectorPress.Unavailable.self) { try Self.press("identifier", "x", server: FakeAuditServer([])) }
    }

    @Test func aRefusedActionIsAnUnknownOutcomeAndNotAFallback() throws {
        let server = FakeAuditServer(Self.screen)
        server.refusesAction = true
        let failure = #expect(throws: CommandFailure.self) { try Self.press("identifier", "probe.tv.button.a", server: server) }
        #expect(failure?.code == .inputOutcomeUnknown && failure?.inputSent == .possible)
    }
}

/// The route's entry point: only a press, only on an Apple TV.
struct InspectorRouteTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    private static func details(type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": uuid, "properties": ["state": ["developerModeStatus": "enabled"],
                                               "hardware": ["deviceType": type, "udid": "00008110-000A11112222801E"]]]])
    }

    private static func press(_ operation: String, _ operands: [String], type: String = "appleTV",
                              open: @escaping InspectorRoute.Open) throws -> InspectorRoute.Outcome {
        try InspectorRoute.press(CoreDeviceInput.validated(device: uuid, operation: operation, operands: operands),
                                 query: { _ in try details(type: type) }, open: open)
    }

    @Test func aPressOnAnAppleTVGoesByTheCursorAndCarriesTheDevice() throws {
        let outcome = try Self.press("press-id", ["probe.tv.button.a"]) { udid in
            #expect(udid == "00008110-000A11112222801E")
            return (AuditSession(transport: FakeAuditServer([.init(identifier: "probe.tv.button.a", label: "Button A")])), {})
        }
        guard case .pressed(let data) = outcome else { Issue.record("not pressed"); return }
        let receipt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(receipt["resolvedCoreDeviceUUID"] as? String == Self.uuid && receipt["transport"] as? String == "apple-mobiledevice-shim")
    }

    @Test func anotherDeviceOrAnotherCommandDoesNotOpenTheRoute() throws {
        let never: InspectorRoute.Open = { _ in Issue.record("opened"); throw CancellationError() }
        if case .notApplicable = try Self.press("press-id", ["x"], type: "iPhone", open: never) {} else { Issue.record("a phone") }
        if case .notApplicable = try Self.press("scroll-id", ["x"], open: never) {} else { Issue.record("a scroll") }
        // What the cursor cannot select is said without opening anything.
        if case .unavailable = try Self.press("press-value", ["x"], open: never) {} else { Issue.record("by value") }
        if case .unavailable = try Self.press("press-id", ["x", AccessibilitySelector.indexOption, "2"], open: never) {} else { Issue.record("index") }
    }

    @Test func aRouteThatDoesNotOpenLeavesTheOtherOneWithItsReason() throws {
        let outcome = try Self.press("press-label", ["Button A"]) { _ in throw CommandFailure(.deviceNotReady, "no connection", inputSent: .none) }
        guard case .unavailable(let reason) = outcome else { Issue.record("not unavailable"); return }
        #expect(reason.contains("no connection"))
        let annotated = InspectorRoute.annotate(Data(#"{"status":"accepted"}"#.utf8), unavailable: reason)
        let root = try #require(JSONSerialization.jsonObject(with: annotated) as? [String: Any])
        #expect(root["inspectorUnavailable"] as? String == reason && root["status"] as? String == "accepted")
    }
}
