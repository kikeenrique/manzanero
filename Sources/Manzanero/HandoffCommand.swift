import Foundation
import Darwin

struct HandoffCommand: Sendable {
    let platform: String
    let device: String
    let message: String
    let timeoutSeconds: Int
    let target: DeviceTarget

    static func parse(_ args: [String]) throws -> Self? {
        guard args.count >= 3, ["physical", "simulator"].contains(args[0]), args[2] == "handoff" else { return nil }
        guard (4...5).contains(args.count), let identifier = DeviceTarget.identifier(args[1]),
              args[0] != "simulator" || UUID(uuidString: args[1]) != nil,
              args[0] != "physical" || UUID(uuidString: args[1]) == nil,
              !args[3].isEmpty, args[3].utf8.count <= 2048,
              args[3].unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0.value == 9 || $0.value == 10 }),
              let timeout = Int(args.count == 5 ? args[4] : "300"), (1...3600).contains(timeout) else {
            throw CommandFailure(description: "Usage: <physical|simulator> <UDID> handoff <message> [terminal-timeout-seconds: 1...3600]. Message must be 1...2048 UTF-8 bytes without terminal control codes.")
        }
        return Self(platform: args[0], device: args[1], message: args[3], timeoutSeconds: timeout, target: DeviceTarget(platform: args[0], identifier: identifier))
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
            throw CommandFailure(description: "Handoff needs an interactive terminal, or an MCP host with form elicitation support.")
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
            guard ready >= 0 else { throw CommandFailure(description: "Unable to read handoff confirmation.") }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(input, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CommandFailure(description: "Unable to read handoff confirmation.") }
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
