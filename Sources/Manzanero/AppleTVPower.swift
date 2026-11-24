import Foundation

/// `remote sleep` and `remote wake` on a physical Apple TV
/// (docs/other-families.md#sleep-and-wake).
///
/// Sleep is Control Centre's Power Off. `button lock` opens Control Centre,
/// which the system UI process draws over whatever is in front, and Power
/// Off is an element of that process's accessibility tree with the
/// identifier `sleep`, in any language. The command presses that element by
/// accessibility: found, seen visible and activated in one session, so no
/// remote select is sent and nothing depends on where the focus is.
///
/// It was first built on a remote select, which is how a person does it,
/// and that is not safe: with an app in front the select, a keyboard usage,
/// goes to the app although Control Centre is on the screen. On 2026-11-20
/// it pressed a button of the tvOS probe twice, once a second after a
/// picture that showed Power Off in focus.
///
/// A sleeping Apple TV is told from an awake one by its screenshot, which
/// fails with a zero-sized display; one Home press wakes it.
enum AppleTVPower {
    static let names = ["sleep", "wake"]
    static let usage = "remote sleep and remote wake take no option; no input sent."
    static let simulatorRefusal = "remote sleep and remote wake work on a physical Apple TV only: Power Off puts an Apple TV simulator to sleep and nothing sent to it wakes it (shutdown and boot do). No input sent."
    /// Control Centre belongs to this process, not to the application in
    /// front, and its tree is there only while Control Centre is open: 44
    /// nodes then and 9 without it, on an Apple TV 4K with tvOS 27.2.
    static let systemUIExecutable = "/TVSystemUIService.app/TVSystemUIService"
    /// Power Off's accessibility identifier there, whatever the language.
    static let powerOffIdentifier = "sleep"

    static func handles(_ operands: [String]) -> Bool { operands.first.map(names.contains) ?? false }

    static func validate(_ operands: [String]) throws {
        guard operands.count == 1, handles(operands) else { throw CommandFailure.usage(usage) }
    }

    static func plan(_ input: CoreDeviceInput) throws -> [String: Any] {
        try validate(input.operands)
        let sleep = input.operands[0] == "sleep"
        return ["backend": "coredevice-direct", "operation": "remote", "remote": input.operands[0],
            "identityArguments": try input.identityPlan().arguments,
            "maximumPresses": sleep ? ["lock": 1, "power-off": 1] : ["home": 1],
            "liveVerification": "one Apple TV 4K (3rd generation), tvOS 27.2",
            "execution": sleep
                ? "Read the device's details; only if they say it is an Apple TV, take a screenshot. If it fails with a zero-sized display the device is asleep already and nothing is sent. Otherwise press the power button once (button lock), which opens Control Centre, find the system UI process among the device's processes, and press Power Off there by accessibility, by its identifier sleep: the element must be in that process's tree and visible, and it is activated once (a connection to the device's service directory, as every accessibility command on an Apple TV). No remote select is sent. Then take screenshots until one fails. No press is repeated."
                : "Read the device's details; only if they say it is an Apple TV, take a screenshot. If it succeeds the device is awake already and nothing is sent. Otherwise (a zero-sized display, or a capture refused with error 25004) press Home once, then take screenshots until one succeeds. While the device's HID service refuses the press before any input (\"did not become ready\"), wait \(hidWaitInterval.components.seconds) s and ask again, at most \(hidWaits) times. The television connected to the device may come on. No press is repeated."]
    }

    /// The system UI process among a device's running processes.
    static func systemUIProcess(_ processes: Data) -> Int32? {
        guard let root = (try? JSONSerialization.jsonObject(with: processes)) as? [String: Any],
              let running = (root["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]],
              let pid = running.first(where: { ($0["executable"] as? String)?.hasSuffix(systemUIExecutable) == true })?["processIdentifier"] as? Int
        else { return nil }
        return Int32(exactly: pid)
    }

    /// How the command reaches the device; tests replace all of it.
    struct Environment {
        /// A screenshot's file, or nil when the device refuses one with a
        /// zero-sized display: asleep.
        var capture: () throws -> URL?
        /// Presses Power Off in Control Centre by accessibility. False when
        /// Control Centre does not show it, with nothing pressed.
        var pressPowerOff: () async throws -> Bool
        /// One press: `lock` or `home`.
        var press: (String) throws -> Void
        var settle: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// The live environment: screenshots through `query` into `directory`,
    /// button presses over the routes `button` and `remote` use, and Power
    /// Off over the physical accessibility route.
    static func live(_ input: CoreDeviceInput, details: Data, directory: URL, query: @escaping (DeviceCommand) throws -> Data) -> Environment {
        var number = 0
        return Environment(
            capture: {
                number += 1
                return try screenshot(device: input.device, to: directory.appendingPathComponent("power-\(number).png"), query: query)
            },
            pressPowerOff: {
                var plan = try DeviceCommand.plan(physical: true, device: input.device, operation: "processes", operands: [])
                plan.arguments.append("--quiet")
                guard let pid = systemUIProcess(try query(plan)) else { return false }
                let press = try CoreDeviceInput.validated(device: input.device, operation: "press-id", operands: [String(pid), powerOffIdentifier])
                do {
                    // The one use of `overlayProcess`: Control Centre is on
                    // the screen and its process is not the frontmost one.
                    _ = try await DirectPhysicalAccessibility.executeNativeRSD(press, overlayProcess: pid, query: query)
                    return true
                } catch let failure as CommandFailure where failure.code == .targetUnresolved && failure.inputSent == CommandFailure.InputSent.none {
                    return false
                }
            },
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

    /// A screenshot refused with "The screen capture operation failed"
    /// (CoreDevice error 25004). Seen once, ten minutes after a `remote
    /// sleep` (2026-11-24): the device was asleep and one Home press woke it.
    /// It is not proof of sleep, so only `wake` acts on it, by the human
    /// owner's decision of 2026-11-24: one Home press, as on a sleeping
    /// device; `sleep` and `readiness` still read it as unknown.
    static func captureRefused(_ error: any Error) -> Bool {
        let text = String(describing: error)
        return text.contains("25004") || text.contains("screen capture operation failed")
    }

    /// One screenshot into `image`: its file, or nil when the device refuses
    /// it as asleep. Any other failure is thrown.
    static func screenshot(device: String, to image: URL, query: (DeviceCommand) throws -> Data) throws -> URL? {
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            _ = try query(DeviceCommand.plan(physical: true, device: device, operation: "screenshot", operands: [image.path]))
        } catch where isAsleep(error) { return nil }
        return image
    }

    /// An Apple TV asleep for hours can refuse input before any is sent:
    /// "Apple HID service did not become ready; no input sent." (2026-11-20,
    /// and again on 2026-11-23 for an agent's `remote wake`). Nothing went
    /// out, so the wake waits and asks again; it is not a repeated press.
    static func hidNotReady(_ failure: CommandFailure) -> Bool {
        failure.inputSent == .none && failure.description.contains("HID service did not become ready")
    }

    /// How long a wake waits between two refusals, and how many it takes:
    /// about a minute, plus the bridge's own three seconds each time.
    static let hidWaitInterval = Duration.seconds(5)
    static let hidWaits = 12

    /// How many screenshots are taken, and how far apart, while waiting for
    /// the device to fall asleep or to wake.
    static let checks = 4
    static let checkInterval = Duration.seconds(3)
    static let controlCentreSettle = Duration.milliseconds(1500)

    /// `operation` is the command's name in the receipt: `remote`, or `wake`,
    /// which on an Apple TV does what `remote wake` does.
    static func execute(_ input: CoreDeviceInput, details: Data, environment: Environment, operation: String = "remote",
                        isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try validate(input.operands)
        let name = input.operands[0]
        _ = try DirectPhysicalInput.identity(input, query: { _ in details })
        guard AppleTVRemote.deviceType(details) == "appleTV" else {
            throw CommandFailure.unsupported("remote drives an Apple TV; this device reports the type \(AppleTVRemote.deviceType(details) ?? "unknown"). No input sent.")
        }
        var result: [String: Any] = ["backend": "coredevice-direct", "operation": operation, "device": input.device,
            "limitations": ["Asleep and awake are read from whether the device gives a screenshot, before and after; nothing else says so.",
                            "Any command to a sleeping Apple TV may switch it on, and its television with it."]]
        if operation == "remote" { result["remote"] = name }
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
        /// Whether a screenshot shows the device awake. For a wake, a
        /// screenshot refused with 25004 counts as not awake yet.
        func givesPicture() async throws -> Bool {
            try await guarded {
                do {
                    return try environment.capture() != nil
                } catch where name == "wake" && captureRefused(error) {
                    return false
                }
            }
        }
        /// Screenshots until one says `asleep`, a few seconds apart.
        func becomes(asleep: Bool) async throws -> Bool {
            for _ in 0..<checks {
                try await guarded { try await environment.settle(checkInterval) }
                if try await givesPicture() != asleep { return true }
            }
            return false
        }

        if name == "wake" {
            let before: URL?
            do {
                before = try environment.capture()
            } catch where captureRefused(error) {
                before = nil
                result["screenshotRefused"] = "The screenshot before the press was refused with CoreDevice error 25004, not the zero-sized display of a sleeping device; Home is pressed once all the same, as for a sleeping one."
            }
            guard before == nil else { return try finish("already-awake") }
            var waits = 0
            while true {
                do {
                    try await press("home")
                    break
                } catch let failure as CommandFailure where hidNotReady(failure) {
                    guard waits < hidWaits else {
                        throw CommandFailure(.deviceNotReady, "The Apple TV is asleep and its HID service did not become ready after \(waits) waits of \(hidWaitInterval.components.seconds) s; no input sent. A device asleep for hours can take longer to answer: try again in a few minutes.", inputSent: .none)
                    }
                    waits += 1
                    try await environment.settle(hidWaitInterval)
                }
            }
            result["hidWaits"] = waits
            return try await becomes(asleep: false)
                ? finish("awake")
                : finish("not-awake", action: "Home was pressed once and the device still gives no screenshot. It is not pressed again automatically; an Apple TV asleep for hours can take a minute to answer.", exitCode: 1)
        }
        guard try environment.capture() != nil else { return try finish("already-asleep") }
        try await press("lock")
        try await guarded { try await environment.settle(controlCentreSettle) }
        guard try await guarded({ try await environment.pressPowerOff() }) else {
            return try finish("control-centre-not-seen", action: "The power button was pressed once and the system UI's accessibility tree does not show Power Off, so nothing more was pressed. Control Centre may not have opened (from a screen saver the button only wakes the device). Look at the screen; if Control Centre is open it closes by itself.", exitCode: 1)
        }
        pressed.append("power-off")
        return try await becomes(asleep: true)
            ? finish("asleep")
            : finish("not-asleep", action: "Power Off was pressed once by accessibility and the device still gives screenshots. Nothing is pressed again automatically; look at the screen.", exitCode: 1)
    }
}
