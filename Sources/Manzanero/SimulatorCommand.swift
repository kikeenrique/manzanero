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
    static let operations = ["tree"]
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
        default:
            throw CommandFailure.unsupported("Unsupported simulator operation: \(operation).")
        }
        return Self(device: device, operation: operation, operands: operands)
    }

    /// The dry-run plan: what would run, without looking the simulator up.
    func plan() throws -> [String: Any] {
        var plan: [String: Any] = ["platform": "simulator", "device": device, "operation": operation, "liveVerified": false,
                                   "bootRequirement": "Refused unless CoreSimulator reports the simulator Booted; never booted implicitly."]
        if operation == "tree" {
            plan["backend"] = AccessibilityPlatform.simulator.backend
            plan["pid"] = operands.first.flatMap(Int.init).map { $0 as Any } ?? NSNull()
            plan["deviceLease"] = "not taken (observation)"
            plan["execution"] = "In-process CoreSimulator: archived AXPTranslatorRequest objects through -[SimDevice sendAccessibilityRequestAsync:]. Omitted PID selects and rechecks the frontmost application (request type 4); application, snapshot and application identity recheck as on physical devices. No subscription, helper or fallback."
        }
        return plan
    }
}

/// The simulator connections, injectable for tests. Production values call
/// the bridge; every closure runs on the command service's own thread.
struct SimulatorEnvironment: Sendable {
    var lookup: @Sendable (String) throws -> SimulatorDeviceInfo
    var accessibility: @Sendable (String) throws -> any AccessibilityExchange

    static let live = SimulatorEnvironment(
        lookup: { try SimulatorDevice.lookup($0) },
        accessibility: { uuid in
            try SimulatorAccessibilitySession.bridge(device: uuid, developerDirectory: SimulatorDevice.developerDirectory())
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
        let session: any AccessibilityExchange
        do { session = try environment.accessibility(input.device) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
        let pid = input.operands.first.flatMap { Int32($0) }
        let bytes = try DirectPhysicalAccessibility.capture(device: input.device, resolved: info.uuid, pid: pid,
                                                            session: session, display: display)
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
