import AppleDeviceBridge
import Foundation

/// Simulator single-contact touch, buttons, named keys and US-layout typing.
/// Schedules come from the physical builders (`DirectPhysicalTouch.plan`,
/// `DirectPhysicalTyping.samples`) and run through the bridge's shared
/// schedulers; only the connection (host XPC to the simulator's dtuhidd)
/// differs. Receipts keep the physical shape with backend `coresimulator-dtuhid`.
enum DirectSimulatorInput {
    static let backend = "coresimulator-dtuhid"

    /// Touch samples in the digitizer's normalized portrait space. The
    /// simulator interface is assumed portrait, so these are the requested
    /// normalized current-interface coordinates unchanged.
    static func touchSamples(_ input: SimulatorInput, info: SimulatorDeviceInfo) throws -> [DirectPhysicalTouch.Sample] {
        try DirectPhysicalTouch.plan(input.coreDeviceInput, display: DirectTouchDisplay(
            portraitPoints: info.widthPoints, height: info.heightPoints, scale: info.scale))
    }

    static func execute(_ input: SimulatorInput, info: SimulatorDeviceInfo, environment: SimulatorEnvironment) throws -> Data {
        try Task.checkCancellation()
        var result: [String: Any] = ["backend": backend, "operation": input.operation, "status": "dispatched",
            "verified": false, "releaseVerified": false, "platform": "simulator", "device": input.device,
            "resolvedSimulatorUUID": info.uuid, "screen": info.screenJSON]
        switch input.operation {
        case let operation where SimulatorInput.touchOperations.contains(operation):
            let samples = try touchSamples(input, info: info)
            guard samples.allSatisfy({ $0.second == nil }) else {
                throw CommandFailure(.internal, "Simulator touch supports one contact; no input sent.", inputSent: .none)
            }
            try Task.checkCancellation()
            try environment.touch(input.device, samples.map { ADCTouchSample(nanoseconds: $0.nanoseconds, x: $0.x, y: $0.y, phase: $0.phase) })
            result["sampleCount"] = samples.count
            result["contactCount"] = 1
            result["coordinateSpace"] = "normalized-current-interface"
            if operation == "long-press" { result["holdSeconds"] = Double(input.operands[2]) }
        default:
            throw CommandFailure.unsupported("Unsupported simulator input operation: \(input.operation); no input sent.")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Bridge dispatch

    static func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Opens the simulator, runs one bridge input call and classifies its
    /// status like the physical dispatchers.
    static func dispatch(_ uuid: String, _ body: (UnsafeMutableRawPointer, inout [CChar]) -> Int32) throws {
        let owner = try SimulatorBridgeOwner(uuid: uuid, developerDirectory: SimulatorDevice.developerDirectory(), accessibility: false)
        var error = [CChar](repeating: 0, count: 1024)
        let status = body(owner.pointer, &error)
        try Task.checkCancellation()
        guard status == 0 else { throw CommandFailure.inputDispatch(status: status, message: message(error)) }
    }

    static func touch(_ uuid: String, _ samples: [ADCTouchSample]) throws {
        try dispatch(uuid) { owner, error in
            samples.withUnsafeBufferPointer { ADCSimulatorPerformTouch(owner, $0.baseAddress, $0.count, { Task.isCancelled ? 1 : 0 }, &error, error.count) }
        }
    }
}
