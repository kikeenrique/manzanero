import AppleDeviceBridge
import Foundation

/// Folding the iPhone Duo simulator (docs/other-families.md, research in
/// docs/duo-fold-research.md). One vendor-defined Indigo event, the one Device
/// Hub's hinge control sends, sets the hinge angle; the guest animates to it
/// (0 to 180 in about 0.3 s) and swaps the active display on its own.
///
/// The swap depends on the path, not only on the final angle: 0 → 110 in one
/// step unfolded, 0 → 45 → 70 → 110 in steps did not, and 180 → 90 stayed
/// unfolded. So `fold` (0) and `unfold` (180) wait until the display
/// information shows the expected display awake, while `hinge <degrees>`
/// only sends the angle and reports the display it reads right after.
enum SimulatorHinge {
    static let operations = ["fold", "unfold", "hinge", angleOperation]
    /// `hinge` without an angle: one read-only sample of the angle.
    static let angleOperation = "hinge-angle"
    static let angleTimeoutSeconds = 3.0
    static let service = "com.apple.coredevice.feature.remote.hid.vendordefined"
    static let message = "IndigoVendorDefinedEvent {usagePage: 0xFF61, usage: 0x5B, version: 0, data: IOCFSerialize(binary) of {source: hinge-slider-control, type: range, value: <degrees>}}"
    static let usage = "hinge takes an angle in degrees, 0...180 (0 closed, 180 fully open); no input sent."

    /// The display check after fold and unfold: every `pollInterval`, at most
    /// `pollLimit` reads and no longer than `waitLimit`.
    static let pollInterval: Duration = .milliseconds(250)
    /// Folding took 11 reads (about 2.7 s) on the iOS 27.2 runtime, both
    /// displays reading awake in between; unfolding took 3.
    static let pollLimit = 40
    static let waitLimit: Duration = .seconds(10)

    /// The request: refused on a physical device before any contact.
    static func request(_ target: Target, _ operation: String, _ operands: [String] = []) throws -> CommandRequest {
        guard target.platform == .simulator else {
            throw CommandFailure.unsupported("\(operation == angleOperation ? "hinge" : operation) is implemented for foldable simulators (iPhone Duo) only; no device was contacted.")
        }
        return try .input(target, operation, operands)
    }

    /// The validated angle.
    static func degrees(_ operand: String) throws -> Double {
        guard let value = Double(operand), value.isFinite, (0...180).contains(value) else { throw CommandFailure.usage(usage) }
        return value
    }

    /// The angle an operation sends.
    static func angle(_ input: SimulatorInput) -> Double {
        switch input.operation {
        case "fold": 0
        case "unfold": 180
        default: Double(input.operands.first ?? "") ?? 0
        }
    }

    static func plan(_ input: SimulatorInput) -> [String: Any] {
        if input.operation == angleOperation {
            return ["backend": DirectSimulatorInput.backend, "operation": "hinge", "readOnly": true, "deviceLease": "not taken (observation)",
                    "foldable": "Refused unless the display information lists exactly two integrated displays with a framebuffer, one of them primary.",
                    "execution": "One display-information read, then in-process host XPC to the simulator's dtdeviceinfod (com.apple.coredevice.feature.monitormotion): the CoreDevice streamhingeangle action; the first pushed sample (the current state) is taken within \(Int(angleTimeoutSeconds)) s and the connection is cancelled, which ends the stream. No input."]
        }
        var plan: [String: Any] = ["backend": DirectSimulatorInput.backend, "operands": input.operands, "deviceLease": "simulator UUID",
                                   "degrees": angle(input), "service": service, "message": message,
                                   "foldable": "Refused unless the display information lists exactly two integrated displays with a framebuffer, one of them primary (the iPhone Duo's LCD and LCD-1); read before any input."]
        let send = "In-process host XPC to the simulator's dtuhidd (\(service)): readiness barrier, one vendor-defined event, completion barrier and the short input drain before disconnect. No helper executable or automatic replay."
        if input.operation == "hinge" {
            plan["execution"] = "\(send) Then one display-information read, reported as the display awake at that moment; the guest may still be moving, and whether an intermediate angle swaps the display depends on the path, so none is promised."
        } else {
            plan["expectedDisplay"] = input.operation == "fold" ? "the primary integrated display (outer)" : "the other integrated display (inner)"
            plan["execution"] = "\(send) Then read the display information every \(pollInterval.milliseconds) ms, at most \(pollLimit) times and \(waitLimit.milliseconds / 1000) s, until the expected integrated display is awake and the other is not."
        }
        return plan
    }

    /// Sends the angle; for fold and unfold, waits (bounded) for the expected display.
    static func execute(_ input: SimulatorInput, info: SimulatorDeviceInfo, environment: SimulatorEnvironment) throws -> Data {
        try Task.checkCancellation()
        let displays: [SimulatorDisplayEntry]
        do { displays = try SimulatorDisplays.read(input.device, environment: environment) }
        catch let failure as CommandFailure { throw failure.noInputSent() }
        guard let pair = SimulatorDisplays.foldable(displays) else {
            throw CommandFailure.unsupported("\(input.operation) needs a foldable simulator such as iPhone Duo (two integrated displays); this one lists \(displays.filter { $0.isIntegrated && $0.capturable }.count) integrated display(s) with a framebuffer. No input sent.")
        }
        if input.operation == angleOperation {
            let sample = try HingeSample(environment.hingeAngle(input.device))
            var result: [String: Any] = ["operation": "hinge", "platform": "simulator", "device": input.device, "resolvedSimulatorUUID": info.uuid,
                                         "readOnly": true, "source": "CoreDevice streamhingeangle (monitormotion), first sample"]
            result.merge(sample.json) { $1 }
            result["activeDisplay"] = SimulatorDisplays.active(displays)?.summary ?? NSNull()
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        let degrees = angle(input)
        try Task.checkCancellation()
        try environment.hinge(input.device, degrees)
        var result: [String: Any] = ["backend": DirectSimulatorInput.backend, "operation": input.operation, "status": "dispatched",
                                     "platform": "simulator", "device": input.device, "resolvedSimulatorUUID": info.uuid,
                                     "degrees": degrees, "service": service]
        guard input.operation != "hinge" else {
            let now = try? SimulatorDisplays.read(input.device, environment: environment)
            result["activeDisplay"] = now.flatMap(SimulatorDisplays.active)?.summary ?? NSNull()
            result["displayObserved"] = false
            result["note"] = "The display read right after sending; the guest animates to the angle, and whether an intermediate angle swaps the display depends on the path (use fold or unfold for a confirmed display)."
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        let expected = input.operation == "fold" ? pair.outer : pair.inner
        let other = input.operation == "fold" ? pair.inner : pair.outer
        result["expectedDisplay"] = expected.summary
        let start = environment.now()
        var polls = 0, observed = false, last: [SimulatorDisplayEntry] = []
        while polls < pollLimit, start.duration(to: environment.now()) <= waitLimit {
            if polls > 0 { try environment.pause(pollInterval) }
            try Task.checkCancellation()
            polls += 1
            // A failed read is not a result; the next poll reads again.
            guard let current = try? SimulatorDisplays.read(input.device, environment: environment) else { continue }
            last = current
            let state = { (display: SimulatorDisplayEntry) in current.first { $0.id == display.id } }
            if state(expected)?.isOn == true, state(other)?.isOn == false {
                observed = true
                break
            }
        }
        result["displayObserved"] = observed
        result["displayReads"] = polls
        result["activeDisplay"] = SimulatorDisplays.active(last)?.summary ?? NSNull()
        if !observed {
            result["note"] = "The hinge event was sent, but within \(waitLimit.milliseconds / 1000) s the display information did not show \(expected.name) awake and \(other.name) off. Inspect with displays before relying on the fold state; no automatic replay."
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    /// Blocks for `duration` in slices of at most 10 ms, throwing
    /// `CancellationError` as soon as the task is cancelled (SIGINT).
    static func sleep(_ duration: Duration) throws {
        let end = ContinuousClock.now.advanced(by: duration)
        while true {
            try Task.checkCancellation()
            let left = ContinuousClock.now.duration(to: end)
            guard left > .zero else { return }
            Thread.sleep(forTimeInterval: Double(min(left, .milliseconds(10)).milliseconds) / 1000 + 0.0005)
        }
    }

    /// One hinge sample as JSON; read-only.
    static func readAngle(_ uuid: String) throws -> Data {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: SimulatorDevice.developerDirectory(), accessibility: false)
        var error = [CChar](repeating: 0, count: 1024)
        var data = Data()
        let status = ADCSimulatorReadHingeAngle(owner.pointer, angleTimeoutSeconds, { Task.isCancelled ? 1 : 0 }, { pointer, count in
            if let pointer { data = Data(bytes: pointer, count: count) }
        }, &error, error.count)
        try Task.checkCancellation()
        guard status == 0 else { throw CommandFailure(.transportFailed, DirectSimulatorInput.message(error), inputSent: .none) }
        return data
    }

    static func set(_ uuid: String, _ degrees: Double) throws {
        try DirectSimulatorInput.dispatch(uuid) { owner, error in
            ADCSimulatorSetHingeAngle(owner, degrees, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        }
    }
}

/// One streamhingeangle sample: each angle is a Measurement in degrees,
/// `{value, unit: {symbol, converter}}`. `angle` and `mechanicalAngle`
/// differ while moving and slightly at rest (mechanical 90, angle 94.62).
struct HingeSample: Equatable {
    let angle: Double
    let mechanicalAngle: Double?
    let minAngle: Double?
    let maxAngle: Double?
    let velocity: Double?
    let angleValid: Bool

    init(_ data: Data) throws {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandFailure(.transportFailed, "Cannot read the simulator's hinge angle sample; nothing was sent.", inputSent: .none)
        }
        func value(_ key: String) -> Double? {
            ((root[key] as? [String: Any])?["value"] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
        }
        guard let angle = value("angle") else {
            throw CommandFailure(.transportFailed, "The simulator's hinge angle sample has no angle; nothing was sent.", inputSent: .none)
        }
        self.angle = angle
        mechanicalAngle = value("mechanicalAngle")
        minAngle = value("minAngle")
        maxAngle = value("maxAngle")
        velocity = value("velocity")
        angleValid = root["isAngleValid"] as? Bool == true
    }

    var json: [String: Any] {
        func optional(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return ["angle": angle, "mechanicalAngle": optional(mechanicalAngle), "minAngle": optional(minAngle), "maxAngle": optional(maxAngle),
                "velocity": optional(velocity), "isAngleValid": angleValid, "unit": "degrees", "velocityUnit": "degrees per second",
                "posture": angleValid ? Self.posture(angle) : "unknown", "postureSource": Self.postureSource]
    }

    /// Manzanero's own reading of the angle, not a value the simulator
    /// reports: closed up to 5 degrees, flat from 175, partially open between.
    /// The device-motion stream that carries Apple's posture was not found.
    static func posture(_ angle: Double) -> String {
        angle <= closedLimit ? "closed" : angle >= flatLimit ? "flat" : "partially-open"
    }
    static let closedLimit = 5.0
    static let flatLimit = 175.0
    static let postureSource = "derived from angle by manzanero: closed <= 5, flat >= 175 degrees, else partially-open; not reported by the simulator"
}

extension Duration {
    /// Whole milliseconds.
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
