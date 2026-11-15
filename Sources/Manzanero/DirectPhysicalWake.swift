import Foundation

/// Guarded wake for a device whose display was turned off.
///
/// The side button toggles the display, so a press is only safe when the
/// display is known to be off. This reads Apple's display state twice, presses
/// the side button at most once, and reads the state again. It never repeats a
/// press: a second press could turn off a display the first one lit.
///
/// A lock screen goes dark again after a few seconds, so on a device without a
/// passcode the wake is followed by one Home press to leave it. A device that
/// requires a passcode is woken and reported as needing a person; no passcode
/// is ever entered.
enum DirectPhysicalWake {
    static let operation = "wake"
    static let noDismissFlag = "--no-dismiss"

    static func validate(_ operands: [String]) throws {
        guard operands.isEmpty || operands == [noDismissFlag] else {
            throw CommandFailure(description: "Usage: physical <UDID> wake [\(noDismissFlag)]")
        }
    }

    static func plan(_ input: CoreDeviceInput) throws -> [String: Any] {
        try validate(input.operands)
        return ["backend": "coredevice-direct", "operation": operation, "identityArguments": try input.identityPlan().arguments,
            "dismissLockScreen": input.operands.isEmpty, "maximumSideButtonPresses": 1, "liveVerified": false,
            "execution": "Read Apple display and passcode state twice. Only if the primary display is off both times, press the side button once in process, then read the state again. If the display is then on and no passcode is required, press Home once to leave the lock screen. No press when the display is on or its state is unknown; no retry; no passcode entry."]
    }

    /// `press` sends one hardware button. `settle` waits for the display to
    /// respond before it is read again.
    static func execute(_ input: CoreDeviceInput, query: (DeviceCommand) throws -> Data,
                        press: (CoreDeviceInput, Data) throws -> Void = { button, details in
                            _ = try DirectPhysicalInput.execute(button, query: { _ in details })
                        },
                        settle: (Duration) -> Void = { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }) throws -> Data {
        try validate(input.operands)
        let dismiss = input.operands.isEmpty
        let details = try query(input.identityPlan())
        _ = try DirectPhysicalInput.identity(input, query: { _ in details })
        func observe() throws -> DeviceUIReadiness {
            try Task.checkCancellation()
            return try DeviceUIReadiness.observe(details: details, device: input.device, query: query)
        }
        func button(_ name: String) throws {
            try Task.checkCancellation()
            try press(CoreDeviceInput(device: input.device, operation: "button", operands: [name]), details)
        }
        var result: [String: Any] = ["backend": "coredevice-direct", "operation": operation, "device": input.device,
            "sideButtonPressed": false, "homePressed": false,
            "limitations": ["Display power is Apple's reported backlight state, read before and after; it can change immediately.",
                            "An awake display does not prove the UI is unlocked or which screen is shown. Inspect before acting."]]
        func finish(_ status: String, _ state: DeviceUIReadiness, action: String? = nil, exitCode: Int32 = 0) throws -> Data {
            result["status"] = status
            result["displayPower"] = state.displayPower
            result["passcodeRequired"] = state.passcodeRequired.map { $0 as Any } ?? NSNull()
            if let action { result["action"] = action }
            result["exitCode"] = Int(exitCode)
            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let before = try observe()
        result["displayPowerBefore"] = before.displayPower
        if before.displayPower == "on" { return try finish("already-awake", before) }
        guard before.displayPower == "off" else {
            return try finish("unknown-display-state", before, action: "Display power could not be read; no button pressed. Check the device and try again.", exitCode: 1)
        }
        // The press toggles, so require the same reading twice before sending it.
        let confirmed = try observe()
        guard confirmed.displayPower == "off" else {
            return try finish(confirmed.displayPower == "on" ? "already-awake" : "unknown-display-state", confirmed,
                              action: confirmed.displayPower == "on" ? nil : "Display power changed while reading; no button pressed.",
                              exitCode: confirmed.displayPower == "on" ? 0 : 1)
        }
        try button("lock")
        result["sideButtonPressed"] = true
        settle(.milliseconds(700))
        let woken = try observe()
        guard woken.displayPower == "on" else {
            return try finish("not-awake", woken, action: "The side button was pressed once and the display is not reported on. It is not pressed again automatically; check the device.", exitCode: 1)
        }
        guard woken.passcodeRequired == false else {
            return try finish("awake-locked", woken, action: woken.passcodeRequired == true
                ? "The device requires a passcode. Unlock it directly; the tool does not enter passcodes."
                : "Passcode state is unknown, so the lock screen was left alone. Unlock the device directly.", exitCode: 1)
        }
        guard dismiss else { return try finish("awake", woken) }
        try button("home")
        result["homePressed"] = true
        settle(.milliseconds(700))
        return try finish("awake", try observe())
    }

    /// The JSON carries its own exit code so a refused or failed wake is an
    /// answer on stdout, not only an error message.
    static func output(_ data: Data) throws -> CommandOutput {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root.removeValue(forKey: "exitCode") as? Int else {
            throw CommandFailure(description: "Invalid internal wake result.")
        }
        return CommandOutput(data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), exitCode: Int32(code))
    }
}
