import AppleDeviceBridge
import Foundation

/// The Apple TV simulator's Siri Remote over the existing Indigo routes
/// (docs/other-families.md). The D-pad and select are keyboard usages, which
/// tvOS treats as the remote's arrows and click; Menu, TV/Home and Play/Pause
/// are consumer-page buttons on the simulator's button service.
enum AppleTVRemote {
    enum Route: Equatable, Sendable {
        /// A keyboard usage on hid.keyboard.
        case key(UInt64)
        /// A consumer-page usage on hid.button.
        case button(UInt64)
        /// One finger drawn across the remote's touch surface, on a touch-pad
        /// service the simulator's universalhidservice creates for the call.
        /// The direction as a unit step: y grows downward.
        case swipe(dx: Double, dy: Double)
    }

    static let names = ["select", "menu", "home", "play-pause", "up", "down", "left", "right",
                        "swipe-up", "swipe-down", "swipe-left", "swipe-right"]
    static let routes: [String: Route] = [
        "select": .key(40), "up": .key(82), "down": .key(81), "left": .key(80), "right": .key(79),
        "menu": .button(0x46), "home": .button(0x40), "play-pause": .button(0xCD),
        "swipe-up": .swipe(dx: 0, dy: -1), "swipe-down": .swipe(dx: 0, dy: 1),
        "swipe-left": .swipe(dx: -1, dy: 0), "swipe-right": .swipe(dx: 1, dy: 0)]

    /// A swipe's travel as a share of the surface, its duration and its
    /// frame interval. The finger starts that far before the centre and ends
    /// that far past it.
    static let swipeTravel = 0.5
    static let swipeMilliseconds: UInt64 = 200
    static let swipeFrameMilliseconds: UInt64 = 20

    /// The reports of one swipe: a contact that goes down, moves in a
    /// straight line through the centre, and lifts where it stopped.
    static func swipeFrames(dx: Double, dy: Double) -> (times: [UInt64], reports: [[UInt8]]) {
        let moves = Int(swipeMilliseconds / swipeFrameMilliseconds)
        func position(_ progress: Double) -> [Int] {
            [dx, dy].map { Int(((0.5 + $0 * swipeTravel * (progress - 0.5)) * 65535).rounded()) }
        }
        var times: [UInt64] = [], reports: [[UInt8]] = []
        for step in 0...moves {
            times.append(UInt64(step) * swipeFrameMilliseconds * 1_000_000)
            reports.append(NativeTouchFrames.report(positions: [position(Double(step) / Double(moves))], active: [0]))
        }
        times.append(UInt64(moves + 1) * swipeFrameMilliseconds * 1_000_000)
        reports.append(NativeTouchFrames.report(positions: [position(1)], active: []))
        return (times, reports)
    }
    /// The remote's button hold, as for the phone's buttons.
    static let holdMicroseconds: UInt32 = 80_000

    /// `--hold <seconds>`: a long press. Simulator only so far. A button
    /// (home, menu, play-pause) is held on the button service: a 1.5 s hold
    /// on home opened Control Centre on a tvOS 27.2 simulator. A key (select
    /// and the arrows) is held as one key down and one key up that far apart.
    static let holdOption = "--hold"
    static let holdRange = 0.08...3.0
    static let holdUsage = "remote \(holdOption) takes seconds in 0.08...3 for a button on an Apple TV simulator, not for a swipe; no input sent."

    /// A held key: down at once, up after the hold.
    static func heldKey(_ usage: UInt64, holdMicroseconds: UInt32) -> [ADCKeyboardSample] {
        [ADCKeyboardSample(nanoseconds: 0, usage: usage, state: 1),
         ADCKeyboardSample(nanoseconds: UInt64(holdMicroseconds) * 1000, usage: usage, state: 2)]
    }

    /// `<button> [--hold <seconds>]`: the button's route and the hold in
    /// microseconds, checked before any contact.
    static func parse(_ operands: [String]) throws -> (name: String, route: Route, holdMicroseconds: UInt32) {
        guard let name = operands.first, let route = routes[name], operands.count == 1 || operands.count == 3 else {
            throw CommandFailure.usage(usage)
        }
        guard operands.count == 3 else { return (name, route, holdMicroseconds) }
        guard operands[1] == holdOption, let seconds = Double(operands[2]), holdRange.contains(seconds) else {
            throw CommandFailure.usage(holdUsage)
        }
        if case .swipe = route { throw CommandFailure.usage(holdUsage) }
        return (name, route, UInt32((seconds * 1_000_000).rounded()))
    }

    static let usage = "Remote buttons: select, menu, home, play-pause, up, down, left, right, and swipe-up, swipe-down, swipe-left, swipe-right on a simulator; no input sent."

    static func describe(_ route: Route) -> [String: Any] {
        switch route {
        case .key(let usage): ["service": "com.apple.coredevice.feature.remote.hid.keyboard", "usagePage": 7, "usage": usage]
        case .button(let usage): ["service": "com.apple.coredevice.feature.remote.hid.button", "usagePage": 12, "usage": usage]
        case .swipe(let dx, let dy):
            ["service": "com.apple.coredevice.feature.remote.universalhidservice", "usagePage": 13, "usage": 5,
             "swipe": ["dx": dx, "dy": dy, "travel": swipeTravel, "durationMilliseconds": swipeMilliseconds]]
        }
    }

    static let swipeRefusal = "remote swipes are built for Apple TV simulators only: a touch-pad service is created in the simulator's HID daemon, and no such route is known on a device. No device was contacted."

    /// The device type in a physical device's `devicectl` details (`appleTV`).
    static func deviceType(_ details: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: details)) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        let hardware = (result["properties"] as? [String: Any])?["hardware"] as? [String: Any]
        return (hardware ?? result["hardwareProperties"] as? [String: Any])?["deviceType"] as? String
    }

    /// A physical Apple TV's routes. Its button service closed the connection
    /// on the consumer usages for Menu (0x46) and Play/Pause (0xCD), so both
    /// go as the keys a keyboard uses for them on tvOS: Escape and Space.
    /// The tvOS probe recorded both, and the other buttons, on an Apple TV 4K
    /// (3rd generation, tvOS 27.2) (docs/other-families.md).
    static let physicalRoutes: [String: Route] = routes.merging(["menu": .key(41), "play-pause": .key(44)]) { $1 }

    /// Operands for a physical device, checked before any contact.
    static func validatePhysical(_ operands: [String]) throws {
        if operands.count == 3, operands[1] == holdOption, routes[operands[0]] != nil {
            throw CommandFailure.unsupported("remote \(holdOption) is built for Apple TV simulators only; on a device, button lock opens Control Centre. No device was contacted.")
        }
        guard operands.count == 1, let route = physicalRoutes[operands[0]] else { throw CommandFailure.usage(usage) }
        if case .swipe = route { throw CommandFailure.unsupported(swipeRefusal) }
    }

    static func plan(_ input: CoreDeviceInput) throws -> [String: Any] {
        try validatePhysical(input.operands)
        guard let route = physicalRoutes[input.operands[0]] else { throw CommandFailure.usage(usage) }
        var plan = describe(route)
        if case .button = route { plan["holdMilliseconds"] = holdMicroseconds / 1000 }
        plan.merge(["backend": "coredevice-direct", "operation": "remote", "remote": input.operands[0],
            "identityArguments": try input.identityPlan().arguments,
            "execution": "Read the device's details; only if they say it is an Apple TV, send one press in process over Apple CoreDevice/RemoteXPC. No helper executable, no retry."]) { $1 }
        return plan
    }

    /// One remote press on a physical Apple TV, over the routes `key` and
    /// `button` use. The family is read from the device's details before
    /// anything is sent; another device is refused.
    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        key: (DirectPhysicalKeyboard.Key) throws -> Void = DirectPhysicalKeyboard.dispatch,
                        button: (DirectPhysicalInput.Button) throws -> Void = DirectPhysicalInput.dispatch) throws -> Data {
        try validatePhysical(input.operands)
        guard input.operation == "remote", let route = physicalRoutes[input.operands[0]] else { throw CommandFailure.usage(usage) }
        let name = input.operands[0]
        let details = try query(input.identityPlan())
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard deviceType(details) == "appleTV" else {
            throw CommandFailure.unsupported("remote drives an Apple TV; this device reports the type \(deviceType(details) ?? "unknown"). No input sent.")
        }
        try Task.checkCancellation()
        switch route {
        case .key(let usage): try key(.init(uuid: identity.uuid, version: identity.version, name: name, usage: usage))
        case .button(let usage): try button(.init(uuid: identity.uuid, version: identity.version, usage: usage, holdMicroseconds: holdMicroseconds))
        case .swipe: throw CommandFailure.unsupported(swipeRefusal)
        }
        var receipt = describe(route)
        receipt.merge(["backend": "coredevice-direct", "operation": "remote", "remote": name, "status": "dispatched",
            "verified": false, "releaseVerified": false, "device": input.device, "resolvedCoreDeviceUUID": identity.uuid]) { $1 }
        return try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    }

    static let touchRefusal = "Apple TV has no touch screen; move focus and select with remote (up, down, left, right, select, menu, home, play-pause). No input sent."

    /// Family checks for simulator input, made after the read-only lookup and
    /// before any input: touch is refused on Apple TV, and the remote is
    /// refused elsewhere.
    static func checkFamily(_ input: SimulatorInput, info: SimulatorDeviceInfo) throws {
        let touch = (SimulatorInput.touchOperations + SimulatorInput.gestureOperations).contains(input.operation)
        if info.isAppleTV, touch { throw CommandFailure.unsupported(touchRefusal) }
        if input.operation == "remote", !info.isAppleTV {
            throw CommandFailure.unsupported("remote drives an Apple TV simulator; this simulator is \(info.family.isEmpty ? "of an unknown family" : "an \(info.family)"). No input sent.")
        }
    }
}
