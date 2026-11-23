import Foundation

/// Orientation, interface settings, a simulated location, status bar
/// overrides and reading the clipboard, through Apple's `devicectl`, which
/// addresses a booted simulator by its UUID as it addresses a device (checked
/// on an iPhone simulator for each of these on 2026-11-21). Each changes the
/// target's state except `clipboard`, which reads it.
enum DeviceSettings {
    static let operations = ["rotate", "settings", "settings-read", "location", "status-bar", "clipboard"]
    /// `settings` without options: the current values, read-only
    /// (`devicectl device info appearance`).
    static let readOperation = "settings-read"

    /// `rotate` operand → devicectl orientation.
    static let orientations: [(name: String, devicectl: String)] = [
        ("portrait", "portrait"), ("portrait-upside-down", "portraitUpsideDown"),
        ("landscape-left", "landscapeLeft"), ("landscape-right", "landscapeRight"),
    ]
    static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                            "accessibility-medium", "accessibility-large", "accessibility-extra-large",
                            "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    static let dataNetworks = ["hide", "wifi", "hotspot", "1x", "GPRS", "Edge", "UMTS", "4G", "LTE", "LTEA", "LTEPlus", "5G", "5GPlus", "5GUWB", "5GUC"]
    static let batteryStates = ["draining", "charging", "charged"]
    static let clear = "--clear"
    /// `settings` options that are devicectl subcommands of their own.
    static let ownSubcommands = ["--voiceover", "--standby", "--standby-seconds"]
    static let standbySeconds = 1...600
    /// Stands for the result file a clipboard read writes, named per run.
    static let resultPlaceholder = "<result file>"
    /// The most clipboard text a read returns.
    static let clipboardLimit = 1_048_576

    /// The `devicectl` invocation for one of `operations`, or nil for any
    /// other operation. Operands are the internal form the CLI builds:
    /// `rotate <orientation>`; `settings` and `status-bar` as `--name value`
    /// pairs (or `--clear`); `location <latitude> <longitude>` or `--clear`.
    static func plan(device: String, operation: String, operands: [String]) throws -> DeviceCommand? {
        guard operations.contains(operation) else { return nil }
        let tail = ["--device", device, "--timeout", "30"]
        func json(_ command: [String]) -> DeviceCommand {
            DeviceCommand(arguments: ["devicectl", "device"] + command + tail + ["--json-output", "-"], jsonOutput: true)
        }
        switch operation {
        case "rotate":
            guard operands.count == 1, let orientation = orientations.first(where: { $0.name == operands[0] }) else {
                throw CommandFailure.usage("rotate takes one of \(orientations.map(\.name).joined(separator: ", ")).")
            }
            return json(["orientation", "set", orientation.devicectl])
        case readOperation:
            guard operands.isEmpty else { throw CommandFailure.usage("Reading the settings takes no operands.") }
            return json(["info", "appearance"])
        case "settings":
            // VoiceOver and StandBy are devicectl subcommands of their own,
            // so each is one call, alone.
            if let own = operands.first, ownSubcommands.contains(own) {
                let pairs = try Self.pairs(operands, allowed: [
                    "--voiceover": ["on", "off"], "--standby": ["show", "hide"], "--standby-seconds": nil,
                ], subject: "settings")
                let names = Set(pairs.map(\.0))
                guard names.count == 1 || names == ["--standby", "--standby-seconds"] else {
                    throw CommandFailure.usage("settings takes --voiceover or --standby alone, in a call of its own: each is a devicectl subcommand of its own.")
                }
                let values = Dictionary(uniqueKeysWithValues: pairs)
                if let voiceover = values["--voiceover"] {
                    return json(["settings", "voiceover", voiceover == "on" ? "--enable" : "--disable"])
                }
                guard let standby = values["--standby"] else { throw CommandFailure.usage("--standby-seconds goes with --standby show.") }
                guard let seconds = values["--standby-seconds"] else { return json(["settings", "standby", "--\(standby)"]) }
                guard standby == "show", let count = Int(seconds), standbySeconds.contains(count) else {
                    throw CommandFailure.usage("--standby-seconds takes \(standbySeconds.lowerBound)...\(standbySeconds.upperBound) with --standby show.")
                }
                // devicectl keeps StandBy up for the duration, so its own
                // timeout must outlast it.
                return DeviceCommand(arguments: ["devicectl", "device", "settings", "standby", "--show", "--duration", seconds,
                    "--device", device, "--timeout", String(count + 30), "--json-output", "-"], jsonOutput: true)
            }
            let pairs = try Self.pairs(operands, allowed: [
                "--appearance": ["light", "dark"], "--text-size": textSizes,
                "--increase-contrast": ["on", "off"], "--reduce-motion": ["on", "off"],
            ], subject: "settings")
            var command = ["settings", "appearance"]
            for (name, value) in pairs {
                command += [name == "--appearance" ? "--mode" : name, value]
                // devicectl needs Larger Accessibility Sizes on for those sizes.
                if name == "--text-size", value.hasPrefix("accessibility-") { command += ["--larger-accessibility-sizes", "on"] }
            }
            return json(command)
        case "location":
            if operands == [clear] { return json(["simulate", "location", "clear"]) }
            guard operands.count == 2, let latitude = Double(operands[0]), let longitude = Double(operands[1]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw CommandFailure.usage("location takes <latitude>,<longitude> in decimal degrees (latitude -90...90, longitude -180...180), or --clear.")
            }
            // Attached with '=', so a negative value is not read as an option.
            return json(["simulate", "location", "coordinate", "--latitude=\(operands[0])", "--longitude=\(operands[1])"])
        case "status-bar":
            if operands == [clear] { return json(["simulate", "statusBar", "clear"]) }
            let pairs = try Self.pairs(operands, allowed: [
                "--time": nil, "--battery-level": (0...100).map(String.init), "--battery-state": batteryStates,
                "--wifi-bars": ["1", "2", "3"], "--cellular-bars": ["1", "2", "3", "4", "5"], "--data-network": dataNetworks,
            ], subject: "status-bar")
            var command = ["simulate", "statusBar", "override"]
            for (name, value) in pairs {
                switch name {
                case "--wifi-bars": command += ["--wifi-mode", "active", "--wifi-strength", value]
                case "--cellular-bars": command += ["--cellular-mode", "active", "--cellular-strength", value]
                default: command += ["\(name)=\(value)"]
                }
            }
            return json(command)
        default:
            guard operands.isEmpty else { throw CommandFailure.usage("clipboard takes no operands.") }
            // The text is the command's stdout, so its JSON goes to a file.
            return DeviceCommand(arguments: ["devicectl", "device", "pasteboard", "paste"] + tail + ["--json-output", resultPlaceholder],
                                 jsonOutput: false)
        }
    }

    /// `--name value` pairs, each name at most once and at least one, with a
    /// value from its list (nil: any text of 1...64 bytes).
    private static func pairs(_ operands: [String], allowed: [String: [String]?], subject: String) throws -> [(String, String)] {
        guard !operands.isEmpty, operands.count % 2 == 0 else {
            throw CommandFailure.usage("\(subject) needs at least one of \(allowed.keys.sorted().joined(separator: ", ")).")
        }
        var seen: Set<String> = []
        return try stride(from: 0, to: operands.count, by: 2).map { index in
            let name = operands[index], value = operands[index + 1]
            guard let choices = allowed[name] else { throw CommandFailure.usage("\(subject) does not take \(name).") }
            guard seen.insert(name).inserted else { throw CommandFailure.usage("\(subject) takes \(name) once.") }
            if let choices {
                guard choices.contains(value) else {
                    throw CommandFailure.usage("\(name) is one of \(choices.count > 20 ? "\(choices.first!)...\(choices.last!)" : choices.joined(separator: ", ")).")
                }
            } else {
                guard (1...64).contains(value.utf8.count), !value.contains("\0") else { throw CommandFailure.usage("\(name) takes 1...64 bytes of text.") }
            }
            return (name, value)
        }
    }

    /// A clipboard read's result: the text devicectl wrote to stdout, with
    /// the type and size from its result file. An empty clipboard is
    /// `empty: true` with no text.
    static func clipboardResult(stdout: Data, resultFile: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: resultFile) as? [String: Any],
              (root["info"] as? [String: Any])?["outcome"] as? String == "success" else {
            throw CommandFailure(.toolFailed, "devicectl's pasteboard result could not be read.", inputSent: .none)
        }
        let result = root["result"] as? [String: Any] ?? [:]
        guard let type = result["contentType"] as? String else { return ["empty": true] }
        let truncated = stdout.count > clipboardLimit
        var text = String(decoding: stdout.prefix(clipboardLimit), as: UTF8.self)
        // devicectl ends the payload with one newline of its own.
        if text.hasSuffix("\n"), let size = (result["contentSize"] as? NSNumber)?.intValue, stdout.count == size + 1 { text.removeLast() }
        return ["empty": false, "text": text, "contentType": type,
                "bytes": (result["contentSize"] as? NSNumber)?.intValue ?? stdout.count, "truncated": truncated]
    }
}
