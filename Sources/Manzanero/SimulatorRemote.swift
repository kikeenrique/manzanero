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
    }

    static let names = ["select", "menu", "home", "play-pause", "up", "down", "left", "right"]
    static let routes: [String: Route] = [
        "select": .key(40), "up": .key(82), "down": .key(81), "left": .key(80), "right": .key(79),
        "menu": .button(0x46), "home": .button(0x40), "play-pause": .button(0xCD)]
    /// The remote's button hold, as for the phone's buttons.
    static let holdMicroseconds: UInt32 = 80_000

    static let usage = "Remote buttons: select, menu, home, play-pause, up, down, left, right; no input sent."

    static func describe(_ route: Route) -> [String: Any] {
        switch route {
        case .key(let usage): ["service": "com.apple.coredevice.feature.remote.hid.keyboard", "usagePage": 7, "usage": usage]
        case .button(let usage): ["service": "com.apple.coredevice.feature.remote.hid.button", "usagePage": 12, "usage": usage]
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
        guard operands.count == 1, physicalRoutes[operands[0]] != nil else { throw CommandFailure.usage(usage) }
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
