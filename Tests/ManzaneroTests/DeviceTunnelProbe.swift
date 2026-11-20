import AppleDeviceBridge
import Foundation
import Testing
@testable import Manzanero

/// Opt-in live check of the tool's own tunnel on a device on its cable or on the network
/// and unlocked: open the tunnel, relay to the device's service directory,
/// and read the directory through the tool's existing directory code. Reads
/// only; nothing is sent to an app. Enabled by MANZANERO_TUNNEL_DEVICE, the
/// hardware UDID.
struct DeviceTunnelProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_TUNNEL_DEVICE"] != nil))
    func theDirectoryIsReadThroughTheToolsOwnTunnel() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_TUNNEL_DEVICE"])
        let tunnel = try DeviceTunnel(device: device)
        defer { tunnel.close() }
        #expect(tunnel.info.mtu >= 1280 && tunnel.info.serviceDirectoryPort > 0)
        let port = try tunnel.relay(to: tunnel.info.serviceDirectoryPort)
        // The directory's handshake checks the device's identity itself.
        let directory = try RSDDirectoryConnection(tunnelAddress: "::1", port: port, expectedUDID: device, relayed: true)
        defer { directory.close() }
        #expect(directory.accessibilityPort > 0)
        FileHandle.standardError.write(Data("tunnel mtu \(tunnel.info.mtu), accessibility service found: \(directory.accessibilityPort > 0)\n".utf8))

        // One read-only tree of the app in front, over a second relay to
        // the accessibility service's port.
        let run: (DeviceCommand) throws -> Data = { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) }
        let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: device, operation: "tree", operands: []), query: run)
        let servicePort = try tunnel.relay(to: directory.accessibilityPort)
        let transport = try RSDDirectoryConnection.openAccessibility(tunnelAddress: "::1", port: servicePort, relayed: true)
        let session = AccessibilitySession(transport: transport)
        let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: nil, session: session,
            display: { try AccessibilityDisplay(run(AccessibilityDisplay.plan(device: identity.uuid))) })
        let tree = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nodes = tree["nodeCount"] as? Int ?? 0
        #expect(nodes > 0)
        FileHandle.standardError.write(Data("tree through the tunnel: \(nodes) nodes, \(bytes.count) bytes\n".utf8))
    }
}

/// Opt-in live check of the accessibility daemon reached through the Mac's
/// own remoted, by the shim MobileDevice is served: one read-only tree of
/// the app in front. Enabled by MANZANERO_SHIM_DEVICE, the hardware UDID.
struct AccessibilityShimProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_DEVICE"] != nil))
    func aTreeIsReadThroughTheShim() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_SHIM_DEVICE"])
        let run: (DeviceCommand) throws -> Data = { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) }
        let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: device, operation: "tree", operands: []), query: run)
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let session = AccessibilitySession(transport: shim.transport)
        let bytes = try DirectPhysicalAccessibility.capture(device: device, resolved: identity.uuid, pid: nil, session: session,
            display: { try AccessibilityDisplay(run(AccessibilityDisplay.plan(device: identity.uuid))) })
        let tree = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nodes = tree["nodeCount"] as? Int ?? 0
        #expect(nodes > 0)
        FileHandle.standardError.write(Data("tree through the shim: \(nodes) nodes, \(bytes.count) bytes\n".utf8))
    }
}

/// Opt-in: what the audit server behind the shim answers. Asks for its
/// version, then for one element and a few of that element's attributes, in
/// the server's own requests, and prints each reply. Read-only. Enabled by
/// MANZANERO_SHIM_SELECTORS, the hardware UDID.
struct AccessibilityShimSelectorProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"] != nil))
    func theDaemonBehindTheShimAnswersTheseRequests() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_SHIM_SELECTORS"])
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let transport = shim.transport
        var identifier: UInt32 = 1
        @discardableResult func ask(_ selector: String, _ arguments: [NSObject] = [], note: String = "", show: Int = 1600) throws -> Data {
            let message = try AccessibilityDTX.invocation(selector, arguments: arguments, identifier: identifier)
            identifier += 1
            let limit = ContinuousClock.now.advanced(by: .seconds(6))
            try transport.write(message, until: limit, cancelled: { false })
            while true {
                let frame = try transport.read(until: limit, cancelled: { false })
                if frame.kind == .invocation {
                    let name = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "?"
                    if frame.expectsReply {
                        let seven = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
                        try transport.write(frame.reply(object: name.contains("ersion") ? seven : Data()), until: limit, cancelled: { false })
                    }
                    continue
                }
                guard frame.isReply(to: message) else { continue }
                let value = (try? KeyedArchiveInspector.decodeProtocol(frame.object)).map { "\($0)" } ?? "(\(frame.object.count) bytes)"
                let text = value.replacingOccurrences(of: "Manzanero.AccessibilityArchiveValue.", with: "")
                FileHandle.standardError.write(Data("\(selector)\(note.isEmpty ? "" : " \(note)") ->\(frame.kind) [\(frame.object.count) bytes] \(text.prefix(show))\n".utf8))
                return frame.object
            }
        }
        try ask("deviceApiVersion")
        // Special element 1 answered an element of the app in front once and
        // nothing another time; 0 has always answered.
        var reply = try ask("deviceFetchSpecialElement:", [NSNumber(value: 1)], note: "1")
        if reply.isEmpty { reply = try ask("deviceFetchSpecialElement:", [NSNumber(value: 0)], note: "0") }
        // Or the element at a point of the display, 0...1 each way, given as
        // MANZANERO_SHIM_POINT=x,y. This request takes a plain point value:
        // given Apple's typed AXAuditPoint dictionary instead, the server
        // answered an error naming `CGPointValue`, without crashing.
        if let text = ProcessInfo.processInfo.environment["MANZANERO_SHIM_POINT"] {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let found = try ask("deviceFetchElementAtNormalizedDeviceCoordinate:", [NSValue(point: NSPoint(x: parts[0], y: parts[1]))], note: text)
                if !found.isEmpty { reply = found }
            }
        }
        // The element is a dictionary of property-list values.
        let element = try #require(try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self, NSData.self, NSNumber.self, NSArray.self], from: reply) as? NSDictionary)
        #expect(element["ObjectType"] as? String == "AXAuditElement_v1")
        // An attribute travels as Apple's own encoder writes it
        // (`AXAuditObjectTransportManager` in the AccessibilityAudit
        // framework, asked on the Mac): a typed dictionary, never a plain
        // name. On 2026-11-20 a plain name made the Apple TV's axauditd abort
        // (SIGABRT), twice (docs/verification.md#an-element-read-through-the-shim).
        // The attributes asked for are named in MANZANERO_SHIM_ATTRIBUTES,
        // comma-separated, so that a new one is tried alone.
        func attribute(_ name: String) -> NSDictionary {
            func plain(_ value: Any) -> NSDictionary { ["ObjectType": "passthrough", "Value": value] }
            return ["ObjectType": "AXAuditElementAttribute_v1", "Value": plain([
                "AttributeNameValue_v1": plain(name), "DisplayAsTree_v1": plain(false), "DisplayInlineValue_v1": plain(false),
                "IsInternal_v1": plain(false), "PerformsActionValue_v1": plain(false), "SettableValue_v1": plain(false),
                "ValueTypeValue_v1": plain(1)] as NSDictionary)]
        }
        for name in (ProcessInfo.processInfo.environment["MANZANERO_SHIM_ATTRIBUTES"] ?? "").split(separator: ",") {
            do { try ask("deviceElement:valueForAttribute:", [element, attribute(String(name))], note: String(name), show: 1200) }
            catch { FileHandle.standardError.write(Data("\(name) -> threw \(error)\n".utf8)); break }
        }
    }
}

/// Opt-in: the audit server's inspector cursor, the way Apple's
/// Accessibility Inspector goes from one element to the next. Each move is
/// answered by the device with `hostInspectorCurrentElementChanged:`, whose
/// focus object names the element, its caption and the attributes it has.
/// Every request is in the form Apple's own client writes it
/// (`XDMDeviceTransportBased` in the Inspector's device manager): the move
/// options and an element as typed dictionaries, numbers and flags plain.
/// Enabled by MANZANERO_SHIM_WALK, the hardware UDID; MANZANERO_SHIM_STEPS
/// moves (default 1) in MANZANERO_SHIM_DIRECTION (default 4, next);
/// MANZANERO_SHIM_SETUP names requests sent first (`monitor`, `events`,
/// `ignored`); MANZANERO_SHIM_READ=1 also asks for each attribute the device
/// listed, given back as received. Writes what it saw to tmp/shim-walk.txt.
struct AccessibilityShimWalkProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_SHIM_WALK"] != nil))
    func theInspectorCursorMovesThroughTheScreen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let device = try #require(environment["MANZANERO_SHIM_WALK"])
        let shim = try AccessibilityShim(device: device)
        defer { shim.close() }
        let transport = shim.transport
        var identifier: UInt32 = 1
        var lines: [String] = []
        func note(_ line: String) { lines.append(line) }
        defer {
            try? FileManager.default.createDirectory(atPath: "tmp", withIntermediateDirectories: true)
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: "tmp/shim-walk.txt"))
        }
        let classes: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self, NSNumber.self, NSArray.self, NSValue.self, NSNull.self, NSDate.self]
        func unarchive(_ bytes: Data) -> Any? {
            bytes.isEmpty ? nil : try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: bytes)
        }
        // Typed dictionaries read without their wrapping.
        func plain(_ value: Any) -> Any {
            if let dictionary = value as? NSDictionary {
                if let type = dictionary["ObjectType"] as? String {
                    let inner = dictionary["Value"].map(plain) ?? "nil"
                    return type == "passthrough" ? inner : ["<\(type)>": inner]
                }
                var result: [String: Any] = [:]
                for (key, item) in dictionary { result["\(key)"] = plain(item) }
                return result
            }
            if let array = value as? NSArray { return array.map(plain) }
            if let data = value as? Data { return "data(\(data.count)) " + data.prefix(24).map { String(format: "%02x", $0) }.joined() }
            return value
        }
        func text(_ bytes: Data) -> String {
            if let object = unarchive(bytes) { return "\(plain(object))" }
            return (try? KeyedArchiveInspector.decodeProtocol(bytes)).map { "\($0)" } ?? "(\(bytes.count) bytes)"
        }
        var events: [(name: String, argument: Data)] = []
        // Answers what the device asks, and keeps what it announces.
        func take(_ frame: AccessibilityDTX, until limit: ContinuousClock.Instant) throws {
            let name = (unarchive(frame.object) as? String) ?? "?"
            if frame.expectsReply {
                let seven = try NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 7), requiringSecureCoding: true)
                try transport.write(frame.reply(object: name.contains("ersion") ? seven : Data()), until: limit, cancelled: { false })
            }
            let argument = (try? frame.archiveArgument()) ?? Data()
            events.append((name, argument))
            note("<- \(name) [\(argument.count) bytes] \(text(argument))")
        }
        @discardableResult func ask(_ selector: String, _ arguments: [NSObject] = [], reply: Bool = true, note label: String = "") throws -> Data {
            let message = try AccessibilityDTX.invocation(selector, arguments: arguments, identifier: identifier, expectsReply: reply)
            identifier += 1
            let limit = ContinuousClock.now.advanced(by: .seconds(6))
            try transport.write(message, until: limit, cancelled: { false })
            guard reply else { note("-> \(selector) \(label)"); return Data() }
            while true {
                let frame = try transport.read(until: limit, cancelled: { false })
                if frame.kind == .invocation { try take(frame, until: limit); continue }
                guard frame.isReply(to: message) else { continue }
                note("-> \(selector) \(label) = \(frame.kind) [\(frame.object.count) bytes] \(text(frame.object))")
                return frame.object
            }
        }
        // Reads what the device sends by itself until an event of that name, or the time is up.
        func wait(for name: String, seconds: Double) -> Data? {
            let limit = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
            let seen = events.count
            while ContinuousClock.now < limit {
                if let found = events[seen...].first(where: { $0.name == name }) { return found.argument }
                guard let frame = try? transport.read(until: limit, cancelled: { false }) else { break }
                if frame.kind == .invocation { try? take(frame, until: limit) }
            }
            return events[seen...].first(where: { $0.name == name })?.argument
        }
        func typed(_ value: Any) -> NSDictionary { ["ObjectType": "passthrough", "Value": value] }

        try ask("deviceApiVersion")
        for step in (environment["MANZANERO_SHIM_SETUP"] ?? "").split(separator: ",") {
            switch step {
            case "monitor": try ask("deviceSetAppMonitoringEnabled:", [NSNumber(value: true)], reply: false)
            case "events": try ask("deviceInspectorSetMonitoredEventType:", [NSNumber(value: 0)], reply: false)
            case "ignored": try ask("deviceInspectorShowIgnoredElements:", [NSNumber(value: true)], reply: false)
            default: note("unknown setup step \(step)")
            }
        }
        let direction = Int(environment["MANZANERO_SHIM_DIRECTION"] ?? "") ?? 4
        let steps = Int(environment["MANZANERO_SHIM_STEPS"] ?? "") ?? 1
        var seen = Set<Data>()
        var cursor: NSDictionary?
        var listed: [String: NSDictionary] = [:]
        for step in 0..<steps {
            let options = typed(["direction": typed(direction), "includeContainers": typed(true), "allowNonAX": typed(false)] as NSDictionary)
            try ask("deviceInspectorMoveWithOptions:", [options], reply: false, note: "step \(step) direction \(direction)")
            guard let argument = wait(for: "hostInspectorCurrentElementChanged:", seconds: 4) else { note("no element after step \(step)"); break }
            // The focus object: the element, then the sections of attributes.
            guard let focus = (unarchive(argument) as? NSDictionary)?["Value"] as? NSDictionary,
                  let fields = focus["Value"] as? NSDictionary, let element = fields["ElementValue_v1"] as? NSDictionary else { continue }
            if let token = ((element["Value"] as? NSDictionary)?["Value"] as? NSDictionary)?["PlatformElementValue_v1"] as? NSDictionary,
               let bytes = token["Value"] as? Data, !seen.insert(bytes).inserted {
                note("the cursor is back on an element already seen, after \(step + 1) moves")
                break
            }
            guard let sections = (fields["InspectorSectionsValue_v1"] as? NSDictionary)?["Value"] as? NSArray else { continue }
            cursor = element
            for case let section as NSDictionary in sections {
                guard let attributes = (((section["Value"] as? NSDictionary)?["Value"] as? NSDictionary)?["ElementAttributesValue_v1"] as? NSDictionary)?["Value"] as? NSArray else { continue }
                for case let attribute as NSDictionary in attributes {
                    let inner = (attribute["Value"] as? NSDictionary)?["Value"] as? NSDictionary
                    let name = (inner?["AttributeNameValue_v1"] as? NSDictionary)?["Value"] as? String ?? "?"
                    listed[name] = attribute
                    guard environment["MANZANERO_SHIM_READ"] == "1" else { continue }
                    // An attribute that performs an action is never asked for.
                    if ((inner?["PerformsActionValue_v1"] as? NSDictionary)?["Value"] as? NSNumber)?.boolValue == true { note("   \(name): an action, not asked"); continue }
                    do { try ask("deviceElement:valueForAttribute:", [element, attribute], note: name) }
                    catch { note("\(name) threw \(error)"); return }
                }
            }
            // MANZANERO_SHIM_PRESS names an identifier: when the cursor is
            // on it, its Activate action is performed, as Apple's client
            // writes it (the element, the action attribute as the device
            // listed it, and a null value), and the walk ends.
            let identifier = (((element["Value"] as? NSDictionary)?["Value"] as? NSDictionary)?["AccessibilityIdentifier_v1"] as? NSDictionary)?["Value"] as? String
            if let target = environment["MANZANERO_SHIM_PRESS"], identifier == target {
                guard let action = listed["AXAction-2010"] else { note("\(target) lists no Activate action"); break }
                try ask("deviceElement:performAction:withValue:", [element, action, NSNull()], note: target)
                _ = wait(for: "hostInspectorCurrentElementPropertiesChanged:", seconds: 1)
                break
            }
            listed["AXAction-2010"] = nil
        }
        #expect(!events.isEmpty)
        // The whole screen in one request: the hierarchy attribute of the
        // element under the cursor answers the tree it belongs to. Then,
        // for the identifiers named in MANZANERO_SHIM_ELEMENTS, the listed
        // attributes of elements the cursor is not on.
        guard environment["MANZANERO_SHIM_TREE"] == "1", let cursor, let hierarchy = listed["_AXHierarchyElementsAttribute"] else { return }
        let started = ContinuousClock.now
        let reply = try ask("deviceElement:valueForAttribute:", [cursor, hierarchy], note: "tree")
        lines.removeLast()
        note("tree: \(reply.count) bytes in \(ContinuousClock.now - started)")
        var found: [String: NSDictionary] = [:]
        var count = 0
        func walk(_ node: Any?, depth: Int) {
            guard let fields = ((node as? NSDictionary)?["Value"] as? NSDictionary)?["Value"] as? NSDictionary else { return }
            func field(_ key: String) -> Any? { (fields[key] as? NSDictionary)?["Value"] }
            let element = fields["AuditElementValue_v1"] as? NSDictionary
            let identifier = (((element?["Value"] as? NSDictionary)?["Value"] as? NSDictionary)?["AccessibilityIdentifier_v1"] as? NSDictionary)?["Value"] as? String
            if let identifier, let element { found[identifier] = element }
            count += 1
            let others = fields.allKeys.map { "\($0)" }.filter { !["AuditElementValue_v1", "ChildrenValue_v1", "HumanReadableDescriptionValue_v1", "HumanReadableRoleDescriptionValue_v1", "IsIgnoredValue_v1"].contains($0) }
            note(String(repeating: "  ", count: depth) + "\(field("HumanReadableDescriptionValue_v1") ?? "-") | role \(field("HumanReadableRoleDescriptionValue_v1") ?? "-") | id \(identifier ?? "-") | ignored \(field("IsIgnoredValue_v1") ?? "-")\(others.isEmpty ? "" : " | also \(others)")")
            for child in (field("ChildrenValue_v1") as? NSArray) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(unarchive(reply), depth: 0)
        note("tree: \(count) nodes, \(found.count) with an identifier")
        for special in (environment["MANZANERO_SHIM_SPECIAL"] ?? "").split(separator: ",").compactMap({ Int($0) }) {
            try ask("deviceFetchSpecialElement:", [NSNumber(value: special)], note: "\(special)")
        }
        for identifier in (environment["MANZANERO_SHIM_ELEMENTS"] ?? "").split(separator: ",").map(String.init) {
            guard let element = found[identifier] else { note("no element \(identifier) in the tree"); continue }
            for name in ["Label", "Value", "TraitsHumanReadable", "Identifier"] {
                guard let attribute = listed[name] else { continue }
                try ask("deviceElement:valueForAttribute:", [element, attribute], note: "\(identifier) \(name)")
            }
        }
    }
}

/// Opt-in: one swipe on the Apple TV remote's touch surface, on a physical
/// device. A touch-pad service is created on the device's Universal HID
/// service for the call, as on a simulator, and the swipe's reports are sent
/// to it. Sends input: have the tvOS probe in front. Enabled by
/// MANZANERO_REMOTE_TOUCH_DEVICE, the hardware UDID, and
/// MANZANERO_REMOTE_TOUCH_SWIPE (`swipe-up`, `swipe-down`, `swipe-left` or
/// `swipe-right`).
struct RemoteTouchProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_REMOTE_TOUCH_DEVICE"] != nil))
    func aSwipeIsSentToATouchPadServiceCreatedOnTheDevice() async throws {
        let environment = ProcessInfo.processInfo.environment
        let device = try #require(environment["MANZANERO_REMOTE_TOUCH_DEVICE"])
        guard case .swipe(let dx, let dy)? = AppleTVRemote.routes[environment["MANZANERO_REMOTE_TOUCH_SWIPE"] ?? ""] else {
            Issue.record("MANZANERO_REMOTE_TOUCH_SWIPE names no swipe")
            return
        }
        let run: (DeviceCommand) throws -> Data = { try ToolRunner().run($0.arguments, executable: $0.executable, timeout: 20) }
        let identity = try DirectPhysicalInput.identity(CoreDeviceInput(device: device, operation: "remote", operands: []), query: run)
        let frames = AppleTVRemote.swipeFrames(dx: dx, dy: dy)
        let bytes = frames.reports.flatMap { $0 }
        var error = [CChar](repeating: 0, count: 1024)
        let status = frames.times.withUnsafeBufferPointer { times in
            bytes.withUnsafeBufferPointer { reports in
                ADCPerformCancellableRemoteTouch(identity.uuid, identity.version, times.baseAddress, reports.baseAddress,
                                                 times.count, { 0 }, &error, error.count)
            }
        }
        let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        try? FileManager.default.createDirectory(atPath: "tmp", withIntermediateDirectories: true)
        try? Data("status \(status) \(message)\n".utf8).write(to: URL(fileURLWithPath: "tmp/remote-touch.txt"))
        #expect(status == 0, "\(message)")
    }
}
