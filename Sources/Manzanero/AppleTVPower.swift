import CoreGraphics
import Foundation
import ImageIO

/// `remote sleep` and `remote wake` on a physical Apple TV
/// (docs/other-families.md#sleep-and-wake).
///
/// Sleep is Control Centre's Power Off: `button lock` opens Control Centre
/// with Power Off in focus, and a select then puts the device to sleep, but
/// only with the Home Screen in front. With an app in front the select, a
/// keyboard usage, goes to the app: on 2026-11-20 it pressed a button of the
/// tvOS probe twice while a picture a second old showed Power Off in focus.
/// So the command presses Home first. Control Centre is in no accessibility
/// tree and Apple's Inspector cursor does not reach it, so the focus is read
/// from a screenshot, and the select is sent only when that picture shows
/// Power Off with the focus on it. If the select misses all the same, it
/// opens the Home Screen icon in focus.
///
/// A sleeping Apple TV is told from an awake one by its screenshot, which
/// fails with a zero-sized display; one Home press wakes it.
enum AppleTVPower {
    static let names = ["sleep", "wake"]
    static let usage = "remote sleep and remote wake take no option; no input sent."
    static let simulatorRefusal = "remote sleep and remote wake work on a physical Apple TV only: Power Off puts an Apple TV simulator to sleep and nothing sent to it wakes it (shutdown and boot do). No input sent."
    /// The words tvOS shows under Power Off, as read from the screen. Only
    /// English has been seen; another language stops before the select.
    static let powerOffLabels = ["power off"]
    /// The tile in focus is white with dark text; the others are grey with
    /// white text.
    static let focusedBackground = 0.85
    static let darkText = 0.35

    static func handles(_ operands: [String]) -> Bool { operands.first.map(names.contains) ?? false }

    static func validate(_ operands: [String]) throws {
        guard operands.count == 1, handles(operands) else { throw CommandFailure.usage(usage) }
    }

    static func plan(_ input: CoreDeviceInput) throws -> [String: Any] {
        try validate(input.operands)
        let sleep = input.operands[0] == "sleep"
        return ["backend": "coredevice-direct", "operation": "remote", "remote": input.operands[0],
            "identityArguments": try input.identityPlan().arguments,
            "maximumPresses": sleep ? ["home": 1, "lock": 1, "select": 1] : ["home": 1],
            "liveVerification": "one Apple TV 4K (3rd generation), tvOS 27.2, in English",
            "execution": sleep
                ? "Read the device's details; only if they say it is an Apple TV, take a screenshot. If it fails with a zero-sized display the device is asleep already and nothing is sent. Otherwise press Home once, which leaves the app in front for the Home Screen, then the power button once (button lock), which opens Control Centre; take a screenshot and read it: only if it shows Power Off with the focus on it, send one select at once, then take screenshots until one fails. No press is repeated. If the select misses Control Centre it opens the Home Screen icon in focus."
                : "Read the device's details; only if they say it is an Apple TV, take a screenshot. If it succeeds the device is awake already and nothing is sent. Otherwise press Home once, then take screenshots until one succeeds. The television connected to the device may come on. No press is repeated."]
    }

    /// The share of a tile's pixels around a text: its background (the
    /// median luminance) and its darkest pixel, both in 0...1.
    struct Tile: Equatable, Sendable {
        let background: Double
        let darkest: Double
        var focused: Bool { background >= AppleTVPower.focusedBackground && darkest <= AppleTVPower.darkText }
    }

    /// What surrounds a recognised text in the picture: the text's box, a
    /// third of its height wider on each side.
    static func tile(image url: URL, around region: ScreenText.Region) throws -> Tile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CommandFailure(.toolFailed, "The screenshot could not be read: \(url.path)", inputSent: .none)
        }
        let margin = region.height / 3
        let box = CGRect(x: (region.x - margin) * Double(image.width), y: (region.y - margin) * Double(image.height),
                         width: (region.width + 2 * margin) * Double(image.width), height: (region.height + 2 * margin) * Double(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard box.width >= 1, box.height >= 1, let cropped = image.cropping(to: box) else {
            throw CommandFailure(.toolFailed, "The text's place is outside the screenshot.", inputSent: .none)
        }
        return try tile(cropped)
    }

    static func tile(_ image: CGImage) throws -> Tile {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, !pixels.isEmpty else { throw CommandFailure(.toolFailed, "The screenshot's pixels could not be read.", inputSent: .none) }
        pixels.sort()
        return Tile(background: Double(pixels[pixels.count / 2]) / 255, darkest: Double(pixels[0]) / 255)
    }

    /// How the command reaches the device and reads its screen; tests
    /// replace all of it.
    struct Environment {
        /// A screenshot's file, or nil when the device refuses one with a
        /// zero-sized display: asleep.
        var capture: () throws -> URL?
        var recognize: (URL) async throws -> [ScreenText.Region]
        var tile: (URL, ScreenText.Region) throws -> Tile = AppleTVPower.tile(image:around:)
        /// One press: `lock`, `select` or `home`.
        var press: (String) throws -> Void
        var settle: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// The live environment: screenshots through `query` into `directory`,
    /// presses over the routes `button` and `remote` use.
    static func live(_ input: CoreDeviceInput, details: Data, directory: URL, query: @escaping (DeviceCommand) throws -> Data) -> Environment {
        var number = 0
        return Environment(
            capture: {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                number += 1
                let image = directory.appendingPathComponent("power-\(number).png")
                do {
                    _ = try query(DeviceCommand.plan(physical: true, device: input.device, operation: "screenshot", operands: [image.path]))
                } catch where isAsleep(error) { return nil }
                return image
            },
            recognize: { try await ScreenText.recognize(path: $0.path).regions },
            press: { name in
                if name == "lock" {
                    _ = try DirectPhysicalInput.execute(CoreDeviceInput(device: input.device, operation: "button", operands: [name]), query: { _ in details })
                } else {
                    _ = try AppleTVRemote.execute(CoreDeviceInput(device: input.device, operation: "remote", operands: [name]), query: { _ in details })
                }
            })
    }

    /// A sleeping Apple TV refuses a screenshot with "Display reports
    /// zero-sized native size" (CoreDevice error 25005), the one sign of
    /// sleep found.
    static func isAsleep(_ error: any Error) -> Bool {
        let text = String(describing: error)
        return text.contains("zero-sized") || text.contains("25005")
    }

    /// How many screenshots are taken, and how far apart, while waiting for
    /// the device to fall asleep or to wake.
    static let checks = 4
    static let checkInterval = Duration.seconds(3)
    static let controlCentreSettle = Duration.milliseconds(1500)

    static func execute(_ input: CoreDeviceInput, details: Data, environment: Environment,
                        isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try validate(input.operands)
        let name = input.operands[0]
        _ = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard AppleTVRemote.deviceType(details) == "appleTV" else {
            throw CommandFailure.unsupported("remote drives an Apple TV; this device reports the type \(AppleTVRemote.deviceType(details) ?? "unknown"). No input sent.")
        }
        var result: [String: Any] = ["backend": "coredevice-direct", "operation": "remote", "remote": name, "device": input.device,
            "pressed": [String](), "verified": false,
            "limitations": ["Asleep and awake are read from whether the device gives a screenshot, before and after; nothing else says so.",
                            "Any command to a sleeping Apple TV may switch it on, and its television with it."]]
        var pressed: [String] = []
        // Once a press went out, a later failure leaves the device changed.
        func guarded<T>(_ body: () async throws -> T) async throws -> T {
            do {
                try Task.checkCancellation()
                return try await body()
            } catch let failure as CommandFailure where !pressed.isEmpty {
                throw failure.inputPossiblySent()
            }
        }
        func press(_ button: String) async throws {
            try await guarded { try environment.press(button) }
            pressed.append(button)
        }
        func finish(_ status: String, action: String? = nil, exitCode: Int32 = 0) throws -> Data {
            result["status"] = status
            result["pressed"] = pressed
            result["verified"] = ["asleep", "awake", "already-asleep", "already-awake"].contains(status)
            if let action { result["action"] = action }
            result["exitCode"] = Int(exitCode)
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        /// Screenshots until one says `asleep`, a few seconds apart.
        func becomes(asleep: Bool) async throws -> Bool {
            for _ in 0..<checks {
                try await guarded { try await environment.settle(checkInterval) }
                if try await guarded({ try environment.capture() == nil }) == asleep { return true }
            }
            return false
        }

        let before = try environment.capture()
        if name == "wake" {
            guard before == nil else { return try finish("already-awake") }
            try await press("home")
            return try await becomes(asleep: false)
                ? finish("awake")
                : finish("not-awake", action: "Home was pressed once and the device still gives no screenshot. It is not pressed again automatically; an Apple TV asleep for hours can take a minute to answer.", exitCode: 1)
        }
        guard before != nil else { return try finish("already-asleep") }
        // With an app in front the select goes to the app, not to Control
        // Centre; with the Home Screen in front it goes to Power Off.
        try await press("home")
        try await guarded { try await environment.settle(controlCentreSettle) }
        try await press("lock")
        try await guarded { try await environment.settle(controlCentreSettle) }
        guard let picture = try await guarded({ try environment.capture() }) else {
            return try finish("asleep", action: "The device gave no screenshot after the power button alone; no select was sent.")
        }
        let regions = try await guarded { try await environment.recognize(picture) }
        guard let powerOff = regions.first(where: { powerOffLabels.contains($0.text.trimmingCharacters(in: .whitespaces).lowercased()) }) else {
            return try finish("control-centre-not-seen", action: "Home and the power button were pressed once each and the screenshot after them does not show Power Off, so no select was sent. Control Centre may not have opened (from a screen saver a press only wakes the device), or the device's language is not English. Look at the screen; if Control Centre is open it closes by itself.", exitCode: 1)
        }
        let tile = try await guarded { try environment.tile(picture, powerOff) }
        result["powerOffTile"] = ["background": tile.background, "darkest": tile.darkest, "focused": tile.focused]
        guard tile.focused else {
            return try finish("power-off-not-in-focus", action: "Control Centre is open and Power Off does not look in focus, so no select was sent. Control Centre closes by itself.", exitCode: 1)
        }
        try await press("select")
        return try await becomes(asleep: true)
            ? finish("asleep")
            : finish("not-asleep", action: "Power Off was selected once and the device still gives screenshots. Nothing is pressed again automatically; look at the screen.", exitCode: 1)
    }
}
