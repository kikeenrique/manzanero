import Foundation

/// A tree node's `handle`: the live element it was read from, as
/// `<pid>:<objectID in hex>` (`ax:412:7f9a…`). Selector actions take it with
/// `--handle` and act on that same element in a fresh snapshot, or refuse when
/// no node of the fresh snapshot has it (the element is gone or replaced).
struct ElementHandle: Sendable, Equatable, CustomStringConvertible {
    static let prefix = "ax:"
    let pid: Int32
    let objectID: UInt64

    var description: String { "\(Self.prefix)\(pid):\(String(objectID, radix: 16))" }

    init(pid: Int32, objectID: UInt64) {
        self.pid = pid
        self.objectID = objectID
    }

    init(_ text: String) throws {
        let parts = text.hasPrefix(Self.prefix) ? text.dropFirst(Self.prefix.count).split(separator: ":") : []
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, let objectID = UInt64(parts[1], radix: 16) else {
            throw CommandFailure.usage("A handle is a tree node's handle, ax:<pid>:<hex>; '\(text)' is not one.")
        }
        self.init(pid: pid, objectID: objectID)
    }

    func matches(_ token: AccessibilityRequest.Token) -> Bool { token.pid == pid && token.objectID == objectID }
}
