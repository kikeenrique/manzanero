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
        case swipe(dx: Double, dy: Double, shape: SwipeShape = .standard)
    }

    /// How far a swipe goes, as a share of the surface, and how long it
    /// takes. The finger starts half the travel before the centre and ends
    /// half the travel past it.
    struct SwipeShape: Equatable {
        var travel: Double
        var milliseconds: UInt64
        static let standard = SwipeShape(travel: swipeTravel, milliseconds: swipeMilliseconds)
    }

    static let names = ["select", "menu", "home", "play-pause", "up", "down", "left", "right",
                        "swipe-up", "swipe-down", "swipe-left", "swipe-right"] + AppleTVPower.names
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
    static func swipeFrames(dx: Double, dy: Double, shape: SwipeShape = .standard) -> (times: [UInt64], reports: [[UInt8]]) {
        let moves = max(1, Int(shape.milliseconds / swipeFrameMilliseconds))
        func position(_ progress: Double) -> [Int] {
            [dx, dy].map { Int(((0.5 + $0 * shape.travel * (progress - 0.5)) * 65535).rounded()) }
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

    /// `--hold <seconds>`: a long press. A button (home, menu, play-pause on
    /// a simulator) is held on the button service: a 1.5 s hold on home
    /// opened Control Centre on a tvOS 27.2 simulator. A key (select and the
    /// arrows) is held as one key down and one key up that far apart. On a
    /// device the keys can be held (a held select was a long press on an
    /// Apple TV 4K) and home cannot.
    static let holdOption = "--hold"
    static let holdRange = 0.08...3.0
    static let holdUsage = "remote \(holdOption) takes seconds in 0.08...3 for a button on an Apple TV, not for a swipe; no input sent."

    /// A held key: down at once, up after the hold.
    static func heldKey(_ usage: UInt64, holdMicroseconds: UInt32) -> [ADCKeyboardSample] {
        [ADCKeyboardSample(nanoseconds: 0, usage: usage, state: 1),
         ADCKeyboardSample(nanoseconds: UInt64(holdMicroseconds) * 1000, usage: usage, state: 2)]
    }

    /// `<button> [--hold <seconds>]`: the button's route and the hold in
    /// microseconds, checked before any contact.
    static func parse(_ operands: [String]) throws -> (name: String, route: Route, holdMicroseconds: UInt32) {
        // Sleep and wake are a physical Apple TV's (`AppleTVPower`), which
        // takes them before this is reached.
        if AppleTVPower.handles(operands) { throw CommandFailure.unsupported(AppleTVPower.simulatorRefusal) }
        guard let name = operands.first, let route = routes[name], operands.count % 2 == 1, operands.count <= 5 else {
            throw CommandFailure.usage(usage)
        }
        var hold: UInt32?, shape = SwipeShape.standard, seen = Set<String>()
        for index in stride(from: 1, to: operands.count, by: 2) {
            // Each option once, each with a number.
            guard seen.insert(operands[index]).inserted else { throw CommandFailure.usage(usage) }
            let value = Double(operands[index + 1])
            switch operands[index] {
            case holdOption:
                guard let value, holdRange.contains(value) else { throw CommandFailure.usage(holdUsage) }
                hold = UInt32((value * 1_000_000).rounded())
            case travelOption:
                guard let value, travelRange.contains(value) else { throw CommandFailure.usage(shapeUsage) }
                shape.travel = value
            case secondsOption:
                guard let value, secondsRange.contains(value) else { throw CommandFailure.usage(shapeUsage) }
                shape.milliseconds = UInt64((value * 1000).rounded())
            default: throw CommandFailure.usage(usage)
            }
        }
        guard case .swipe(let dx, let dy, _) = route else {
            if seen.contains(travelOption) || seen.contains(secondsOption) { throw CommandFailure.usage(shapeUsage) }
            return (name, route, hold ?? holdMicroseconds)
        }
        if hold != nil { throw CommandFailure.usage(holdUsage) }
        return (name, .swipe(dx: dx, dy: dy, shape: shape), holdMicroseconds)
    }

    /// `--travel <share>` and `--seconds <seconds>`: a swipe's length, as a
    /// share of the remote's touch surface, and its duration. The defaults
    /// are half the surface in 0.2 s.
    static let travelOption = "--travel"
    static let secondsOption = "--seconds"
    static let travelRange = 0.05...0.9
    static let secondsRange = 0.04...2.0
    static let shapeUsage = "remote \(travelOption) takes a share of the touch surface in 0.05...0.9 and \(secondsOption) seconds in 0.04...2, for a swipe only; no input sent."

    static let usage = "Remote buttons: select, menu, home, play-pause, up, down, left, right, and swipe-up, swipe-down, swipe-left, swipe-right; sleep and wake on a physical Apple TV; no input sent."

    static func describe(_ route: Route) -> [String: Any] {
        switch route {
        case .key(let usage): ["service": "com.apple.coredevice.feature.remote.hid.keyboard", "usagePage": 7, "usage": usage]
        case .button(let usage): ["service": "com.apple.coredevice.feature.remote.hid.button", "usagePage": 12, "usage": usage]
        case .swipe(let dx, let dy, let shape):
            ["service": "com.apple.coredevice.feature.remote.universalhidservice", "usagePage": 13, "usage": 5,
             "swipe": ["dx": dx, "dy": dy, "travel": shape.travel, "durationMilliseconds": shape.milliseconds]]
        }
    }

    /// One swipe for a physical Apple TV: the reports and their times.
    struct Swipe {
        let uuid: String
        let version: String
        let times: [UInt64]
        let reports: [UInt8]
    }

    /// Sends a swipe to a touch-pad service created for the call on the
    /// device's Universal HID service, as on a simulator. On an Apple TV 4K
    /// (tvOS 27.2) one swipe to the right moved the focus across the screen
    /// and the tvOS probe recorded `right` (docs/other-families.md).
    static func dispatchSwipe(_ swipe: Swipe) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let status = swipe.times.withUnsafeBufferPointer { times in
            swipe.reports.withUnsafeBufferPointer { reports in
                ADCPerformCancellableRemoteTouch(swipe.uuid, swipe.version, times.baseAddress, reports.baseAddress,
                                                 times.count, { Task.isCancelled ? 1 : 0 }, &error, error.count)
            }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw CommandFailure.inputDispatch(status: status, message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }

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
        if AppleTVPower.handles(operands) { return try AppleTVPower.validate(operands) }
        _ = try parsePhysical(operands)
    }

    /// `<button> [--hold <seconds>]` for a physical Apple TV: its route
    /// there, and the hold when one was asked for. A held button goes on the
    /// button service with that hold; a held key (select, the arrows, and
    /// Menu and Play/Pause, which are keys on a device) is one key down and
    /// one key up that far apart, as on a simulator.
    static func parsePhysical(_ operands: [String]) throws -> (name: String, route: Route, held: UInt32?) {
        let parsed = try parse(operands)
        guard var route = physicalRoutes[parsed.name] else { throw CommandFailure.usage(usage) }
        if case .swipe = parsed.route { route = parsed.route }
        let held = operands.contains(holdOption) ? parsed.holdMicroseconds : nil
        if held != nil, case .button = route { throw CommandFailure.unsupported(physicalHomeHoldRefusal) }
        return (parsed.name, route, held)
    }

    /// Home is the one remote button a device takes on its button service,
    /// and that service does not hold it: on an Apple TV 4K (tvOS 27.2) a
    /// 1.5 s hold ended with the connection failing during the hold, and
    /// neither Control Centre nor the Home Screen appeared.
    static let physicalHomeHoldRefusal = "remote home \(holdOption) works on Apple TV simulators only: a device's button service failed during the hold and nothing opened. select, the arrows, menu and play-pause can be held on a device. No device was contacted."

    static func plan(_ input: CoreDeviceInput) throws -> [String: Any] {
        if AppleTVPower.handles(input.operands) { return try AppleTVPower.plan(input) }
        let (_, route, held) = try parsePhysical(input.operands)
        var plan = describe(route)
        if let held { plan["holdMilliseconds"] = held / 1000 }
        else if case .button = route { plan["holdMilliseconds"] = holdMicroseconds / 1000 }
        plan.merge(["backend": "coredevice-direct", "operation": "remote", "remote": input.operands[0],
            "identityArguments": try input.identityPlan().arguments,
            "execution": "Read the device's details; only if they say it is an Apple TV, send one press in process over Apple CoreDevice/RemoteXPC, or for a swipe create a touch-pad service on the device's Universal HID service and send it one finger's reports. No helper executable, no retry."]) { $1 }
        return plan
    }

    /// One remote press on a physical Apple TV, over the routes `key` and
    /// `button` use. The family is read from the device's details before
    /// anything is sent; another device is refused.
    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        key: (DirectPhysicalKeyboard.Key) throws -> Void = DirectPhysicalKeyboard.dispatch,
                        button: (DirectPhysicalInput.Button) throws -> Void = DirectPhysicalInput.dispatch,
                        heldKey: (DirectPhysicalKeyboard.Sequence) throws -> Void = DirectPhysicalKeyboard.dispatchSequence,
                        swipe: (Swipe) throws -> Void = AppleTVRemote.dispatchSwipe) throws -> Data {
        let (name, route, held) = try parsePhysical(input.operands)
        guard input.operation == "remote" else { throw CommandFailure.usage(usage) }
        let details = try query(input.identityPlan())
        let identity = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard deviceType(details) == "appleTV" else {
            throw CommandFailure.unsupported("remote drives an Apple TV; this device reports the type \(deviceType(details) ?? "unknown"). No input sent.")
        }
        try Task.checkCancellation()
        switch route {
        case .key(let usage):
            if let held {
                try heldKey(.init(uuid: identity.uuid, version: identity.version, samples: Self.heldKey(usage, holdMicroseconds: held)))
            } else { try key(.init(uuid: identity.uuid, version: identity.version, name: name, usage: usage)) }
        case .button(let usage):
            try button(.init(uuid: identity.uuid, version: identity.version, usage: usage, holdMicroseconds: held ?? holdMicroseconds))
        case .swipe(let dx, let dy, let shape):
            let frames = swipeFrames(dx: dx, dy: dy, shape: shape)
            try swipe(.init(uuid: identity.uuid, version: identity.version, times: frames.times, reports: frames.reports.flatMap { $0 }))
        }
        var receipt = describe(route)
        if let held { receipt["holdMilliseconds"] = held / 1000 }
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
