import Foundation

/// The audit server Apple's Accessibility Inspector talks to, reached
/// through `AccessibilityShim`: its requests over DTX, each written as
/// Apple's own client writes it (docs/verification.md#the-inspectors-cursor-the-whole-hierarchy-and-a-press-through-the-shim).
/// Typed objects travel as `{ObjectType, Value}` dictionaries; a number, a
/// flag and a null go plain. Never add a request here whose form was not
/// read from Apple's client: a guessed one aborted a device's `axauditd`.
final class AuditSession {
    /// What the device announces without being asked, by request name.
    private var events: [(name: String, argument: Data)] = []
    private let transport: any AccessibilitySessionTransport
    private var identifier: UInt32 = 1
    private static let classes: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self, NSNumber.self, NSArray.self, NSValue.self, NSNull.self, NSDate.self]

    init(transport: any AccessibilitySessionTransport) { self.transport = transport }

    static func unarchive(_ bytes: Data) -> Any? {
        bytes.isEmpty ? nil : try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: bytes)
    }

    /// A value as Apple's encoder wraps one that has no type of its own.
    static func plain(_ value: Any) -> NSDictionary { ["ObjectType": "passthrough", "Value": value] }

    /// The inner dictionary of a typed object, or nil for another shape.
    static func fields(_ object: Any?, type: String) -> NSDictionary? {
        guard let typed = object as? NSDictionary, typed["ObjectType"] as? String == type else { return nil }
        return (typed["Value"] as? NSDictionary)?["Value"] as? NSDictionary
    }

    /// A field's value without its wrapping.
    static func value(_ fields: NSDictionary?, _ key: String) -> Any? { (fields?[key] as? NSDictionary)?["Value"] }

    /// Answers what the device asks and keeps what it announces.
    private func take(_ frame: AccessibilityDTX, until limit: ContinuousClock.Instant) throws {
        let name = (Self.unarchive(frame.object) as? String) ?? ""
        if frame.expectsReply {
            // The host's version is the one request the device waits on.
            let version = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
            try transport.write(frame.reply(object: name.lowercased().contains("version") ? version : Data()), until: limit, cancelled: { Task.isCancelled })
        }
        guard events.count < 4096 else { return }
        events.append((name, (try? frame.archiveArgument()) ?? Data()))
    }

    /// A request that is answered. An error answer throws.
    func ask(_ selector: String, _ arguments: [NSObject] = [], seconds: Double = 6) throws -> Data {
        let message = try AccessibilityDTX.invocation(selector, arguments: arguments, identifier: identifier)
        identifier += 1
        let limit = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        try transport.write(message, until: limit, cancelled: { Task.isCancelled })
        while true {
            let frame = try transport.read(until: limit, cancelled: { Task.isCancelled })
            if frame.kind == .invocation { try take(frame, until: limit); continue }
            guard frame.isReply(to: message) else { continue }
            guard frame.kind != .error else {
                throw CommandFailure(.toolFailed, "The device's audit server answered \(selector) with an error.", inputSent: .none)
            }
            return frame.object
        }
    }

    /// A request the device does not answer.
    func send(_ selector: String, _ arguments: [NSObject]) throws {
        let message = try AccessibilityDTX.invocation(selector, arguments: arguments, identifier: identifier, expectsReply: false)
        identifier += 1
        try transport.write(message, until: ContinuousClock.now.advanced(by: .seconds(6)), cancelled: { Task.isCancelled })
    }

    /// The next announcement of that name not yet handed out, waiting up to
    /// `seconds` for one. Earlier announcements of other names are dropped.
    func next(_ name: String, seconds: Double) throws -> Data? {
        let limit = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while true {
            if let index = events.firstIndex(where: { $0.name == name }) {
                let argument = events[index].argument
                events.removeFirst(index + 1)
                return argument
            }
            events.removeAll()
            guard ContinuousClock.now < limit, let frame = try? transport.read(until: limit, cancelled: { Task.isCancelled }) else {
                try Task.checkCancellation()
                return nil
            }
            if frame.kind == .invocation { try take(frame, until: limit) }
        }
    }

    func close() { transport.close() }
}

/// `press` on a physical Apple TV by the Inspector's cursor: the cursor is
/// walked through the screen, the one element the selector names is found,
/// the cursor is brought back to it and its Activate action is performed.
/// It makes no connection to the device's service directory, so the Mac's
/// own connection is not reset, and the on-screen focus does not move.
///
/// What it cannot do is said before anything is pressed, as `Unavailable`,
/// and the caller then uses the other route: an element the cursor does not
/// reach (rows inside a list, most of the time), several matches or
/// `--index` (the cursor's order is not the tree's), and selection by value.
/// The walk can scroll a list.
struct InspectorPress {
    /// Nothing was pressed, and the other route may be tried.
    struct Unavailable: Error, CustomStringConvertible { let description: String }

    struct Element {
        let token: Data
        let identifier: String?
        let caption: String
        /// The element and its Activate attribute as the device wrote them.
        let object: NSDictionary
        let label: NSDictionary?
        let activate: NSDictionary?
    }

    static let maximumMoves = 400
    static let activateName = "AXAction-2010"

    let selector: AccessibilitySelector

    /// Refusals that need no connection.
    func checkSelector() throws {
        if selector.by == "value" { throw Unavailable(description: "the Inspector's cursor gives no way to select by value") }
        if selector.index != nil { throw Unavailable(description: "the Inspector's cursor does not walk in the tree's order, so \(AccessibilitySelector.indexOption) is not used on it") }
    }

    static func element(_ argument: Data) -> Element? {
        guard let focus = AuditSession.fields(AuditSession.unarchive(argument), type: "AXAuditInspectorFocus_v1"),
              let object = focus["ElementValue_v1"] as? NSDictionary,
              let inner = AuditSession.fields(object, type: "AXAuditElement_v1"),
              let token = AuditSession.value(inner, "PlatformElementValue_v1") as? Data else { return nil }
        var listed: [String: NSDictionary] = [:]
        for case let section as NSDictionary in (AuditSession.value(focus, "InspectorSectionsValue_v1") as? NSArray) ?? [] {
            let attributes = AuditSession.value(AuditSession.fields(section, type: "AXAuditInspectorSection_v1"), "ElementAttributesValue_v1") as? NSArray
            for case let attribute as NSDictionary in attributes ?? [] {
                if let name = AuditSession.value(AuditSession.fields(attribute, type: "AXAuditElementAttribute_v1"), "AttributeNameValue_v1") as? String {
                    listed[name] = attribute
                }
            }
        }
        return Element(token: token, identifier: AuditSession.value(inner, "AccessibilityIdentifier_v1") as? String,
                       caption: AuditSession.value(focus, "CaptionTextValue_v1") as? String ?? "",
                       object: object, label: listed["Label"], activate: listed[activateName])
    }

    private static func move(_ session: AuditSession) throws -> Element? {
        let options = AuditSession.plain(["direction": AuditSession.plain(4), "includeContainers": AuditSession.plain(true),
                                          "allowNonAX": AuditSession.plain(false)] as NSDictionary)
        try session.send("deviceInspectorMoveWithOptions:", [options])
        guard let argument = try session.next("hostInspectorCurrentElementChanged:", seconds: 4) else { return nil }
        return element(argument)
    }

    private func matches(_ element: Element, session: AuditSession) throws -> Bool {
        if selector.by == "identifier" { return selector.accepts(element.identifier) }
        guard let label = element.label else { return false }
        let reply = try session.ask("deviceElement:valueForAttribute:", [element.object, label])
        let value = (AuditSession.unarchive(reply) as? NSDictionary)?["Value"]
        return selector.accepts(value as? String)
    }

    /// Walks the cursor through the screen, settles on the one element the
    /// selector names and brings the cursor back to it. Sends no input.
    private func locate(session: AuditSession) throws -> (element: Element, activate: NSDictionary, walked: Int) {
        _ = try session.ask("deviceApiVersion")
        // Without these two the device announces nothing after a move.
        try session.send("deviceSetAppMonitoringEnabled:", [NSNumber(value: true)])
        try session.send("deviceInspectorSetMonitoredEventType:", [NSNumber(value: 0)])
        var seen = Set<Data>(), found: [Element] = [], walked = 0
        while walked < Self.maximumMoves {
            try Task.checkCancellation()
            guard let element = try Self.move(session), seen.insert(element.token).inserted else { break }
            walked += 1
            if try matches(element, session: session) { found.append(element) }
        }
        guard walked > 0 else { throw Unavailable(description: "the device announced no element to the Inspector's cursor") }
        guard let target = found.first else {
            throw Unavailable(description: "the Inspector's cursor reached \(walked) elements and none with that \(selector.by)")
        }
        guard found.count == 1 else { throw Unavailable(description: "the Inspector's cursor reached \(found.count) elements with that \(selector.by)") }
        guard target.activate != nil else { throw Unavailable(description: "the element lists no Activate action") }
        // Values and actions are answered for the element under the cursor
        // only, so the cursor goes round to it again.
        for _ in 0...walked {
            try Task.checkCancellation()
            guard let element = try Self.move(session) else { break }
            guard element.token == target.token else { continue }
            guard let activate = element.activate, try matches(element, session: session) else { break }
            return (element, activate, walked)
        }
        throw Unavailable(description: "the Inspector's cursor did not come back to the element")
    }

    /// Walks, finds and presses. Throws `Unavailable` while nothing has
    /// been pressed; a failure of the press itself says input may have gone.
    func execute(session: AuditSession) throws -> [String: Any] {
        try checkSelector()
        let located: (element: Element, activate: NSDictionary, walked: Int)
        do { located = try locate(session: session) }
        catch let unavailable as Unavailable { throw unavailable }
        catch is CancellationError { throw CancellationError() }
        // A connection or protocol failure before the press: the other
        // route can still be tried.
        catch { throw Unavailable(description: String("\(error)".prefix(300))) }
        try Task.checkCancellation()
        do { _ = try session.ask("deviceElement:performAction:withValue:", [located.element.object, located.activate, NSNull()]) }
        catch {
            throw CommandFailure(.inputOutcomeUnknown, "The Activate request was sent through the Inspector's route and not confirmed: \(error). Inspect before retrying.", inputSent: .possible)
        }
        var target: [String: Any] = ["caption": located.element.caption]
        if let identifier = located.element.identifier { target["identifier"] = identifier }
        return ["backend": "coredevice-direct", "operation": "press", "selector": selector.json, "route": "inspector",
                "status": "accepted", "nativeAccepted": true, "effectVerified": false, "verified": false, "atomic": false,
                "target": target, "elementsWalked": located.walked,
                "limitations": ["Pressed by Apple's Accessibility Inspector cursor: no frame, visibility or hit test is known on this route.",
                    "The cursor's walk can scroll a list. The on-screen focus does not move.",
                    "No automatic replay. Inspect a fresh observation before retrying."]]
    }
}

/// Where `press` on a physical Apple TV tries the Inspector's cursor: after
/// the tool's own tunnel, which takes every selector. The route over Apple's
/// tunnel that once came last is gone for an Apple TV: it left the Mac's
/// connection to the device stale (the human owner's decision of
/// 2026-11-21). `MANZANERO_INSPECTOR_PRESS=0` turns the cursor off.
enum InspectorRoute {
    /// The routes of a press on a physical Apple TV, in order: the tool's own
    /// tunnel, then the Inspector's cursor. Each either presses or says,
    /// before anything is sent, why it cannot, and when neither can the press
    /// is refused with both reasons. A failure of a press itself ends the
    /// command, because its outcome is unknown and another route would press
    /// a second time.
    static func pressInOrder(isolation: isolated (any Actor)? = #isolation,
                             ownTunnel: () async throws -> Data,
                             inspector: (() throws -> Outcome)?) async throws -> Data {
        var notes: [String: String] = [:]
        do { return try await ownTunnel() } catch let refused as DirectPhysicalAccessibility.OwnTunnelRefused {
            notes["ownTunnelUnavailable"] = refused.reason
        }
        if let inspector {
            switch try inspector() {
            case .pressed(let data): return annotate(data, notes)
            case .unavailable(let reason): notes["inspectorUnavailable"] = reason
            case .notApplicable: break
            }
        }
        let reasons = ["ownTunnelUnavailable", "inspectorUnavailable"].compactMap { key in notes[key].map { "\(key): \($0)" } }
        throw CommandFailure(.deviceNotReady, DirectPhysicalAccessibility.appleTVTunnelRefusal(reasons.joined(separator: "; ")), inputSent: .none)
    }

    /// The device's details when the command is a press on a physical Apple
    /// TV, the one case the order above is for; nil otherwise.
    static func appleTVPress(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data) throws -> Data? {
        guard AccessibilitySelector.operations("press").contains(input.operation) else { return nil }
        let details = try query(input.identityPlan())
        return AppleTVRemote.deviceType(details) == "appleTV" ? details : nil
    }

    enum Outcome {
        case pressed(Data)
        /// Nothing was pressed; the reason goes into the other route's
        /// result as `inspectorUnavailable`.
        case unavailable(String)
        /// Not a press on an Apple TV: the route was not asked for.
        case notApplicable
    }

    /// Opens the audit server for a hardware UDID; `close` ends it.
    typealias Open = @Sendable (String) throws -> (session: AuditSession, close: () -> Void)

    static var enabled: Bool { ProcessInfo.processInfo.environment["MANZANERO_INSPECTOR_PRESS"] != "0" }

    static let live: Open = { udid in
        let shim = try AccessibilityShim(device: udid)
        return (AuditSession(transport: shim.transport), { shim.close() })
    }

    static func press(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data, open: Open = live) throws -> Outcome {
        guard let details = try appleTVPress(input, query: query) else { return .notApplicable }
        return try press(input, details: details, open: open)
    }

    /// A press on the Apple TV whose details are given.
    static func press(_ input: CoreDeviceInput, details: Data, open: Open = live) throws -> Outcome {
        let action = try DirectAccessibilityAction(input)
        let press = InspectorPress(selector: action.selector)
        do {
            if action.pid != nil { throw InspectorPress.Unavailable(description: "the Inspector's cursor takes no process") }
            try press.checkSelector()
            let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
            guard let root = try JSONSerialization.jsonObject(with: details) as? [String: Any],
                  let hardware = ((root["result"] as? [String: Any])?["properties"] as? [String: Any])?["hardware"] as? [String: Any],
                  let udid = hardware["udid"] as? String else {
                throw InspectorPress.Unavailable(description: "the device's details name no hardware identifier")
            }
            let opened: (session: AuditSession, close: () -> Void)
            do { opened = try open(udid) } catch { throw InspectorPress.Unavailable(description: String("\(error)".prefix(300))) }
            defer { opened.close() }
            var result = try press.execute(session: opened.session)
            result.merge(["device": input.device, "resolvedCoreDeviceUUID": identity.uuid, "transport": "apple-mobiledevice-shim"]) { $1 }
            return .pressed(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        } catch let unavailable as InspectorPress.Unavailable {
            return .unavailable(unavailable.description)
        }
    }

    /// Says in the result of the route used why the earlier ones were not.
    static func annotate(_ data: Data, _ notes: [String: String]) -> Data {
        guard !notes.isEmpty, var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        root.merge(notes) { $1 }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? data
    }
}
