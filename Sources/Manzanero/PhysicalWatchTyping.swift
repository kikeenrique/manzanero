import Foundation

/// `type` on a physical Apple Watch: keyboard events do not reach watchOS,
/// so, as on a simulator (`WatchKeyboard`), the keys of the on-screen
/// keyboard are tapped one by one, read from a fresh accessibility tree
/// before each key. On a watch the keyboard is the frontmost process itself
/// (`QuickboardViewService`, 2026-11-24), so the plain tree shows its keys;
/// screens without keys of the keyboard's own class are not taken for one.
enum PhysicalWatchTyping {
    static func execute(_ input: CoreDeviceInput, query: @escaping (DeviceCommand) throws -> Data,
                        readTree: ((CoreDeviceInput) async throws -> Data)? = nil,
                        tap: ((CoreDeviceInput) throws -> Data)? = nil,
                        pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                        isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        // The operands are the text and a layout; the watch's own keyboard is
        // tapped, so no layout applies.
        guard let text = input.operands.first else {
            throw CommandFailure.usage("type takes the text to enter. No input sent.")
        }
        try WatchKeyboard.validate(text)
        let tree = CoreDeviceInput(device: input.device, operation: "tree", operands: [])
        let read: (CoreDeviceInput) async throws -> Data = readTree ?? { try await DirectPhysicalAccessibility.executeNativeRSD($0, query: query) }
        let send: (CoreDeviceInput) throws -> Data = tap ?? { try DirectPhysicalTouch.execute($0, query: query) }
        var taps = 0
        func snapshot() async throws -> (entries: [WatchKeyboard.Entry], bounds: AccessibilityDisplay.Bounds) {
            do { return try WatchKeyboard.entries(tree: await read(tree)) }
            catch let failure as CommandFailure where taps > 0 { throw failure.inputPossiblySent() }
        }
        // The keyboard takes a moment to open after the field is pressed.
        var first = try await snapshot()
        for _ in 0..<WatchKeyboard.openingReads where !WatchKeyboard.showsKeyboard(first.entries) {
            try await pause(WatchKeyboard.openingInterval)
            first = try await snapshot()
        }
        guard WatchKeyboard.showsKeyboard(first.entries) else {
            throw CommandFailure(.targetUnresolved, "No watch keyboard is open: press the text field first, so watchOS shows its keyboard, then type. No input sent.", inputSent: .none)
        }
        var pending: [String: WatchKeyboard.Key]? = WatchKeyboard.keys(first.entries, bounds: first.bounds)
        let typed = try await WatchKeyboard.type(text, read: {
            if let keys = pending { pending = nil; return keys }
            let now = try await snapshot()
            guard WatchKeyboard.showsKeyboard(now.entries) else {
                throw CommandFailure(.targetUnresolved, "The watch keyboard closed after \(taps) tap(s): inspect the field before retrying.", inputSent: .possible)
            }
            return WatchKeyboard.keys(now.entries, bounds: now.bounds)
        }, tap: { key in
            let point = try CoreDeviceInput.validated(device: input.device, operation: "tap", operands: [String(key.x), String(key.y)])
            do { _ = try send(point) }
            catch let failure as CommandFailure where taps > 0 { throw failure.inputPossiblySent() }
            taps += 1
        })
        return try JSONSerialization.data(withJSONObject: [
            "backend": "coredevice-direct", "operation": "type", "device": input.device, "status": "dispatched",
            "route": "watch-on-screen-keyboard", "keyTaps": typed.taps, "doneTapped": typed.submitted,
            "textUTF8Bytes": text.utf8.count, "insertionVerified": false,
        ] as [String: Any], options: [.prettyPrinted, .sortedKeys])
    }
}
