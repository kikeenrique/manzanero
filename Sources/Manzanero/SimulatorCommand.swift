import AppleDeviceBridge
import Foundation

/// Simulator input and accessibility in process: argument validation, dry-run
/// plans and routing. Execution lives in `DirectSimulator*`, and the
/// connections in `AppleSimulatorBridge.m`. The operands, coordinate space,
/// receipts and error categories are those of the physical commands.
struct SimulatorInput {
    let device: String
    let operation: String
    let operands: [String]

    static let selectorActions = ["press-id", "press-label", "scroll-id", "scroll-label"]
    static let accessibilityOperations = ["tree"] + selectorActions + AccessibilityWait.operations
    static let touchOperations = ["tap", "long-press", "swipe", "drag"]
    static let inputOperations = touchOperations + ["button", "key", "type"]
    static let operations = accessibilityOperations + inputOperations
    /// Operations that exist for physical devices but not yet for simulators.
    static let unimplemented = ["multi-tap", "multi-drag", "pinch", "gesture", "paste", "wake"]
    static let buttons: [String: UInt64] = ["home": 64, "lock": 48]

    /// Same rule as physical: trees and waits only read, take no lease and are
    /// not paused by a pending handoff.
    static let observations = ["tree"] + AccessibilityWait.operations

    var isObservation: Bool { Self.observations.contains(operation) }
    var coreDeviceInput: CoreDeviceInput { CoreDeviceInput(device: device, operation: operation, operands: operands) }

    static func parse(_ args: [String]) throws -> Self? {
        guard args.count >= 3, args[0] == "simulator" else { return nil }
        let operation = args[2]
        if unimplemented.contains(operation) {
            throw CommandFailure.unsupported("Simulator \(operation) is not implemented yet; simulator input covers tap, long-press, swipe, drag, button, key and type. Multi-contact gestures, paste and wake remain physical-only. No input sent.")
        }
        guard operations.contains(operation) else { return nil }
        let device = try SimulatorDevice.requireUUID(args[1], operation: operation)
        var operands = Array(args.dropFirst(3))
        let probe = CoreDeviceInput(device: device, operation: operation, operands: operands)
        switch operation {
        case "tree":
            if !operands.isEmpty {
                guard operands.count == 1, let pid = Int32(operands[0]), pid > 0 else {
                    throw CommandFailure.usage("Simulator tree accepts one PID in 1...2147483647, or no PID for the frontmost application.")
                }
                operands = [String(pid)]
            }
        case let value where selectorActions.contains(value):
            _ = try DirectAccessibilityAction(probe)
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
        case "button":
            guard operands.count == 1, buttons[operands[0]] != nil else {
                throw CommandFailure.usage("Supported simulator buttons: home, lock. Volume buttons are untested on the simulator and refused; no input sent.")
            }
        case "type":
            guard operands.count == 1 else { throw CommandFailure.usage("Simulator typing expects one text operand.") }
            let bytes = Array(operands[0].utf8)
            guard (1...512).contains(bytes.count), bytes.allSatisfy({ DirectPhysicalTyping.stroke($0) != nil }) else {
                throw CommandFailure.usage("Simulator typing requires 1...512 printable US-layout ASCII characters, tab or LF newline. Unicode entry is not implemented on the simulator yet. No input sent.")
            }
        default:
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        return Self(device: device, operation: operation, operands: operands)
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
            plan["execution"] = "\(route) Omitted PID selects and rechecks the frontmost application (request type 4); application, snapshot and application identity recheck as on physical devices. No helper or fallback."
        } else if Self.selectorActions.contains(operation) {
            let action = try DirectAccessibilityAction(coreDeviceInput)
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["operation"] = action.operation
            plan["selector"] = ["by": action.by, "text": action.text]
            plan["pid"] = action.pid.map { Int($0) as Any } ?? NSNull()
            plan["deviceLease"] = "simulator UUID"
            plan["execution"] = "\(route) Frontmost-application selection, two unique snapshots and live state/frame guards before one action, as on physical devices. Press checks an exact hit (client type 2) at the target centre; scroll follows with fresh visibility/frame/hit and selection checks. No fallback or replay."
        } else if AccessibilityWait.operations.contains(operation) {
            let wait = try AccessibilityWait(coreDeviceInput)
            plan.merge(wait.plan(identityArguments: [])) { _, shared in shared }
            plan.removeValue(forKey: "identityArguments")
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["execution"] = "\(route) Omitted PID re-selects the frontmost application on every poll; an explicit PID is observed even in the background. Each poll reads application identity and one bounded snapshot, evaluates the exact selector, and rechecks the selection before reporting a met condition. No input, fallback or reconnection."
        } else if Self.touchOperations.contains(operation) {
            let samples = try DirectPhysicalTouch.plan(coreDeviceInput, display: DirectTouchDisplay(portraitPoints: 1, height: 1, scale: 1))
            plan["backend"] = DirectSimulatorInput.backend
            plan["operands"] = operands
            plan["deviceLease"] = "simulator UUID"
            plan["sampleCount"] = samples.count
            plan["contactCount"] = 1
            plan["coordinateSpace"] = "normalized-current-interface (portrait assumed)"
            plan["execution"] = "In-process host XPC to the simulator's dtuhidd (com.apple.coredevice.feature.remote.hid.digitizer): readiness barrier, the physical Indigo digitizer schedule, release on stop, completion barrier and a short drain before disconnect. No helper executable or automatic replay."
        } else if Self.inputOperations.contains(operation) {
            plan["backend"] = DirectSimulatorInput.backend
            plan["operands"] = operands
            plan["deviceLease"] = "simulator UUID"
            let service: String
            switch operation {
            case "button":
                service = "com.apple.coredevice.feature.remote.hid.button"
                plan["usage"] = Self.buttons[operands[0]]
                plan["holdMilliseconds"] = operands[0] == "lock" ? 400 : 80
            case "key":
                service = "com.apple.coredevice.feature.remote.hid.keyboard"
                plan["usage"] = DirectPhysicalKeyboard.usages[operands[0]]
            default:
                service = "com.apple.coredevice.feature.remote.hid.keyboard"
                plan["layout"] = "US"
                plan["characterCount"] = operands[0].utf8.count
                plan["sampleCount"] = try DirectPhysicalTyping.samples(operands[0]).count
            }
            plan["execution"] = "In-process host XPC to the simulator's dtuhidd (\(service)): readiness barrier, the physical Indigo \(operation == "button" ? "button press" : "keyboard schedule") with release on stop, completion barrier and a short drain before disconnect. No clipboard, helper executable or automatic replay."
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
    /// A complete US-layout keyboard schedule (`type`).
    var keyboard: @Sendable (String, [ADCKeyboardSample]) throws -> Void = DirectSimulatorInput.keyboard
    /// One named key (`key`).
    var key: @Sendable (String, UInt64) throws -> Void = DirectSimulatorInput.key
    /// One button press: usage and hold in microseconds.
    var button: @Sendable (String, UInt64, UInt32) throws -> Void = DirectSimulatorInput.button

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
        let display = {
            try Task.checkCancellation()
            return try SimulatorDevice.requireBooted(input.device, operation: input.operation, lookup: environment.lookup).display
        }
        let action = SimulatorInput.selectorActions.contains(input.operation) ? try DirectAccessibilityAction(input.coreDeviceInput) : nil
        let wait = AccessibilityWait.operations.contains(input.operation) ? try AccessibilityWait(input.coreDeviceInput) : nil
        let session: any AccessibilityExchange
        do { session = try environment.accessibility(input.device, wait?.sessionLimits.lifetime ?? AccessibilitySession.Limits.standard.lifetime) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
        let bytes: Data
        if let action {
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
                                                            session: session, display: display)
        }
        return try annotate(bytes, info: info)
    }

    static func annotate(_ bytes: Data, info: SimulatorDeviceInfo) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommandFailure(.internal, "Invalid internal simulator AX result.", inputSent: .unknown)
        }
        root["platform"] = "simulator"
        root["transport"] = "coresimulator"
        root["screen"] = info.screenJSON
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

extension SimulatorDeviceInfo {
    /// The simulator's interface as the shared accessibility guards see it:
    /// the whole screen in logical points, display 0, portrait assumed.
    var display: AccessibilityDisplay {
        AccessibilityDisplay(bounds: .init(x: 0, y: 0, width: widthPoints, height: heightPoints),
                             displayId: 0, pointScale: scale, orientation: SimulatorDevice.orientation)
    }
}
