import Foundation
import Darwin

struct HandoffCommand: Sendable, Equatable {
    let platform: String
    let device: String
    let message: String
    let timeoutSeconds: Int
    let target: DeviceTarget

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

    func output(_ status: HandoffStatus, mechanism: String) throws -> CommandOutput {
        let acknowledged = status == .acknowledged
        let data = try JSONSerialization.data(withJSONObject: ["status": status.rawValue, "platform": platform,
            "device": device, "humanAcknowledged": acknowledged, "verified": false, "mechanism": mechanism], options: [.prettyPrinted, .sortedKeys])
        return CommandOutput(data: data, exitCode: acknowledged ? 0 : 1)
    }
}

enum HandoffStatus: String, Sendable { case acknowledged, declined, cancelled, notCompleted, timedOut }

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
