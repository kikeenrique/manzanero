import Foundation
import Darwin

struct HandoffCommand: Sendable, Equatable {
    let platform: String
    let device: String
    let message: String
    let timeoutSeconds: Int
    let target: DeviceTarget
    /// What "finished" looks like on the device. With one, the handoff
    /// watches for it and ends by itself; nobody has to answer.
    var condition: HandoffCondition? = nil

    /// A handoff that ends when the device shows `until`: `unlocked`,
    /// `paired`, or a `wait` condition (`visible`, `gone`, `enabled`,
    /// `disabled`, `value`, `focused`) on the element `id` or `label` names.
    init(platform: String, device: String, message: String, timeout: String?,
         until: String?, id: String? = nil, label: String? = nil, withValue: String? = nil, index: String? = nil, value: String? = nil) throws {
        try self.init(platform: platform, device: device, message: message, timeout: timeout)
        guard let until else {
            guard id == nil, label == nil, withValue == nil, index == nil, value == nil else {
                throw CommandFailure.usage("handoff: --id, --label, --with-value, --index and --value describe what --until watches; give --until.")
            }
            return
        }
        condition = try HandoffCondition(until: until, platform: platform, device: device, id: id, label: label, withValue: withValue, index: index, value: value)
    }

    /// A physical device takes a hardware UDID, a simulator its UUID.
    init(platform: String, device: String, message: String, timeout: String?) throws {
        guard let identifier = DeviceTarget.identifier(device),
              platform != "simulator" || UUID(uuidString: device) != nil,
              platform != "physical" || UUID(uuidString: device) == nil,
              !message.isEmpty, message.utf8.count <= 2048,
              message.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0.value == 9 || $0.value == 10 }),
              let timeout = Int(timeout ?? "300"), (1...3600).contains(timeout) else {
            throw CommandFailure.usage("Usage: handoff <message> [terminal-timeout-seconds: 1...3600] (--device <UDID> | --simulator <UUID>). Message must be 1...2048 UTF-8 bytes without terminal control codes.")
        }
        self.platform = platform
        self.device = device
        self.message = message
        self.timeoutSeconds = timeout
        self.target = DeviceTarget(platform: platform, identifier: identifier)
    }

    /// `observed` is the device showing the named condition; `acknowledged`
    /// is a person saying so. Both exit 0. `verified` is true only for
    /// `observed`, and only about that condition.
    func output(_ status: HandoffStatus, mechanism: String, extra: [String: Any] = [:]) throws -> CommandOutput {
        let acknowledged = status == .acknowledged, observed = status == .observed
        var result: [String: Any] = ["status": status.rawValue, "platform": platform,
            "device": device, "humanAcknowledged": acknowledged, "verified": observed, "mechanism": mechanism]
        result.merge(extra) { current, _ in current }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return CommandOutput(data: data, exitCode: acknowledged || observed ? 0 : 1)
    }
}

enum HandoffStatus: String, Sendable { case acknowledged, declined, cancelled, notCompleted, timedOut, observed }

/// What a handoff watches the device for.
enum HandoffCondition: Sendable, Equatable {
    /// The display is on and no passcode is required (physical devices).
    case unlocked
    /// CoreDevice reports the device connected and paired (physical devices).
    case paired
    /// A `wait` condition on one element, checked in short waits.
    case element(operation: String, operands: [String], until: String, by: String, text: String, value: String? = nil)

    static let names = ["unlocked", "paired"] + AccessibilityWait.conditionNames
    /// Seconds of one short wait; the handoff repeats it until its deadline.
    static let waitSeconds = 3

    init(until: String, platform: String, device: String, id: String?, label: String?, withValue: String? = nil, index: String?, value: String?) throws {
        let usage = "handoff --until takes \(Self.names.joined(separator: ", ")). unlocked and paired are for physical devices and take no selector; the others take exactly one of --id, --label or --with-value, optionally --index, and --value for value."
        switch until {
        case "unlocked", "paired":
            guard platform == "physical", id == nil, label == nil, withValue == nil, index == nil, value == nil else { throw CommandFailure.usage(usage) }
            self = until == "unlocked" ? .unlocked : .paired
        default:
            guard AccessibilityWait.conditionNames.contains(until), [id, label, withValue].compactMap({ $0 }).count == 1,
                  let text = id ?? label ?? withValue else { throw CommandFailure.usage(usage) }
            let by = id != nil ? "identifier" : withValue != nil ? "value" : "label"
            let operation = "wait-\(AccessibilitySelector.suffix(by: by))"
            var operands = [text]
            if let index { operands += [AccessibilitySelector.indexOption, index] }
            operands += ["--until", until]
            if let value { operands += ["--value", value] }
            operands += ["--timeout", String(Self.waitSeconds)]
            // The wait's own validation is the check: selector, index, value.
            _ = try CommandRequest.input(Target(platform: platform == "physical" ? .physical : .simulator, identifier: device), operation, operands)
            self = .element(operation: operation, operands: operands, until: until, by: by, text: text, value: value)
        }
    }

    var json: [String: Any] {
        switch self {
        case .unlocked: return ["until": "unlocked", "meaning": "display on and no passcode required"]
        case .paired: return ["until": "paired", "meaning": "connected and paired"]
        case .element(_, _, let until, let by, let text, let value):
            var json: [String: Any] = ["until": until, "selector": ["by": by, "text": text]]
            if let value { json["value"] = value }
            return json
        }
    }

    /// One line for the person at a terminal.
    var sentence: String {
        switch self {
        case .unlocked: return "the device unlocked with its display on"
        case .paired: return "the device connected and paired"
        case .element(_, _, let until, let by, let text, let value):
            // "… value 'hola'", not a bare "value": say what is expected.
            return "the element with \(by) '\(text)' \(until)" + (value.map { " '\($0)'" } ?? "")
        }
    }
}

struct DeviceTarget: Hashable, Sendable {
    let platform: String
    let identifier: String
    static func identifier(_ value: String) -> String? {
        if let uuid = UUID(uuidString: value) { return uuid.uuidString }
        if value.range(of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil { return value.uppercased() }
        return nil
    }
}

enum TerminalHandoff {
    static func confirm(_ request: HandoffCommand, input: Int32 = STDIN_FILENO, requireTTY: Bool = true,
                        timeout: Duration? = nil, prompt: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) throws -> HandoffStatus {
        guard !requireTTY || isatty(input) != 0 else {
            throw CommandFailure(.hostRequirement, "Handoff needs an interactive terminal, or an MCP host with form elicitation support.", inputSent: .none)
        }
        prompt("\u{7}Human action needed on \(request.platform) \(request.device):\n\(request.message)\nPerform the action on the device. Type 'done', 'decline', or 'cancel'; do not enter credentials here.\n")
        let deadline = ContinuousClock.now + (timeout ?? .seconds(request.timeoutSeconds))
        var line = Data()
        var overflowed = false
        while ContinuousClock.now < deadline {
            if Task.isCancelled { throw CancellationError() }
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw CommandFailure(.hostRequirement, "Unable to read handoff confirmation.", inputSent: .none) }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(input, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CommandFailure(.hostRequirement, "Unable to read handoff confirmation.", inputSent: .none) }
            if count == 0 { return .cancelled }
            if byte == 10 {
                if overflowed { return .notCompleted }
                switch String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "done": return .acknowledged
                case "decline": return .declined
                case "cancel": return .cancelled
                default: prompt("Type 'done' only after completing the device step, or 'decline'/'cancel'.\n"); line.removeAll(keepingCapacity: true)
                }
            } else {
                if line.count < 64 { line.append(byte) } else { overflowed = true }
            }
        }
        return .timedOut
    }
}
