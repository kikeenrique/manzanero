import Foundation
import Testing
@testable import Manzanero

/// A scripted simulator AX peer behind the CoreSimulator carrier: it reads the
/// project's request archives and answers with AXPTranslatorResponse archives,
/// as the bridge does after archiving the framework's reply. No simulator.
/// A clock that only the code under test advances, by sleeping.
final class VirtualClock: @unchecked Sendable {
    private(set) var instant = ContinuousClock.now
    private(set) var slept: Duration = .zero
    var now: () -> ContinuousClock.Instant { { [unowned self] in instant } }
    var sleep: (Duration) -> Void { { [unowned self] in instant = instant.advanced(by: $0); slept += $0 } }
}

final class SimulatorAXFixture: @unchecked Sendable {
    typealias Token = AccessibilityWaitTests.Token

    /// As the wait fixture's response, but resultData may be nil.
    @objc(ADCAXSimulatorTestResponse)
    final class Response: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let kind: UInt64
        let translation: Token?
        let result: NSObject?
        init(kind: UInt64, translation: Token? = nil, result: NSObject?) { self.kind = kind; self.translation = translation; self.result = result }
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {
            coder.encode(Int(kind), forKey: "associatedRequestType"); coder.encode(kind == 2 ? 52 : 0, forKey: "attribute")
            coder.encode(0, forKey: "error"); coder.encode(0, forKey: "notification")
            coder.encode(translation, forKey: "associatedTranslationObject"); coder.encode(result, forKey: "resultData")
        }
    }

    struct Element {
        var id = 2
        var identifier: String? = "fixture.target"
        var label: String? = "Target"
        var value: String?
        var visible: Bool? = true
        var enabled: Bool? = true
        var frame = NSRect(x: 100, y: 200, width: 80, height: 40)
        /// The live focused attribute (28); nil leaves it out.
        var focused: Bool?
    }
    /// The element the application's focused-element attribute (19) names; nil answers none.
    var focusedElement: Int?
    /// A hit on an element answers this other object for it, as UIKit does
    /// for a plain table row; its identifier and label are the element's
    /// unless these say otherwise.
    var hitHandle: Int?
    var hitHandleIdentifier: String?
    var hitHandleLabel: String?
    /// Attribute lists of live-attribute requests (type 5), in order.
    private(set) var attributeQueries: [[UInt64]] = []

    var pid: Int32 = 42
    var elements: [Element] = []
    /// Requests seen, as (type, action).
    private(set) var requests: [(kind: UInt64, action: UInt64)] = []
    var timeouts: [Duration] = []
    /// Answer to a press or scroll; nil throws a carrier failure after sending.
    var actionResult: Bool? = true
    var onAction: (() -> Void)?
    var emptySnapshot = false
    /// Full-depth (48) snapshots come back empty, as SpringBoard's do.
    var emptyAtFullDepth = false
    /// Shallow snapshots still empty before one answers.
    var emptyShallowAnswers = 0
    /// Depths requested by snapshots, in order.
    private(set) var snapshotDepths: [UInt64] = []
    /// The frontmost request answers without an application.
    var noFrontmost = false
    var frontmostPIDs: [Int32] = []
    var failKind: UInt64?
    /// Answer to the settable query (type 3).
    var settable = true
    /// Values received by set-value requests (type 8), in order.
    private(set) var setValues: [String] = []
    /// The value attribute (53) a read-back returns; set-value replaces it
    /// unless `transform` changes it first.
    var currentValue: String?
    var transform: (String) -> String = { $0 }
    /// The display information every read returns.
    var displayInfo = SimulatorInputTests.displayJSON()
    /// The application root's frame: the window, in the window's own points.
    var rootFrame = NSRect(x: 0, y: 0, width: 390, height: 844)
    /// With a host PID, snapshots are a page's: rooted at that host's remote element.
    var hostPID: Int32?
    /// Where the host's web view starts on the screen: the first page
    /// snapshot has its frames relative to it, later ones on the screen, as a
    /// simulator answers (2026-11-22).
    var hostOffset = NSPoint.zero
    private var hostedReads = 0
    /// Hit points as sent (after the interface-to-native mapping).
    private(set) var hitPoints: [NSPoint] = []
    /// The client type of each hit test as archived (the bridge keeps it).
    private(set) var hitClientTypes: [UInt64] = []

    var kinds: [UInt64] { requests.map(\.kind) }

    func carrier() -> SimulatorAccessibilitySession.Carrier {
        { [self] request, timeout in try answer(request, timeout: timeout) }
    }

    /// Advanced only by the session's pauses, so tests never wait.
    let clock = VirtualClock()

    func session(lifetime: Duration = .seconds(30)) -> SimulatorAccessibilitySession {
        SimulatorAccessibilitySession(carrier: carrier(), lifetime: lifetime, now: clock.now, cancelled: { false }, sleep: clock.sleep)
    }

    private func answer(_ request: Data, timeout: Duration) throws -> Data {
        guard case .object("AXPTranslatorRequest", let fields) = try KeyedArchiveInspector.decodeProtocol(request),
              let kind = fields["requestType"]?.unsignedInteger, let action = fields["actionType"]?.unsignedInteger else {
            throw CommandFailure(description: "Bad fixture request")
        }
        requests.append((kind, action))
        timeouts.append(timeout)
        if kind == failKind { throw CommandFailure(.transportFailed, "Simulator accessibility request failed: fixture", inputSent: .unknown) }
        let response: Response
        switch kind {
        case 1:
            response = Response(kind: 1, result: Token(1, pid: pid, application: true))
        case 2:
            let root = Token(1, pid: pid, application: true)
            guard case .dictionary(let parameters) = fields["parameters"], case .dictionary(let parameter) = parameters["parameter"] ?? .null,
                  let depth = parameter["maxDepth"]?.unsignedInteger else { throw CommandFailure(description: "Bad fixture snapshot") }
            snapshotDepths.append(depth)
            var empty = emptySnapshot || (emptyAtFullDepth && depth == 48)
            if depth < 48, emptyShallowAnswers > 0 { emptyShallowAnswers -= 1; empty = true }
            let shift = hostPID != nil && hostedReads > 0 ? hostOffset : .zero
            if hostPID != nil { hostedReads += 1 }
            var children = elements.map { record(Token($0.id, pid: pid), label: $0.label, identifier: $0.identifier,
                                                 value: $0.value, visible: $0.visible, frame: $0.frame.offsetBy(dx: shift.x, dy: shift.y)) }
            if let hostPID {
                // A page: rooted at the host's remote element.
                response = Response(kind: 2, translation: root, result: record(Token(77, pid: hostPID), label: nil, identifier: nil, visible: true,
                    frame: rootFrame, children: children, remote: true))
                break
            }
            // A depth-limited snapshot cuts records: their count stays, their children go.
            if depth < 48 {
                children.append(record(Token(99, pid: pid), label: "Cut", identifier: nil, visible: true,
                                       frame: NSRect(x: 0, y: 0, width: 10, height: 10), reportedChildren: 3))
            }
            response = Response(kind: 2, translation: root, result: empty ? nil :
                record(root, label: "App", identifier: nil, visible: true, frame: rootFrame,
                       children: children))
        case 4:
            let current = frontmostPIDs.isEmpty ? pid : frontmostPIDs.removeFirst()
            response = Response(kind: 4, result: noFrontmost ? nil : Token(1, pid: current, application: true))
        case 5:
            var queried: [UInt64] = []
            if case .dictionary(let parameters) = fields["parameters"], case .array(let list) = parameters["attributes"] ?? .null {
                queried = list.compactMap(\.unsignedInteger)
            }
            attributeQueries.append(queried)
            if queried == [19] {
                response = Response(kind: 5, result: (focusedElement.map { [19: Token($0, pid: pid)] } ?? [:]) as NSDictionary)
                break
            }
            let element = elements.first ?? Element()
            var live: [Int: Any] = [21: NSValue(rect: element.frame)]
            if queried.contains(28), let focused = element.focused { live[28] = NSNumber(value: focused) }
            if let enabled = element.enabled { live[27] = NSNumber(value: enabled) }
            if let visible = element.visible { live[32] = NSNumber(value: visible) }
            if let identifier = element.identifier { live[25] = identifier }
            if queried == [3, 21, 25] {
                live[25] = hitHandleIdentifier ?? element.identifier
                live[3] = hitHandleLabel ?? element.label
            }
            if let currentValue { live[53] = currentValue }
            response = Response(kind: 5, result: live as NSDictionary)
        case 3:
            #expect(fields["attributeType"]?.unsignedInteger == 53)
            response = Response(kind: 3, result: NSNumber(value: settable))
        case 8:
            guard fields["attributeType"]?.unsignedInteger == 53, case .dictionary(let parameters) = fields["parameters"],
                  case .string(let value) = parameters["value"] ?? .null else { throw CommandFailure(description: "Bad fixture set-value") }
            onAction?()
            setValues.append(value)
            guard actionResult != nil else { throw CommandFailure(.transportFailed, "Simulator accessibility request failed: no reply", inputSent: .unknown) }
            currentValue = transform(value)
            response = Response(kind: 8, result: nil)
        case 6:
            guard case .dictionary(let parameters) = fields["parameters"], case .object(_, let point) = parameters["point"] ?? .null,
                  case .string(let text) = point["NS.pointval"] ?? .null else { throw CommandFailure(description: "Bad fixture hit") }
            hitPoints.append(NSPointFromString(text))
            hitClientTypes.append(fields["clientType"]?.unsignedInteger ?? 99)
            // Elements are hit in native portrait points, as the simulator does.
            let hit = elements.first { element in
                NSPointInRect(NSPointFromString(text), nativeFrame(element.frame))
            }
            response = Response(kind: 6, result: Token(hit.map { hitHandle ?? $0.id } ?? 1, pid: pid, application: hit == nil))
        case 7:
            onAction?()
            guard let actionResult else { throw CommandFailure(.transportFailed, "Simulator accessibility request failed: no reply", inputSent: .unknown) }
            response = Response(kind: 7, result: NSNumber(value: actionResult))
        default:
            throw CommandFailure(description: "Unexpected fixture request type \(kind)")
        }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.setClassName("AXPTranslatorResponse", for: Response.self)
        coder.setClassName("AXPTranslationObject", for: Token.self)
        coder.encode(response, forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// An interface frame (the tree's) in native portrait points of a 390 × 844
    /// screen, for the fixture's display rotation.
    private func nativeFrame(_ frame: NSRect) -> NSRect {
        guard let display = try? SimulatorDisplay(displayInfo), display.rotation != 0 else { return frame }
        let mapping = SimulatorHitMapping()
        mapping.update(display, SimulatorDeviceTests.info())
        let a = mapping.native(frame.minX, frame.minY), b = mapping.native(frame.maxX, frame.maxY)
        return NSRect(x: min(a.0, b.0), y: min(a.1, b.1), width: abs(a.0 - b.0), height: abs(a.1 - b.1))
    }

    private func record(_ token: Token, label: String?, identifier: String?, value: String? = nil, visible: Bool?,
                        frame: NSRect, children: [NSDictionary] = [], reportedChildren: Int? = nil, remote: Bool = false) -> NSDictionary {
        var attributes: [Int: Any] = [3003: "com.example.fixture"]
        if remote { attributes[5003] = "AXRemoteElement" }
        attributes[2001] = label
        attributes[5019] = identifier
        attributes[2006] = value
        attributes[2025] = visible.map { NSNumber(value: $0) }
        attributes[2003] = NSValue(rect: frame)
        return ["UIAccessibilitySnapshotKeyElement": token, "UIAccessibilitySnapshotKeyChildren": children,
                "UIAccessibilitySnapshotKeyChildrenCount": reportedChildren ?? children.count,
                "UIAccessibilitySnapshotKeyAttributes": attributes as NSDictionary] as NSDictionary
    }
}

@Suite(.cleansLeaseDirectories)
struct SimulatorAccessibilityTests {
    static let uuid = SimulatorDeviceTests.uuid
    static let screen = SimulatorDeviceTests.info()

    /// Responses captured from an iPhone 17e simulator (iOS 27.2) while the
    /// Home Screen was frontmost: the frontmost request's answer, and the empty
    /// answer to its full-depth snapshot.
    static let capturedFrontmost = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGmCwwbKSoxVSRudWxs2A0ODxAREhMUFRYXGBYYGBpWJGNsYXNzXxAcYXNzb2NpYXRlZE5vdGlmaWNhdGlvbk9iamVjdFpyZXN1bHREYXRhWWF0dHJpYnV0ZV8QG2Fzc29jaWF0ZWRUcmFuc2xhdGlvbk9iamVjdFxub3RpZmljYXRpb25VZXJyb3JfEBVhc3NvY2lhdGVkUmVxdWVzdFR5cGWABYAAgAIQAIAAEATXDRwdHh8gISIjFiUlFihTcGlkXnJhd0VsZW1lbnREYXRhXxAUaXNBcHBsaWNhdGlvbkVsZW1lbnRfEBNkaWRQb3B1bGRhdGVBcHBJbmZvXxATYnJpZGdlRGVsZWdhdGVUb2tlblhvYmplY3RJRIAEEgABPr+AAAkJgACAAxQAAAAAAAAAAJqw33WR8WuP0issLS5aJGNsYXNzbmFtZVgkY2xhc3Nlc18QFEFYUFRyYW5zbGF0aW9uT2JqZWN0oi8wXxAUQVhQVHJhbnNsYXRpb25PYmplY3RYTlNPYmplY3TSKywyM18QFUFYUFRyYW5zbGF0b3JSZXNwb25zZaI0MF8QFUFYUFRyYW5zbGF0b3JSZXNwb25zZQAIABEAGgAkACkAMgA3AEkATABRAFMAWgBgAHEAeACXAKIArADKANcA3QD1APcA+QD7AP0A/wEBARABFAEjAToBUAFmAW8BcQF2AXgBeQF6AXwBfgGPAZQBnwGoAb8BwgHZAeIB5wH/AgIAAAAAAAACAQAAAAAAAAA1AAAAAAAAAAAAAAAAAAACGg==")!
    static let capturedEmptySnapshot = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGmCwwcKisyVSRudWxs2A0ODxAREhMUFRYWGBkaGhtWJGNsYXNzXxAcYXNzb2NpYXRlZE5vdGlmaWNhdGlvbk9iamVjdFpyZXN1bHREYXRhWWF0dHJpYnV0ZV8QG2Fzc29jaWF0ZWRUcmFuc2xhdGlvbk9iamVjdFxub3RpZmljYXRpb25VZXJyb3JfEBVhc3NvY2lhdGVkUmVxdWVzdFR5cGWABYAAgAAQNIACEAAQAtcNHR4fICEiIyQWJiYWKVNwaWRecmF3RWxlbWVudERhdGFfEBRpc0FwcGxpY2F0aW9uRWxlbWVudF8QE2RpZFBvcHVsZGF0ZUFwcEluZm9fEBNicmlkZ2VEZWxlZ2F0ZVRva2VuWG9iamVjdElEgAQSAAE+v4AACQmAAIADFAAAAAAAAAAAmrDfdZHxa4/SLC0uL1okY2xhc3NuYW1lWCRjbGFzc2VzXxAUQVhQVHJhbnNsYXRpb25PYmplY3SiMDFfEBRBWFBUcmFuc2xhdGlvbk9iamVjdFhOU09iamVjdNIsLTM0XxAVQVhQVHJhbnNsYXRvclJlc3BvbnNlojUxXxAVQVhQVHJhbnNsYXRvclJlc3BvbnNlAAgAEQAaACQAKQAyADcASQBMAFEAUwBaAGAAcQB4AJcAogCsAMoA1wDdAPUA9wD5APsA/QD/AQEBAwESARYBJQE8AVIBaAFxAXMBeAF6AXsBfAF+AYABkQGWAaEBqgHBAcQB2wHkAekCAQIEAAAAAAAAAgEAAAAAAAAANgAAAAAAAAAAAAAAAAAAAhw=")!

    static func environment(_ fixture: SimulatorAXFixture, state: String = "Booted",
                            sessions: SessionCounter = SessionCounter()) -> SimulatorEnvironment {
        var environment = SimulatorEnvironment(lookup: { _ in SimulatorDeviceTests.info(state) },
                             accessibility: { _, lifetime in sessions.count += 1; sessions.lifetimes.append(lifetime); return fixture.session(lifetime: lifetime) })
        environment.displayInfo = { _ in fixture.displayInfo }
        return environment
    }

    final class SessionCounter: @unchecked Sendable { var count = 0; var lifetimes: [Duration] = [] }

    /// A registry in a fresh directory of its own, for tests that take leases.
    /// Without a directory, the new one is removed after the test by
    /// `.cleansLeaseDirectories`, which the calling suite must carry; a caller
    /// that passes a directory removes it itself.
    static func usableLeases(_ directory: URL? = nil) -> DeviceLeaseRegistry {
        guard let directory else {
            return DeviceLeaseRegistry(directory: LeaseDirectories.register("tmp/simulator-leases-\(UUID().uuidString)"))
        }
        return DeviceLeaseRegistry(directory: directory)
    }

    /// The holder note of the simulator's lease file, while it is held.
    static func leaseHolder(_ directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("\(uuid).lock"), encoding: .utf8)) ?? ""
    }

    /// A registry that cannot create its directory: taking a lease fails, so a
    /// successful command proves no lease was taken.
    static func unusableLeases() throws -> DeviceLeaseRegistry {
        let blocker = LeaseDirectories.register("tmp/simulator-lease-blocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocker)
        return DeviceLeaseRegistry(directory: blocker.appendingPathComponent("leases"))
    }

    static func service(_ fixture: SimulatorAXFixture, state: String = "Booted", leases: DeviceLeaseRegistry? = nil,
                        sessions: SessionCounter = SessionCounter()) throws -> CommandService {
        CommandService(leases: try leases ?? unusableLeases(), simulator: environment(fixture, state: state, sessions: sessions),
                       readinessQuery: { _ in Issue.record("Simulator command queried CoreDevice"); return Data() })
    }

    static func json(_ output: CommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    // MARK: - Parsing and plans

    @Test func treeParsesWithAnOptionalPIDAndRequiresAUUID() throws {
        #expect(try SimulatorInput(device: Self.uuid.lowercased(), operation: "tree", operands: []).device == Self.uuid)
        #expect(try SimulatorInput(device: Self.uuid, operation: "tree", operands: ["0042"]).operands == ["42"])
        #expect(try simulatorInput(["tree", "--pid", "0042", "--simulator", Self.uuid])?.operands == ["42"])
        for invalid in [["0"], ["x"], ["1", "2"]] {
            #expect(throws: CommandFailure.self) { try SimulatorInput(device: Self.uuid, operation: "tree", operands: invalid) }
        }
        let alias = try #require(throws: CommandFailure.self) { try SimulatorInput(device: "booted", operation: "tree", operands: []) }
        #expect(alias.code == .usage)
        // apps is a simctl wrapper, and a device tree is physical input.
        #expect(try simulatorInput(["apps", "--simulator", Self.uuid]) == nil)
        #expect(try simulatorInput(["tree", "--device", Self.uuid]) == nil)
    }

    @Test(arguments: ["paste", "wake"])
    func multiContactAndPhysicalOnlyOperationsAreRefusedPlainly(operation: String) async throws {
        let failure = try #require(throws: CommandFailure.self) { try SimulatorInput(device: Self.uuid, operation: operation, operands: ["0.5"]) }
        #expect(failure.code == .unsupportedOperation && failure.inputSent == .none && failure.retry == .no)
        #expect(failure.description.contains(operation == "paste" ? "set-value with --id or --label" : "not implemented yet"))
        let fixture = SimulatorAXFixture()
        let command = (operation == "paste" ? ["paste", "0.5"] : ["wake"]) + ["--simulator", Self.uuid]
        for dryRun in [false, true] {
            let refused = try #require(await #expect(throws: CommandFailure.self) { _ = try await Self.service(fixture).run(command, dryRun: dryRun) })
            #expect(refused.code == .unsupportedOperation)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func treeDryRunDescribesTheSimulatorRouteWithoutLookingItUp() async throws {
        let fixture = SimulatorAXFixture()
        let service = CommandService(leases: try Self.unusableLeases(), simulator: SimulatorEnvironment(
            lookup: { _ in Issue.record("Dry run looked the simulator up"); return Self.screen },
            accessibility: { _, _ in Issue.record("Dry run opened AX"); return fixture.session() }),
            readinessQuery: { _ in Issue.record("Dry run queried CoreDevice"); return Data() })
        let plan = try Self.json(await service.run(["tree", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["backend"] as? String == "coresimulator-ax" && plan["platform"] as? String == "simulator")
        #expect(plan["operation"] as? String == "tree" && plan["pid"] is NSNull && plan["liveVerified"] as? Bool == false)
        #expect((plan["execution"] as? String)?.contains("frontmost application") == true)
        #expect((plan["deviceLease"] as? String)?.hasPrefix("not taken") == true)
    }

    // MARK: - Tree

    @Test func treeSelectsTheFrontmostApplicationAndKeepsThePhysicalShape() async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(identifier: "probe.touch.summary", label: "Probe summary", value: "{\"v\":1}")]
        let sessions = SessionCounter()
        let tree = try Self.json(await Self.service(fixture, sessions: sessions).run(["tree", "--simulator", Self.uuid]))
        // frontmost, application, snapshot, application recheck, frontmost recheck.
        #expect(fixture.kinds == [4, 1, 2, 1, 4] && sessions.count == 1)
        #expect(tree["format"] as? String == "accessibility-tree" && tree["parsedHierarchy"] as? Bool == true)
        #expect(tree["backend"] as? String == "coresimulator-ax" && tree["platform"] as? String == "simulator")
        #expect(tree["transport"] as? String == "coresimulator" && tree["resolvedSimulatorUUID"] as? String == Self.uuid)
        #expect(tree["resolvedCoreDeviceUUID"] == nil && tree["deviceAPIVersion"] == nil && tree["connectionCleanup"] == nil)
        #expect((tree["application"] as? [String: Any])?["selection"] as? String == "frontmost-or-centre-hit")
        #expect((tree["application"] as? [String: Any])?["pid"] as? Int == 42)
        #expect((tree["cleanup"] as? [String: Any])?["subscriptionStop"] as? String == "not-applicable")
        #expect((tree["display"] as? [String: Any])?["orientation"] as? String == "rot0")
        #expect((tree["screen"] as? [String: Any])?["widthPoints"] as? Int == 390)
        #expect((tree["screen"] as? [String: Any])?["orientation"] as? String == "rot0")
        let nodes = try #require(tree["nodes"] as? [[String: Any]])
        #expect(nodes.count == 2 && tree["nodeCount"] as? Int == 2)
        #expect(nodes[1]["identifier"] as? String == "probe.touch.summary" && nodes[1]["value"] as? String == "{\"v\":1}")
        #expect((nodes[1]["nativeAttributes"] as? [String: String])?["3003"] == "com.example.fixture")
        #expect((nodes[1]["frame"] as? [String: Any])?["width"] as? Int == 80)
        #expect(fixture.timeouts.allSatisfy { $0 <= .seconds(5) })
    }

    @Test(arguments: [("rot90", "landscapeRight"), ("rot270", "landscapeLeft")])
    func landscapeUsesTheInterfaceForFramesAndNativePointsForHits(_ current: String, _ sensor: String) async throws {
        let fixture = SimulatorAXFixture()
        fixture.displayInfo = SimulatorInputTests.displayJSON(current: current, sensor: sensor)
        fixture.rootFrame = NSRect(x: 0, y: 0, width: 844, height: 390)
        // A landscape-only position: wholly outside the 390-point native width.
        fixture.elements = [.init(identifier: "fixture.target", label: "Target", frame: NSRect(x: 600, y: 200, width: 80, height: 40))]
        let tree = try Self.json(await Self.service(fixture).run(["tree", "--simulator", Self.uuid]))
        let display = try #require(tree["display"] as? [String: Any])
        #expect(display["orientation"] as? String == current)
        #expect((display["bounds"] as? [String: Any])?["width"] as? Int == 844 && (display["bounds"] as? [String: Any])?["height"] as? Int == 390)
        #expect((tree["screen"] as? [String: Any])?["interfaceWidthPoints"] as? Int == 844)
        // The press guard accepts the frame and hits its centre in native points.
        let press = try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "fixture.target", "--simulator", Self.uuid]))
        #expect(press["status"] as? String == "accepted")
        let hit = try #require(fixture.hitPoints.last)
        let expected = current == "rot90" ? NSPoint(x: 220, y: 204) : NSPoint(x: 170, y: 640)
        #expect(abs(hit.x - expected.x) < 1e-9 && abs(hit.y - expected.y) < 1e-9)
    }

    /// A portrait-only window letterboxed in a landscape interface (an
    /// iPhone Duo's inner display): frames are the window's, so the hit moves
    /// by the window's centred offset before the native mapping.
    @Test func aLetterboxedWindowMovesTheHitByItsCentredOffset() async throws {
        let fixture = SimulatorAXFixture()
        fixture.displayInfo = SimulatorInputTests.displayJSON(current: "rot90", sensor: "landscapeRight")
        fixture.rootFrame = NSRect(x: 0, y: 0, width: 300, height: 390)
        fixture.elements = [.init(identifier: "fixture.target", label: "Target", frame: NSRect(x: 100, y: 200, width: 80, height: 40))]
        let press = try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "fixture.target", "--simulator", Self.uuid]))
        #expect(press["status"] as? String == "accepted")
        // Interface (140 + 272, 220); rot90 maps (x, y) to native (y, 844 - x).
        let hit = try #require(fixture.hitPoints.last)
        #expect(abs(hit.x - 220) < 1e-9 && abs(hit.y - 432) < 1e-9)
    }

    @Test func treeWithAPIDSkipsForegroundSelection() async throws {
        let fixture = SimulatorAXFixture()
        let tree = try Self.json(await Self.service(fixture).run(["tree", "--pid", "42", "--simulator", Self.uuid]))
        #expect(fixture.kinds == [1, 2, 1])
        #expect((tree["application"] as? [String: Any])?["selection"] as? String == "explicit-pid" && tree["display"] == nil)
    }

    @Test func frontmostChangeDuringTheTreeReturnsNoTree() async throws {
        let fixture = SimulatorAXFixture()
        fixture.frontmostPIDs = [42, 77]
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture).run(["tree", "--simulator", Self.uuid])
        })
        #expect(failure.code == .preconditionChanged && failure.inputSent == .none)
        #expect(failure.description.hasPrefix("Simulator tree failed: Foreground application AX process changed"))
    }

    @Test(arguments: ["Shutdown", "Booting"])
    func unbootedSimulatorRefusesTheTreeBeforeOpeningAccessibility(state: String) async throws {
        let fixture = SimulatorAXFixture()
        let sessions = SessionCounter()
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, state: state, sessions: sessions).run(["tree", "--simulator", Self.uuid])
        })
        #expect(failure.code == .deviceNotReady && failure.inputSent == .none && sessions.count == 0 && fixture.requests.isEmpty)
    }

    @Test func emptySnapshotIsReportedAsTheSimulatorBudgetNotAPartialTree() async throws {
        let fixture = SimulatorAXFixture()
        fixture.emptySnapshot = true
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture).run(["tree", "--simulator", Self.uuid])
        })
        #expect(failure.code == .transportFailed && failure.inputSent == .none)
        #expect(failure.description.contains("no snapshot data"))
    }

    @Test func anEmptyFullDepthSnapshotIsReadAgainShallowerAndSaysSo() async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(identifier: "fixture.target", label: "Settings")]
        fixture.emptyAtFullDepth = true
        fixture.emptyShallowAnswers = 2
        let tree = try Self.json(await Self.service(fixture).run(["tree", "--simulator", Self.uuid]))
        // Full depth empty, then depth 10 once a second until it answers.
        #expect(fixture.snapshotDepths == [48, 10, 10, 10] && fixture.clock.slept == .seconds(2))
        let shallow = try #require(tree["shallowSnapshot"] as? [String: Any])
        #expect(shallow["maxDepth"] as? Int == 10 && shallow["pids"] as? [Int] == [42] && shallow["truncatedRecords"] as? Int == 1)
        #expect(shallow["waitedMilliseconds"] as? Int == 2000)
        let nodes = try #require(tree["nodes"] as? [[String: Any]])
        #expect(nodes.contains { $0["label"] as? String == "Settings" } && nodes.contains { $0["label"] as? String == "Cut" })
        // Later snapshots of the same process in the session go shallow at once.
        let press = SimulatorAXFixture()
        press.elements = [.init(identifier: "fixture.target", label: "Settings")]
        press.emptyAtFullDepth = true
        let receipt = try Self.json(await Self.service(press, leases: Self.usableLeases()).run(["press", "--label", "Settings", "--simulator", Self.uuid]))
        #expect(receipt["status"] as? String == "accepted" && press.snapshotDepths == [48, 10, 10])
        // A process with a full answer is never read shallower.
        let normal = SimulatorAXFixture()
        let plain = try Self.json(await Self.service(normal).run(["tree", "--simulator", Self.uuid]))
        #expect(normal.snapshotDepths == [48] && plain["shallowSnapshot"] == nil && normal.clock.slept == .zero)
    }

    /// The probe's inset web view on an iOS 27.2 simulator, 2026-11-22: the
    /// first snapshot of a page has frames relative to its web view, the
    /// next on the screen. The first one of a page in a session is read again.
    @Test func aPagesFirstSnapshotIsReadAgainForScreenFrames() async throws {
        let fixture = SimulatorAXFixture()
        fixture.hostPID = 7
        fixture.hostOffset = NSPoint(x: 40, y: 154)
        fixture.elements = [.init(identifier: nil, label: "Top button", frame: NSRect(x: 12, y: 95, width: 298, height: 49))]
        let tree = try Self.json(await Self.service(fixture).run(["tree", "--pid", "42", "--simulator", Self.uuid]))
        #expect(fixture.snapshotDepths == [48, 48])
        let nodes = try #require(tree["nodes"] as? [[String: Any]])
        let button = try #require(nodes.first { $0["label"] as? String == "Top button" })
        let frame = try #require(button["frame"] as? [String: Any])
        #expect(frame["x"] as? Double == 52 && frame["y"] as? Double == 249)
    }

    @Test func truncatedRecordsAreClosedAndCounted() {
        let leaf: AccessibilityArchiveValue = .dictionary(["UIAccessibilitySnapshotKeyChildren": .array([]), "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(4)])
        let whole: AccessibilityArchiveValue = .dictionary(["UIAccessibilitySnapshotKeyChildren": .array([]), "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(0)])
        let root: AccessibilityArchiveValue = .dictionary(["UIAccessibilitySnapshotKeyChildren": .array([leaf, whole]), "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(2)])
        var count = 0
        guard case .dictionary(let closed) = SimulatorAccessibilitySession.closingTruncatedRecords(root, count: &count),
              case .array(let children) = closed["UIAccessibilitySnapshotKeyChildren"] else { Issue.record("shape"); return }
        #expect(count == 1 && closed["UIAccessibilitySnapshotKeyChildrenCount"] == .unsigned(2))
        #expect(children == [.dictionary(["UIAccessibilitySnapshotKeyChildren": .array([]), "UIAccessibilitySnapshotKeyChildrenCount": .unsigned(0)]), whole])
    }

    @Test func withoutAFrontmostApplicationTheScreenCentreProcessIsSelected() async throws {
        let fixture = SimulatorAXFixture()
        fixture.noFrontmost = true
        let tree = try Self.json(await Self.service(fixture).run(["tree", "--simulator", Self.uuid]))
        // frontmost (none), centre hit, application, snapshot, application,
        // frontmost (none) and centre hit again for the recheck.
        #expect(fixture.kinds == [4, 6, 1, 2, 1, 4, 6])
        #expect((tree["application"] as? [String: Any])?["selection"] as? String == "frontmost-or-centre-hit")
        #expect(tree["foregroundSelection"] as? [String: Int] == ["frontmost": 0, "centre-hit": 2])
        // A frontmost application is used when there is one.
        let normal = SimulatorAXFixture()
        let selected = try Self.json(await Self.service(normal).run(["tree", "--simulator", Self.uuid]))
        #expect(selected["foregroundSelection"] as? [String: Int] == ["frontmost": 2, "centre-hit": 0])
        // An explicit PID needs neither.
        let explicit = SimulatorAXFixture()
        explicit.noFrontmost = true
        let pid = try Self.json(await Self.service(explicit).run(["tree", "--pid", "42", "--simulator", Self.uuid]))
        #expect(explicit.kinds == [1, 2, 1] && pid["foregroundSelection"] == nil)
    }

    @Test func capturedSimulatorResponsesDecodeWithThePhysicalDecoder() throws {
        let frontmost = try AccessibilityResponse(archive: Self.capturedFrontmost)
        #expect(frontmost.requestType == 4 && frontmost.error == 0 && frontmost.attribute == 0)
        let token = try AccessibilityResponse.token(#require(try frontmost.matchingResult(for: .frontmost)))
        #expect(token.pid == 81599 && token.isApplicationElement && token.didPopulateAppInfo && token.bridgeDelegateToken == nil)
        // The empty Home Screen snapshot through the simulator session: full
        // depth, then the shallow depth once a second for the retry window.
        var replies = [Self.capturedFrontmost]
        let clock = VirtualClock()
        let session = SimulatorAccessibilitySession(carrier: { _, _ in replies.isEmpty ? Self.capturedEmptySnapshot : replies.removeFirst() },
                                                    now: clock.now, cancelled: { false }, sleep: clock.sleep)
        try session.start()
        let root = try #require(try session.frontmost())
        let failure = try #require(throws: CommandFailure.self) { try session.snapshot(root) }
        #expect(failure.description.contains("at full depth and at depth 10"))
        #expect(session.requests == 1 + 1 + 13 && clock.slept == .seconds(12))
        // Any failure closes the session.
        #expect(throws: CommandFailure.self) { try session.frontmost() }
    }

    @Test func sessionRefusesMismatchedRepliesDeadlinesAndUseAfterClose() throws {
        let fixture = SimulatorAXFixture()
        // A frontmost reply to an application request does not satisfy it.
        let mismatched = SimulatorAccessibilitySession(carrier: { _, _ in Self.capturedFrontmost }, cancelled: { false })
        try mismatched.start()
        #expect(throws: CommandFailure.self) { try mismatched.application(pid: 81599) }
        // The whole-session lifetime bounds every request.
        let expired = SimulatorAccessibilitySession(carrier: fixture.carrier(), lifetime: .zero, cancelled: { false })
        try expired.start()
        #expect(throws: CommandFailure.self) { try expired.frontmost() }
        #expect(fixture.requests.isEmpty)
        let session = fixture.session()
        #expect(throws: CommandFailure.self) { try session.frontmost() }   // not started
        try session.start()
        #expect(throws: CommandFailure.self) { try session.start() }
        #expect(session.close() == .notApplicable && session.close() == .notApplicable)
        #expect(throws: CommandFailure.self) { try session.frontmost() }
        let cancelled = SimulatorAccessibilitySession(carrier: fixture.carrier(), cancelled: { true })
        #expect(throws: CancellationError.self) { try cancelled.start() }
    }

    // MARK: - Selector actions and waits

    static func pressable() -> SimulatorAXFixture {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(identifier: "probe.touch.reset", label: "Reset probe")]
        return fixture
    }

    @Test func selectorActionsAndWaitsParseLikePhysical() throws {
        for args in [["press-id", "probe.touch.reset"], ["press-label", "42", "Reset probe"], ["scroll-id", "row"],
                     ["wait-id", "x", "--until", "gone", "--timeout", "0"], ["wait-label", "42", "Done", "--value", "v"]] {
            let input = try SimulatorInput(device: Self.uuid, operation: args[0], operands: Array(args.dropFirst()))
            #expect(input.operation == args[0] && input.operands == Array(args.dropFirst()))
        }
        for invalid in [["press-id"], ["press-id", "0", "x"], ["scroll-label", ""], ["wait-id", "x", "--timeout", "99"], ["wait-id", "x", "--bogus", "1"]] {
            let failure = try #require(throws: CommandFailure.self) {
                try SimulatorInput(device: Self.uuid, operation: invalid[0], operands: Array(invalid.dropFirst()))
            }
            #expect(failure.code == .usage && failure.inputSent == .none)
        }
    }

    @Test func pressSendsOneActionAfterTheSharedGuardsAndTakesTheLease() async throws {
        let fixture = Self.pressable()
        let directory = URL(fileURLWithPath: "tmp/simulator-leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let leases = Self.usableLeases(directory)
        var holder = ""
        fixture.onAction = { holder = Self.leaseHolder(directory) }
        let output = try await Self.service(fixture, leases: leases).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        #expect(holder.contains("press-id") && holder.contains("pid \(getpid())"))
        #expect(Self.leaseHolder(directory).isEmpty)
        let receipt = try Self.json(output)
        // frontmost, application, two snapshots, live attributes, hit at the
        // target centre, application and frontmost rechecks, then one press.
        #expect(fixture.kinds == [4, 1, 2, 2, 5, 6, 1, 4, 7])
        #expect(fixture.requests.last?.action == 5)
        #expect(receipt["status"] as? String == "accepted" && receipt["nativeAccepted"] as? Bool == true)
        #expect(receipt["backend"] as? String == "coresimulator-ax" && receipt["platform"] as? String == "simulator")
        #expect(receipt["verified"] as? Bool == false && receipt["effectVerified"] as? Bool == false)
        #expect((receipt["application"] as? [String: Any])?["selection"] as? String == "frontmost-or-centre-hit")
        #expect(receipt["foregroundSelection"] as? [String: Int] == ["frontmost": 2, "centre-hit": 0])
        #expect((receipt["target"] as? [String: Any])?["identifier"] as? String == "probe.touch.reset")
        // The lease was released afterwards: another holder can take it.
        let after = try leases.acquire(device: Self.uuid, operation: "check")
        after.release()
    }

    /// Element hits ask with client type 0, as on a phone: with type 2 an
    /// iPhone Duo and an Apple TV answered a row's centre with an outer
    /// container, so press refused the row as "another native element". Only
    /// the centre hit that selects the process asks for a container (type 2).
    @Test func elementHitsUseClientTypeZeroAndProcessSelectionTwo() async throws {
        let fixture = Self.pressable()
        fixture.noFrontmost = true
        _ = try await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        // centre hit (selection), element hit at the target, centre hit (recheck).
        #expect(fixture.hitClientTypes == [2, 0, 2])
        let framed = Self.pressable()
        _ = try await Self.service(framed, leases: Self.usableLeases()).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        #expect(framed.hitClientTypes == [0])
    }

    /// A plain table row answers a hit by another object than the one the
    /// tree holds. It is accepted when it has the row's frame and its
    /// identifier, or its label for a row with no identifier, and refused
    /// when it has another's.
    @Test func aHitThatAnswersTheSameElementByAnotherObjectIsAccepted() async throws {
        func press(_ selector: [String], identifier: String? = "probe.list.row.31", handleIdentifier: String? = nil,
                   handleLabel: String? = nil) async throws -> [String: Any] {
            let fixture = SimulatorAXFixture()
            fixture.elements = [.init(identifier: identifier, label: "Row 31")]
            fixture.hitHandle = 77
            fixture.hitHandleIdentifier = handleIdentifier
            fixture.hitHandleLabel = handleLabel
            return try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["press"] + selector + ["--simulator", Self.uuid]))
        }
        #expect(try await press(["--id", "probe.list.row.31"])["status"] as? String == "accepted")
        #expect(try await press(["--label", "Row 31"], identifier: nil)["status"] as? String == "accepted")
        await #expect { _ = try await press(["--id", "probe.list.row.31"], handleIdentifier: "probe.list.row.32") }
            throws: { "\($0)".contains("another native element") }
        await #expect { _ = try await press(["--label", "Row 31"], identifier: nil, handleLabel: "Cover") }
            throws: { "\($0)".contains("another native element") }
    }

    /// An element may reach past an edge of the display (a field on a zoomed
    /// web page: 392 points on a 375-point display). Its centre must be on
    /// the display and hit the element itself.
    @Test func pressAcceptsAnElementPartlyOffTheDisplayWhenItsCentreIsOnIt() async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(identifier: "wide", label: "Wide", frame: NSRect(x: -20, y: 200, width: 420, height: 40))]
        let press = try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "wide", "--simulator", Self.uuid]))
        #expect(press["status"] as? String == "accepted")
        let hit = try #require(fixture.hitPoints.last)
        #expect(abs(hit.x - 190) < 1e-9 && abs(hit.y - 220) < 1e-9)
        // Centre beyond the right edge (390 points): refused, nothing sent.
        let off = SimulatorAXFixture()
        off.elements = [.init(identifier: "wide", label: "Wide", frame: NSRect(x: 380, y: 200, width: 80, height: 40))]
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(off, leases: Self.usableLeases()).run(["press", "--id", "wide", "--simulator", Self.uuid])
        })
        #expect(failure.code == .targetUnresolved && failure.inputSent == .none)
        #expect(failure.description.contains("target centre is outside the primary display") && !off.kinds.contains(7))
    }

    /// An element with neither identifier nor label is selected by its value.
    @Test func pressSelectsAnElementByItsValue() async throws {
        let fixture = SimulatorAXFixture()
        fixture.elements = [.init(id: 2, identifier: nil, label: nil, value: "Buscar"),
                            .init(id: 3, identifier: "other", label: "Other", value: "x", frame: NSRect(x: 100, y: 300, width: 80, height: 40))]
        let press = try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--with-value", "Buscar", "--simulator", Self.uuid]))
        #expect(press["status"] as? String == "accepted" && (press["selector"] as? [String: String]) == ["by": "value", "text": "Buscar"])
        #expect((press["target"] as? [String: Any])?["value"] as? String == "Buscar")
        let missing = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--with-value", "Other", "--simulator", Self.uuid])
        })
        #expect(missing.code == .targetUnresolved && missing.inputSent == .none)
    }

    @Test func pressIsRefusedWhenTheSimulatorIsBusyOrUnbooted() async throws {
        let fixture = Self.pressable()
        let unusable = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        })
        #expect(unusable.code == .hostRequirement && unusable.inputSent == .none)
        let unbooted = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, state: "Shutdown", leases: Self.usableLeases()).run(["press", "--label", "Reset probe", "--simulator", Self.uuid])
        })
        #expect(unbooted.code == .deviceNotReady && unbooted.inputSent == .none)
        #expect(fixture.requests.isEmpty)
    }

    @Test func pressWithAnotherPIDOrAMissingTargetSendsNoAction() async throws {
        let fixture = Self.pressable()
        let foreign = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "probe.touch.reset", "--pid", "7", "--simulator", Self.uuid])
        })
        #expect(foreign.code == .targetUnresolved && foreign.inputSent == .none)
        #expect(foreign.description.contains("requested PID differs from foreground application process"))
        let missing = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "absent", "--simulator", Self.uuid])
        })
        #expect(missing.code == .targetUnresolved && missing.inputSent == .none)
        #expect(!fixture.kinds.contains(7))
    }

    @Test func actionWithoutAUsableReplyIsAnUnknownOutcome() async throws {
        let fixture = Self.pressable()
        fixture.actionResult = nil
        let failure = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(fixture, leases: Self.usableLeases()).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        })
        #expect(failure.code == .inputOutcomeUnknown && failure.inputSent == .possible && failure.retry == .afterInspection)
        #expect(failure.description.contains("state=submitted"))
        let refused = Self.pressable()
        refused.actionResult = false
        let refusal = try #require(await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(refused, leases: Self.usableLeases()).run(["press", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        })
        #expect(refusal.code == .inputOutcomeUnknown && refusal.description.contains("state=refused"))
    }

    /// A simulator search gets the search's allowance, as a physical one does:
    /// with the standard 30 s a staggered list's search of 40 steps ran out.
    @Test func searchSessionLifetimeScalesWithItsSteps() async throws {
        let sessions = SessionCounter()
        _ = try await Self.service(Self.pressable(), leases: Self.usableLeases(), sessions: sessions)
            .run(["scroll", "--label", "Reset probe", "--search", "40", "--simulator", Self.uuid])
        _ = try await Self.service(Self.pressable(), leases: Self.usableLeases(), sessions: sessions)
            .run(["scroll", "--label", "Reset probe", "--simulator", Self.uuid])
        #expect(sessions.lifetimes == [.seconds(30 + 3 * 40), .seconds(30)])
    }

    @Test func scrollReportsItsPostcondition() async throws {
        let fixture = Self.pressable()
        let receipt = try Self.json(await Self.service(fixture, leases: Self.usableLeases()).run(["scroll", "--label", "Reset probe", "--simulator", Self.uuid]))
        #expect(fixture.requests.filter { $0.kind == 7 }.map(\.action) == [11])
        #expect(receipt["status"] as? String == "postcondition-verified" && receipt["nativeResult"] as? Bool == true)
        #expect(receipt["operation"] as? String == "scroll-to-visible")
    }

    @Test func waitIsReadOnlyTakesNoLeaseAndAnswersATimeoutWith124() async throws {
        let present = Self.pressable()
        let sessions = SessionCounter()
        let met = try await Self.service(present, sessions: sessions).run(["wait", "--id", "probe.touch.reset", "--simulator", Self.uuid])
        #expect(met.exitCode == 0)
        let json = try Self.json(met)
        #expect(json["status"] as? String == "condition-met" && json["readOnly"] as? Bool == true)
        #expect((json["application"] as? [String: Any])?["selection"] as? String == "frontmost-or-centre-hit-per-poll")
        #expect(json["resolvedSimulatorUUID"] as? String == Self.uuid && json["displayRecheck"] as? String == "unchanged")
        #expect(present.kinds == [4, 1, 2, 5, 1, 4] && !present.kinds.contains(7))
        // The session's whole life scales with the wait, as for physical.
        #expect(sessions.lifetimes == [.seconds(40)])
        let absent = SimulatorAXFixture()
        let timedOut = try await Self.service(absent).run(["wait", "--id", "probe.touch.reset", "--timeout", "0", "--simulator", Self.uuid])
        #expect(timedOut.exitCode == AccessibilityWait.timeoutExitCode)
        #expect(try Self.json(timedOut)["status"] as? String == "timed-out")
    }

    @Test func waitTreatsAFrontmostChangeWithinAPollAsNotMet() async throws {
        let fixture = Self.pressable()
        // Selected 42, but the recheck finds another app frontmost.
        fixture.frontmostPIDs = [42, 77]
        let output = try await Self.service(fixture).run(["wait", "--id", "probe.touch.reset", "--timeout", "0", "--simulator", Self.uuid])
        let json = try Self.json(output)
        #expect(output.exitCode == AccessibilityWait.timeoutExitCode && json["status"] as? String == "timed-out")
        let observation = try #require(json["observation"] as? [String: Any])
        #expect(observation["reason"] as? String == "selection-changed")
        #expect((observation["detail"] as? String)?.contains("foreground application process changed") == true)
    }

    @Test func actionAndWaitDryRunsDescribeTheSimulatorRoute() async throws {
        let fixture = SimulatorAXFixture()
        let service = try Self.service(fixture, state: "Shutdown")
        let press = try Self.json(await service.run(["press", "--label", "Reset probe", "--pid", "42", "--simulator", Self.uuid], dryRun: true))
        #expect(press["backend"] as? String == "coresimulator-ax" && press["operation"] as? String == "press")
        #expect(press["pid"] as? Int == 42 && (press["selector"] as? [String: String]) == ["by": "label", "text": "Reset probe"])
        #expect(press["deviceLease"] as? String == "simulator UUID" && press["identityArguments"] == nil)
        let wait = try Self.json(await service.run(["wait", "--id", "x", "--timeout", "3", "--simulator", Self.uuid], dryRun: true))
        #expect(wait["backend"] as? String == "coresimulator-ax" && wait["operation"] as? String == "wait" && wait["readOnly"] as? Bool == true)
        #expect(wait["maximumPolls"] as? Int == 8 && wait["identityArguments"] == nil && wait["platform"] as? String == "simulator")
        #expect((wait["execution"] as? String)?.contains("foreground application") == true)
        #expect(fixture.requests.isEmpty)
    }
}
