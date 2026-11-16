import AppleDeviceBridge
import Foundation

/// Simulator input and accessibility in process: argument validation, dry-run
/// plans and routing. Execution lives in `DirectSimulator*`, and the
/// connections in `AppleSimulatorBridge.m`. The operands, coordinate space,
/// receipts and error categories are those of the physical commands.
struct SimulatorInput: Sendable, Equatable {
    let device: String
    let operation: String
    let operands: [String]

    static let selectorActions = ["press-id", "press-label", "scroll-id", "scroll-label"]
    static let accessibilityOperations = ["tree"] + selectorActions + DirectAccessibilitySetValue.operations + AccessibilityWait.operations
    /// Indigo digitizer schedules: one contact, or two for pinch and a
    /// two-path multi-drag (pointOne and pointTwo), as on physical devices.
    static let touchOperations = ["tap", "long-press", "swipe", "drag", "pinch", "multi-drag"]
    /// Universal HID complete-state reports: multi-tap, gesture, and
    /// multi-drag with three to five paths (`DirectPhysicalGesture.handles`).
    static let gestureOperations = ["multi-tap", "gesture"]
    static let inputOperations = touchOperations + gestureOperations + ["button", "key", "type"] + familyOperations
    /// Apple TV, Apple Watch and iPhone Duo controls (docs/other-families.md).
    static let familyOperations = ["remote", "crown"] + SimulatorHinge.operations
    static let operations = accessibilityOperations + inputOperations
    /// Operations that exist for physical devices but not yet for simulators.
    static let unimplemented = ["paste", "wake"]

    /// Whether the input travels as Universal HID reports rather than Indigo
    /// digitizer events; the same rule as physical routing.
    var usesUniversalHID: Bool { DirectPhysicalGesture.handles(coreDeviceInput) }
    /// The physical consumer-page usages; volume shows the system HUD on a simulator.
    static let buttons: [String: UInt64] = ["home": 64, "lock": 48, "volume-up": 233, "volume-down": 234]

    /// Same rule as physical: trees and waits only read, take no lease and are
    /// not paused by a pending handoff.
    static let observations = ["tree"] + AccessibilityWait.operations + [SimulatorHinge.angleOperation]

    var isObservation: Bool { Self.observations.contains(operation) }
    var coreDeviceInput: CoreDeviceInput { CoreDeviceInput(device: device, operation: operation, operands: operands) }

    /// One simulator input or accessibility operation with its operands
    /// checked, before any simulator lookup. Paste and wake are refused, and
    /// an operation the simulator route lacks is unsupported.
    init(device: String, operation: String, operands: [String]) throws {
        if operation == "paste" {
            // simctl pbcopy did not reach the pasteboard the simulator pastes
            // from (docs/simulator-input.md), so Command+V could insert text
            // the caller never supplied.
            throw CommandFailure.unsupported("Simulator paste is refused: simctl pbcopy did not change the simulator's pasteboard in testing, so a paste could insert other text. For Unicode text use set-value with --id or --label, which replaces a named element's value without the clipboard. No input sent.")
        }
        if Self.unimplemented.contains(operation) {
            throw CommandFailure.unsupported("Simulator \(operation) is not implemented yet; simulator input covers touch with one to five contacts, gesture sequences, button, key and type. Wake remains physical-only. No input sent.")
        }
        guard Self.operations.contains(operation) else {
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        let device = try SimulatorDevice.requireUUID(device, operation: operation)
        var operands = operands
        let probe = CoreDeviceInput(device: device, operation: operation, operands: operands)
        switch operation {
        case "tree":
            if !operands.isEmpty {
                guard operands.count == 1, let pid = Int32(operands[0]), pid > 0 else {
                    throw CommandFailure.usage("Simulator tree accepts one PID in 1...2147483647, or no PID for the foreground application.")
                }
                operands = [String(pid)]
            }
        case let value where Self.selectorActions.contains(value):
            _ = try DirectAccessibilityAction(probe)
        case let value where DirectAccessibilitySetValue.operations.contains(value):
            _ = try DirectAccessibilitySetValue(probe)
        case let value where AccessibilityWait.operations.contains(value):
            _ = try AccessibilityWait(probe)
        case "long-press":
            guard operands.count == 3, let x = Double(operands[0]), let y = Double(operands[1]),
                  let seconds = Double(operands[2]), x.isFinite, y.isFinite, seconds.isFinite,
                  (0...1).contains(x), (0...1).contains(y), (0.1...10).contains(seconds) else {
                throw CommandFailure.usage("Simulator long-press requires normalized x/y in 0...1 and duration 0.1...10 seconds.")
            }
            operands = [x, y, seconds].map { String($0) }
        case "tap", "swipe", "drag", "key":
            try PhysicalInputOperands.validate(operation, operands, subject: "Simulator")
        case "pinch", "multi-drag", "multi-tap":
            try PhysicalInputOperands.validate(operation, operands, subject: "Simulator")
            if DirectPhysicalGesture.handles(probe) {
                _ = try DirectPhysicalGesture.sequence(for: probe)
            } else {
                // Overlapping or crossing paths are refused here, before any lookup.
                _ = try DirectPhysicalTouch.plan(probe, display: DirectTouchDisplay(portraitPoints: 1, height: 1, scale: 1))
            }
        case "gesture":
            guard operands.count == 1 else { throw CommandFailure.usage("Simulator gesture requires one JSON sequence argument.") }
            _ = try NativeGestureSequence(json: operands[0])
        case "button":
            guard operands.count == 1, Self.buttons[operands[0]] ?? DigitalCrown.watchButtons[operands[0]] != nil else {
                throw CommandFailure.usage("Supported simulator buttons: home, lock, volume-up, volume-down; no input sent.")
            }
        case "remote":
            guard operands.count == 1, AppleTVRemote.routes[operands[0]] != nil else { throw CommandFailure.usage(AppleTVRemote.usage) }
        case "crown":
            guard (1...2).contains(operands.count) else { throw CommandFailure.usage(DigitalCrown.usage) }
            let units = try DigitalCrown.units(operands[0])
            operands = [String(units), String(try DigitalCrown.events(operands.count == 2 ? operands[1] : nil, units: units))]
        case "fold", "unfold":
            guard operands.isEmpty else { throw CommandFailure.usage("\(operation) takes no operands; no input sent.") }
        case "hinge":
            guard operands.count == 1 else { throw CommandFailure.usage(SimulatorHinge.usage) }
            operands = [String(try SimulatorHinge.degrees(operands[0]))]
        case SimulatorHinge.angleOperation:
            guard operands.isEmpty else { throw CommandFailure.usage(SimulatorHinge.usage) }
        case "type":
            operands = try DirectPhysicalTyping.operands(operands, subject: "Simulator")
        default:
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        self.device = device
        self.operation = operation
        self.operands = operands
    }

    /// The dry-run plan: what would run, without looking the simulator up.
    func plan() throws -> [String: Any] {
        var plan: [String: Any] = ["platform": "simulator", "device": device, "operation": operation, "liveVerified": false,
                                   "bootRequirement": "Refused unless CoreSimulator reports the simulator Booted; never booted implicitly."]
        let route = "In-process CoreSimulator: archived AXPTranslatorRequest objects through -[SimDevice sendAccessibilityRequestAsync:], one request at a time, no subscription."
        if operation == "tree" {
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["pid"] = operands.first.flatMap(Int.init).map { $0 as Any } ?? NSNull()
            plan["deviceLease"] = "not taken (observation)"
            plan["execution"] = "\(route) Omitted PID selects and rechecks the foreground application: the frontmost application (request type 4), or the element under the screen centre (client type 2) when the simulator reports none; application, snapshot and application identity recheck as on physical devices. On an Apple TV simulator one more read-only request (attribute 19, the application's focused element) marks that node focused. No helper or fallback."
        } else if Self.selectorActions.contains(operation) {
            let action = try DirectAccessibilityAction(coreDeviceInput)
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["operation"] = action.operation
            plan["selector"] = ["by": action.by, "text": action.text]
            plan["pid"] = action.pid.map { Int($0) as Any } ?? NSNull()
            plan["deviceLease"] = "simulator UUID"
            plan["execution"] = "\(route) Foreground selection (frontmost application, else the screen-centre process), two unique snapshots and live state/frame guards before one action, as on physical devices. Press checks an exact hit (client type 2) at the target centre; scroll follows with fresh visibility/frame/hit and selection checks. No fallback or replay."
        } else if DirectAccessibilitySetValue.operations.contains(operation) {
            let action = try DirectAccessibilitySetValue(coreDeviceInput)
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["operation"] = action.operation
            plan["selector"] = ["by": action.guards.by, "text": action.guards.text]
            plan["pid"] = action.guards.pid.map { Int($0) as Any } ?? NSNull()
            plan["requestedUTF8Bytes"] = action.value.utf8.count
            plan["deviceLease"] = "simulator UUID"
            plan["execution"] = "\(route) Foreground selection, two unique snapshots, live state/frame guards and an exact centre hit as for press; then a settable query (request type 3, attribute 53) that must answer true, one set-value request (type 8, attribute 53) replacing the element's whole value, and one read-back of the value. No keyboard, clipboard, fallback or replay."
        } else if AccessibilityWait.operations.contains(operation) {
            let wait = try AccessibilityWait(coreDeviceInput)
            plan.merge(wait.plan(identityArguments: [])) { _, shared in shared }
            plan.removeValue(forKey: "identityArguments")
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["execution"] = "\(route) Omitted PID re-selects the foreground application (frontmost, else the screen-centre process) on every poll; an explicit PID is observed even in the background. Each poll reads application identity and one bounded snapshot, evaluates the exact selector, and rechecks the selection before reporting a met condition. No input, fallback or reconnection."
        } else if usesUniversalHID {
            let sequence = try DirectPhysicalGesture.sequence(for: coreDeviceInput)
            plan["backend"] = DirectSimulatorInput.backend
            plan["operands"] = operands
            plan["deviceLease"] = "simulator UUID"
            plan["frameCount"] = sequence.times.count
            plan["contactSlots"] = sequence.contactCount
            plan["durationMilliseconds"] = sequence.times.last ?? 0
            plan["coordinateSpace"] = "normalized-current-interface"
            plan["execution"] = "Read the simulator's display information (dtdeviceinfod) twice: awake primary display, orientation, unique identifier. Then in-process host XPC to the simulator's dtuhidd Universal HID service (com.apple.coredevice.feature.remote.universalhidservice): readiness barrier, connectedServices must list exactly one touchscreen for the primary display, the physical complete-state report schedule, all-up report on stop, completion barrier and a short drain before disconnect. No helper executable or automatic replay."
        } else if Self.touchOperations.contains(operation) {
            let samples = try DirectPhysicalTouch.plan(coreDeviceInput, display: DirectTouchDisplay(portraitPoints: 1, height: 1, scale: 1))
            plan["backend"] = DirectSimulatorInput.backend
            plan["operands"] = operands
            plan["deviceLease"] = "simulator UUID"
            plan["sampleCount"] = samples.count
            plan["contactCount"] = samples.first?.second == nil ? 1 : 2
            plan["coordinateSpace"] = "normalized-current-interface"
            plan["execution"] = "Read the simulator's display information (dtdeviceinfod) twice around planning: awake primary display and its orientation, which rotates the coordinates into the portrait-native digitizer as on a phone. Then in-process host XPC to the simulator's dtuhidd (com.apple.coredevice.feature.remote.hid.digitizer): readiness barrier, the physical Indigo digitizer schedule\(samples.first?.second == nil ? "" : " with both contacts in each event (pointOne, pointTwo)"), release on stop, completion barrier and a short drain before disconnect. No helper executable or automatic replay."
        } else if SimulatorHinge.operations.contains(operation) {
            plan.merge(SimulatorHinge.plan(self)) { $1 }
        } else if Self.inputOperations.contains(operation) {
            plan["backend"] = DirectSimulatorInput.backend
            plan["operands"] = operands
            plan["deviceLease"] = "simulator UUID"
            let service: String
            switch operation {
            case "crown":
                plan.merge(DigitalCrown.describe(Int(operands[0]) ?? 0, events: Int(operands[1]))) { $1 }
                plan["family"] = "Refused unless CoreSimulator reports the Apple Watch product family."
                service = "com.apple.coredevice.feature.remote.hid.scroll"
            case "remote":
                let route = AppleTVRemote.routes[operands[0]]!
                plan.merge(AppleTVRemote.describe(route)) { $1 }
                plan["family"] = "Refused unless CoreSimulator reports the Apple TV product family."
                plan["holdMilliseconds"] = AppleTVRemote.holdMicroseconds / 1000
                service = AppleTVRemote.describe(route)["service"] as! String
            case "button":
                service = "com.apple.coredevice.feature.remote.hid.button"
                plan["usage"] = Self.buttons[operands[0]] ?? DigitalCrown.watchButtons[operands[0]]
                plan["holdMilliseconds"] = operands[0] == "lock" ? 400 : 80
            case "key":
                service = "com.apple.coredevice.feature.remote.hid.keyboard"
                plan["usage"] = DirectPhysicalKeyboard.usages[operands[0]]
            default:
                service = "com.apple.coredevice.feature.remote.hid.keyboard"
                let (text, layout) = try DirectPhysicalTyping.request(operands, subject: "Simulator")
                plan.merge(DirectPhysicalTyping.fields(text, layout: layout, samples: try layout.samples(text))) { _, new in new }
                plan["deviceLayoutCheck"] = DeviceKeyboardLayout.simulatorPlan(layout)
            }
            plan["execution"] = "In-process host XPC to the simulator's dtuhidd (\(service)): readiness barrier, the physical Indigo \(service.hasSuffix(".button") ? "button press" : service.hasSuffix(".scroll") ? "scroll events" : "keyboard schedule") with release on stop, completion barrier and a short drain before disconnect. No clipboard, helper executable or automatic replay."
        }
        return plan
    }
}

/// The simulator connections, injectable for tests. Production values call
/// the bridge; every closure runs on the command service's own thread.
struct SimulatorEnvironment: Sendable {
    var lookup: @Sendable (String) throws -> SimulatorDeviceInfo
    /// Opens an accessibility session whose whole life is bounded by the duration.
    var accessibility: @Sendable (String, Duration) throws -> any AccessibilityExchange
    /// Sends one single-contact schedule; throws `CommandFailure.inputDispatch` failures.
    var touch: @Sendable (String, [ADCTouchSample]) throws -> Void = DirectSimulatorInput.touch
    /// Sends one two-contact digitizer schedule (pinch, two-path multi-drag).
    var twoContactTouch: @Sendable (String, [ADCTouchSample], [ADCTouchPoint]) throws -> Void = DirectSimulatorInput.twoContactTouch
    /// Universal HID complete-state reports for the primary display's
    /// touchscreen: device, display unique identifier, nanosecond offsets and
    /// 58-byte reports. Returns the touchscreen's service identifier.
    var digitizerReports: @Sendable (String, String, [UInt64], [UInt8]) throws -> UInt64 = DirectSimulatorInput.digitizerReports
    /// The simulator's display information as devicectl-shaped JSON.
    var displayInfo: @Sendable (String) throws -> Data = DirectSimulatorInput.displayInfo
    /// A complete keyboard schedule (`type`).
    var keyboard: @Sendable (String, [ADCKeyboardSample]) throws -> Void = DirectSimulatorInput.keyboard
    /// The simulator's `com.apple.keyboard.preferences` as an XML plist, read
    /// before typing to compare its hardware layout with the requested one.
    var keyboardPreferences: @Sendable (String) throws -> Data = { uuid in
        try ToolRunner().run(DeviceKeyboardLayout.simulatorRead(uuid), timeout: 15)
    }
    /// One named key (`key`).
    var key: @Sendable (String, UInt64) throws -> Void = DirectSimulatorInput.key
    /// One button press: usage and hold in microseconds.
    var button: @Sendable (String, UInt64, UInt32) throws -> Void = DirectSimulatorInput.button
    /// One Apple TV remote consumer button: usage and hold in microseconds.
    var remoteButton: @Sendable (String, UInt64, UInt32) throws -> Void = DirectSimulatorInput.remoteButton
    /// Digital Crown steps: per-event deltas and the interval in nanoseconds.
    var crown: @Sendable (String, [Double], UInt64) throws -> Void = DigitalCrown.rotate
    /// The iPhone Duo hinge: one angle in degrees, 0...180.
    var hinge: @Sendable (String, Double) throws -> Void = SimulatorHinge.set
    /// One hinge-angle sample as JSON (read-only).
    var hingeAngle: @Sendable (String) throws -> Data = SimulatorHinge.readAngle
    /// Waits between display reads (fold and unfold); cancellation ends it.
    /// It blocks the command service's own thread, as timed input does, so no
    /// other command of this service runs between the event and the check.
    var pause: @Sendable (Duration) throws -> Void = SimulatorHinge.sleep
    /// The clock that bounds those waits.
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    static let live = SimulatorEnvironment(
        lookup: { try SimulatorDevice.lookup($0) },
        accessibility: { uuid, lifetime in
            try SimulatorAccessibilitySession.bridge(device: uuid, developerDirectory: SimulatorDevice.developerDirectory(), lifetime: lifetime)
        })
}

enum DirectSimulatorAccessibility {
    /// Trees, selector actions and waits over CoreSimulator. Same guards,
    /// selectors, waits and JSON shape as physical; see `AccessibilityPlatform.simulator`.
    static func execute(_ input: SimulatorInput, info: SimulatorDeviceInfo, environment: SimulatorEnvironment,
                        isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try Task.checkCancellation()
        // The current interface: frames, hit points and the centre are in
        // interface points, which a rotation swaps (docs/simulator-input.md).
        let mapping = SimulatorHitMapping()
        let display = {
            try Task.checkCancellation()
            let booted = try SimulatorDevice.requireBooted(input.device, operation: input.operation, lookup: environment.lookup)
            let current = try SimulatorDisplay.read(input.device, environment: environment)
            mapping.update(current, booted)
            return current.accessibility(booted)
        }
        let action = SimulatorInput.selectorActions.contains(input.operation) ? try DirectAccessibilityAction(input.coreDeviceInput) : nil
        let setValue = DirectAccessibilitySetValue.operations.contains(input.operation) ? try DirectAccessibilitySetValue(input.coreDeviceInput) : nil
        let wait = AccessibilityWait.operations.contains(input.operation) ? try AccessibilityWait(input.coreDeviceInput) : nil
        let session: any AccessibilityExchange
        do { session = try environment.accessibility(input.device, wait?.sessionLimits.lifetime ?? AccessibilitySession.Limits.standard.lifetime) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
        (session as? SimulatorAccessibilitySession)?.hitMapping = mapping
        let bytes: Data
        if let setValue {
            guard let setter = session as? any AccessibilityValueSetting else {
                session.close()
                throw CommandFailure(.internal, "The simulator accessibility session cannot set values; nothing was sent.", inputSent: .none)
            }
            bytes = try setValue.execute(session: setter, display: display)
            if Task.isCancelled {
                FileHandle.standardError.write(Data("Simulator AX set-value completed, but cancellation withheld its receipt. Inspect before retrying. No automatic replay.\n".utf8))
            }
            try Task.checkCancellation()
        } else if let action {
            // The action classifies its own failures by submission state.
            bytes = try action.execute(session: session, display: display)
            if Task.isCancelled {
                FileHandle.standardError.write(Data("Simulator AX action completed, but cancellation withheld its receipt. Inspect before retrying. No automatic replay.\n".utf8))
            }
            try Task.checkCancellation()
        } else if let wait {
            bytes = try await wait.execute(device: input.device, resolved: info.uuid, session: session, display: display, clock: ContinuousClock())
        } else {
            let pid = input.operands.first.flatMap { Int32($0) }
            bytes = try DirectPhysicalAccessibility.capture(device: input.device, resolved: info.uuid, pid: pid,
                                                            session: session, display: display, readFocus: info.isAppleTV)
        }
        let screen = (try? SimulatorDisplay.read(input.device, environment: environment))?.screenJSON(info)
        let simulatorSession = session as? SimulatorAccessibilitySession
        let annotated = try annotate(bytes, info: info, screen: screen, selections: simulatorSession?.selections ?? [],
                                     shallowPIDs: simulatorSession?.shallowPIDs ?? [], shallowWait: simulatorSession?.shallowWait ?? .zero,
                                     truncatedRecords: simulatorSession?.truncatedRecords ?? 0)
        return input.operation == "tree" && info.isAppleTV ? try annotateFocus(annotated) : annotated
    }

    /// `focus` on an Apple TV tree: the snapshot node marked `focused`, or
    /// null when the focused element is not among the snapshot's nodes.
    static func annotateFocus(_ bytes: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommandFailure(.internal, "Invalid internal simulator AX result.", inputSent: .unknown)
        }
        let focused = (root["nodes"] as? [[String: Any]] ?? []).first { $0["focused"] as? Bool == true }
        root["focus"] = ["read": true, "attribute": AccessibilityRequest.focusedElementAttribute,
                         "nodeId": focused?["id"] ?? NSNull(), "label": focused?["label"] ?? NSNull(), "identifier": focused?["identifier"] ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func annotate(_ bytes: Data, info: SimulatorDeviceInfo, screen: [String: Any]? = nil, selections: [String] = [],
                         shallowPIDs: Set<Int32> = [], shallowWait: Duration = .zero, truncatedRecords: Int = 0) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommandFailure(.internal, "Invalid internal simulator AX result.", inputSent: .unknown)
        }
        root["platform"] = "simulator"
        root["transport"] = "coresimulator"
        root["screen"] = screen ?? info.screenJSON
        // A process whose full-depth snapshot came back empty was read at a
        // shallower depth: deeper elements are missing, not absent.
        if !shallowPIDs.isEmpty {
            root["shallowSnapshot"] = ["maxDepth": SimulatorAccessibilitySession.shallowDepth, "pids": shallowPIDs.sorted().map(Int.init),
                                       "truncatedRecords": truncatedRecords,
                                       "waitedMilliseconds": shallowWait.components.seconds * 1000 + shallowWait.components.attoseconds / 1_000_000_000_000_000,
                                       "reason": "The full-depth snapshot (\(AccessibilityRequest.snapshotDepth)) came back empty, as SpringBoard's Home Screen does; elements deeper than \(SimulatorAccessibilitySession.shallowDepth) levels are not listed."]
        }
        // How many foreground selections and rechecks used the frontmost
        // request (type 4) and how many the centre hit, when it reported none.
        if !selections.isEmpty {
            root["foregroundSelection"] = ["frontmost": selections.filter { $0 == "frontmost" }.count,
                                           "centre-hit": selections.filter { $0 == "centre-hit" }.count]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
