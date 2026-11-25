import Foundation

/// A physical device's installed profiles through `devicectl device profile`:
/// `profile list` (read-only) and `profile remove <identifier>`. Apple's
/// watchOS logging profile, which a watch's `logs` needs, was listed and
/// removed this way on 2026-11-25 (docs/app-logs.md#an-apple-watch). There is
/// no install: Apple's logging profiles go on through the paired iPhone.
enum ProfileCommand {
    static let listOperation = "profiles"
    static let removeOperation = "profile-remove"
    static let types = ["configuration", "provisioning"]

    /// The `devicectl device` words for a profile operation, or nil for any
    /// other operation. Operands of `remove`: the identifier, then the type.
    static func plan(operation: String, operands: [String]) throws -> [String]? {
        switch operation {
        case listOperation:
            guard operands.isEmpty else { throw CommandFailure.usage("Usage: profile list") }
            return ["profile", "list"]
        case removeOperation:
            let usage = "Usage: profile remove <identifier> [--type configuration|provisioning]"
            guard (1...2).contains(operands.count) else { throw CommandFailure.usage(usage) }
            let identifier = operands[0]
            guard (1...255).contains(identifier.utf8.count), !identifier.hasPrefix("-"),
                  !identifier.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw CommandFailure.usage("A profile identifier is 1...255 bytes, without spaces or a leading '-'. \(usage)")
            }
            var words = ["profile", "remove", identifier]
            if operands.count == 2 {
                guard types.contains(operands[1]) else { throw CommandFailure.usage(usage) }
                words += ["--type", operands[1]]
            }
            return words
        default:
            return nil
        }
    }
}
