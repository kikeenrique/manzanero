import Foundation

/// Names the state in which every `devicectl` query to a connected device
/// times out while input still arrives (docs/other-families.md#a-physical-apple-tv).
///
/// The accessibility route opens its own connection to the device's service
/// directory, and the device then resets the one the Mac's `remoted` holds.
/// `remoted` reconnects, and now and then that reconnect never completes:
/// its state dump lists the device as `attached` with no connect results,
/// and queries time out until the tunnel is replaced. Each further command
/// takes a usage assertion that keeps the stale tunnel alive, so the note
/// tells the caller to stop rather than to retry.
enum StaleDeviceConnection {
    /// `devicectl`'s own words when a query gets no answer.
    static let marker = "Command timeout of"

    static let note = "The Mac's remoted lists a device connection as attached but not connected: the connection has gone stale, "
        + "which this tool's accessibility commands can cause. Do not retry: every command keeps the stale tunnel alive. "
        + "It clears when the tunnel is replaced, after some minutes with no command and no other app holding the device, "
        + "or when remotepairingd and CoreDeviceService are restarted. remote, key and button still reach the device meanwhile."

    /// Apple's `remotectl dumpstate`: read-only, and it contacts no device.
    static let liveDump: @Sendable () throws -> Data = {
        try ToolRunner().run(["dumpstate"], executable: "/usr/libexec/remotectl", timeout: 5)
    }

    /// Whether `remotectl dumpstate` lists a CoreDevice connection whose
    /// state is `attached`: found, but with no working connection. With
    /// `device`, only a connection whose `UniqueDeviceID` is that hardware
    /// UDID counts; a stale entry still carries it.
    static func isListed(in dump: Data, device: String? = nil) -> Bool {
        guard dump.count <= 4 * 1024 * 1024, let text = String(data: dump, encoding: .utf8) else { return false }
        var inDevice = false, attached = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Found ") {
                inDevice = line.contains("(coredevice-device)")
                attached = false
            } else if inDevice, trimmed == "State: attached" {
                if device == nil { return true }
                attached = true
            } else if inDevice, attached, let device, trimmed == "UniqueDeviceID => \(device)" { return true }
        }
        return false
    }

    /// Refuses an accessibility command when the device's connection is
    /// already stale, before it takes the usage assertion that would keep
    /// the stale tunnel alive. Nothing is sent to the device. An unreadable
    /// dump refuses nothing.
    static func refuseIfStale(device: String, operation: String, dump: () throws -> Data = liveDump) throws {
        guard let state = try? dump(), isListed(in: state, device: device) else { return }
        throw CommandFailure(.deviceNotReady, "\(operation) not started. \(note)", inputSent: .none)
    }

    /// The failure with the note added, when it is a query timeout and the
    /// dump shows the state. One read-only call to Apple's `remotectl`, made
    /// only after such a timeout; anything else returns the failure as it was.
    static func annotate(_ failure: CommandFailure, dump: () throws -> Data = liveDump) -> CommandFailure {
        guard failure.description.contains(marker), !failure.description.contains(note),
              let state = try? dump(), isListed(in: state) else { return failure }
        return CommandFailure(failure.code, "\(failure.description) \(note)", inputSent: failure.inputSent, retry: failure.retry, action: failure.action)
    }
}
