import Foundation

enum PairingCommand {
    static func plan(_ args: [String]) throws -> DeviceCommand? {
        guard args.first == "pair" else { return nil }
        guard args.count == 5, args[1] == "wifi", !args[2].isEmpty,
              !args[2].hasPrefix("-"), !args[2].contains(where: \.isWhitespace),
              let port = UInt16(args[3]), port > 0, !args[4].isEmpty else {
            throw CommandFailure(description: "Usage: pair wifi <host> <port> <new-record.pairing.plist>")
        }
        guard args[4].hasSuffix(".pairing.plist") else {
            throw CommandFailure(description: "Pairing record path must end in .pairing.plist; these files are excluded from Git.")
        }
        return DeviceCommand(executable: "/usr/bin/env", interactive: true,
                             arguments: ["manzanero-idevice", "pair-wifi", args[2], String(port), args[4]], jsonOutput: true)
    }
}
