import Foundation

/// The small encodings of Apple's remote pairing
/// (docs/transport.md#a-pairing-of-the-tools-own): TLV8 items inside each
/// pairing message, OPACK for the host's description, and the `RPPairing`
/// frame that carries one JSON message. Written from the protocol as the
/// reference project describes it (github.com/jkcoxson/idevice, MIT).
enum PairingTLV {
    enum Kind: UInt8 {
        case method = 0x00, identifier = 0x01, salt = 0x02, publicKey = 0x03, proof = 0x04
        case encryptedData = 0x05, state = 0x06, error = 0x07, signature = 0x0a, info = 0x11
    }

    struct Item: Equatable {
        let kind: UInt8
        var data: [UInt8]
        init(_ kind: Kind, _ data: [UInt8]) { self.kind = kind.rawValue; self.data = data }
        init(kind: UInt8, data: [UInt8]) { self.kind = kind; self.data = data }
    }

    /// A value longer than 255 bytes goes as consecutive items of its kind.
    static func encode(_ items: [Item]) -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            var rest = item.data[...]
            repeat {
                let chunk = rest.prefix(255)
                out += [item.kind, UInt8(chunk.count)] + chunk
                rest = rest.dropFirst(chunk.count)
            } while !rest.isEmpty
        }
        return out
    }

    /// Items in order, consecutive ones of a kind joined; nil when a length
    /// runs past the end.
    static func decode(_ bytes: [UInt8]) -> [Item]? {
        var items: [Item] = [], index = 0
        while index < bytes.count {
            guard index + 2 <= bytes.count, index + 2 + Int(bytes[index + 1]) <= bytes.count else { return nil }
            let kind = bytes[index], length = Int(bytes[index + 1])
            let data = Array(bytes[(index + 2)..<(index + 2 + length)])
            // A full item is continued by the next of its kind.
            if let last = items.last, last.kind == kind, last.data.count % 255 == 0, !last.data.isEmpty {
                items[items.count - 1].data += data
            } else {
                items.append(Item(kind: kind, data: data))
            }
            index += 2 + length
        }
        return items
    }

    static func value(_ kind: Kind, in items: [Item]) -> [UInt8]? { items.first { $0.kind == kind.rawValue }?.data }
}

/// OPACK, only as far as the host's description needs it: a dictionary of
/// at most fourteen entries whose values are strings or data.
enum PairingOPACK {
    enum Value: Equatable { case string(String), data([UInt8]) }

    private static func header(_ count: Int, short: UInt8, long: UInt8) -> [UInt8] {
        if count <= 0x20 { return [short + UInt8(count)] }
        if count <= 0xFF { return [long + 1, UInt8(count)] }
        return [long + 2, UInt8(count & 0xFF), UInt8(count >> 8)]
    }

    static func encode(_ entries: [(key: String, value: Value)]) -> [UInt8] {
        precondition(entries.count < 15 && entries.allSatisfy { $0.key.utf8.count <= 0xFFFF }, "OPACK dictionary out of this encoder's range")
        var out: [UInt8] = [0xE0 + UInt8(entries.count)]
        for entry in entries {
            out += header(entry.key.utf8.count, short: 0x40, long: 0x60) + Array(entry.key.utf8)
            switch entry.value {
            case .string(let text): out += header(text.utf8.count, short: 0x40, long: 0x60) + Array(text.utf8)
            case .data(let bytes): out += header(bytes.count, short: 0x70, long: 0x90) + bytes
            }
        }
        return out
    }
}

/// One message on the pairing connection: `RPPairing`, a 16-bit length, and
/// JSON.
enum PairingFrame {
    static let magic = Array("RPPairing".utf8)
    static let maximumLength = Int(UInt16.max)

    static func encode(_ message: [String: Any]) throws -> [UInt8] {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= maximumLength else {
            throw CommandFailure(.internal, "A pairing message is longer than its frame allows.", inputSent: .none)
        }
        return magic + [UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    /// The envelope every message travels in.
    static func envelope(plain value: [String: Any], sequence: Int) -> [String: Any] {
        ["message": ["plain": ["_0": value]], "originatedBy": "host", "sequenceNumber": sequence]
    }

    static func envelope(encrypted ciphertext: [UInt8], sequence: Int) -> [String: Any] {
        ["message": ["streamEncrypted": ["_0": Data(ciphertext).base64EncodedString()]], "originatedBy": "host", "sequenceNumber": sequence]
    }

    /// Reads one frame with `read`, which returns exactly the bytes asked for.
    static func decode(read: (Int) throws -> [UInt8]) throws -> [String: Any] {
        guard try read(magic.count) == magic else {
            throw CommandFailure(.transportFailed, "The device's pairing service answered with something that is not a pairing message.", inputSent: .none)
        }
        let length = try read(2)
        let body = try read(Int(length[0]) << 8 | Int(length[1]))
        guard let message = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            throw CommandFailure(.transportFailed, "The device's pairing message is not a JSON object.", inputSent: .none)
        }
        return message
    }
}
