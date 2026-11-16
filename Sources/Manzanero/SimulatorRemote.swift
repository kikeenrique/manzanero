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
