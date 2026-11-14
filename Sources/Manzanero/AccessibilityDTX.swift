import Foundation

/// Bounded DTX framing for Apple's remote AX service. Decoding preserves archive
/// bytes; it never instantiates classes named by device-supplied keyed archives.
struct AccessibilityDTX: Sendable {
    static let maximumBody = 16 * 1024 * 1024
    static let maximumFragments = 64
    // DTX DATA (1) is not an archived OBJECT reply (3). Keep unsupported
    // types rejected rather than interpreting their bytes as keyed archives.
    enum Kind: UInt32, Sendable { case acknowledgement = 0, invocation = 2, object = 3, error = 4 }

    let identifier: UInt32
    let conversation: UInt32
    let channel: Int32
    let expectsReply: Bool
    let kind: Kind
    let auxiliary: Data
    let object: Data

    private struct Header: Equatable {
        let fragment: Int
        let count: Int
        let length: Int
        let identifier: UInt32
        let conversation: UInt32
        let channel: Int32
        let expectsReply: Bool
    }

    private static func header(_ bytes: Data) throws -> Header {
        guard bytes.count == 32, integer(bytes, 0, UInt32.self) == 0x1f3d5b79,
              integer(bytes, 4, UInt32.self) == 32 else { throw invalid("header magic or size") }
        let index = Int(integer(bytes, 8, UInt16.self)), count = Int(integer(bytes, 10, UInt16.self))
        let length = Int(integer(bytes, 12, UInt32.self)), reply = integer(bytes, 28, UInt32.self)
        guard (1...maximumFragments).contains(count), index < count,
              (index == 0 ? length >= 16 : length > 0), length <= maximumBody, reply <= 1 else {
            throw invalid("fragment bounds or reply flags")
        }
        return Header(fragment: index, count: count, length: length,
            identifier: integer(bytes, 16, UInt32.self), conversation: integer(bytes, 20, UInt32.self),
            channel: integer(bytes, 24, Int32.self), expectsReply: reply == 1)
    }

    /// The transport must return exactly the requested count or throw. Header
    /// bounds are checked before asking it to allocate/read a body.
    static func read(exactly: (Int) throws -> Data) throws -> Self {
        let first = try header(exactly(32))
        guard first.fragment == 0 else { throw invalid("first fragment index") }
        var body = Data()
        if first.count == 1 {
            body = try exactly(first.length)
        } else {
            // Fragment zero is a declaration of the combined size, with no body.
            for index in 1..<first.count {
                let next = try header(exactly(32))
                guard next.fragment == index, next.count == first.count,
                      next.identifier == first.identifier, next.conversation == first.conversation,
                      next.channel == first.channel, next.expectsReply == first.expectsReply,
                      next.length <= first.length - body.count else { throw invalid("fragment correlation or length") }
                let bytes = try exactly(next.length)
                guard bytes.count == next.length else { throw invalid("short fragment body") }
                body.append(bytes)
            }
        }
        guard body.count == first.length else { throw invalid("combined body length") }
        let flags = integer(body, 0, UInt32.self)
        let auxiliarySize = Int(integer(body, 4, UInt32.self))
        let total = integer(body, 8, UInt64.self)
        guard let kind = Kind(rawValue: flags), total == UInt64(body.count - 16),
              auxiliarySize <= body.count - 16 else { throw invalid("payload flags or lengths") }
        let split = 16 + auxiliarySize
        guard kind != .acknowledgement || (auxiliarySize == 0 && split == body.count) else {
            throw invalid("nonempty acknowledgement")
        }
        return Self(identifier: first.identifier, conversation: first.conversation, channel: first.channel,
            expectsReply: first.expectsReply, kind: kind, auxiliary: Data(body[16..<split]), object: Data(body[split...]))
    }

    /// Incremental consumers can retain an incomplete prefix without treating
    /// malformed complete headers as incomplete or reading past one message.
    static func decodePrefix(_ bytes: Data) throws -> (message: Self, consumed: Int)? {
        enum Incomplete: Error { case prefix }
        var offset = 0
        do {
            let message = try read { count in
                guard count <= bytes.count - offset else { throw Incomplete.prefix }
                defer { offset += count }
                return Data(bytes[offset..<(offset + count)])
            }
            return (message, offset)
        } catch Incomplete.prefix { return nil }
    }

    func encoded() throws -> Data {
        guard auxiliary.count <= Self.maximumBody - 16,
              object.count <= Self.maximumBody - 16 - auxiliary.count,
              kind != .acknowledgement || (auxiliary.isEmpty && object.isEmpty) else {
            throw Self.invalid("outgoing body bounds or acknowledgement")
        }
        var bytes = Data()
        Self.append(UInt32(0x1f3d5b79), to: &bytes)
        Self.append(UInt32(32), to: &bytes)
        Self.append(UInt16(0), to: &bytes)
        Self.append(UInt16(1), to: &bytes)
        Self.append(UInt32(16 + auxiliary.count + object.count), to: &bytes)
        Self.append(identifier, to: &bytes)
        Self.append(conversation, to: &bytes)
        Self.append(channel, to: &bytes)
        Self.append(UInt32(expectsReply ? 1 : 0), to: &bytes)
        Self.append(kind.rawValue, to: &bytes)
        Self.append(UInt32(auxiliary.count), to: &bytes)
        Self.append(UInt64(auxiliary.count + object.count), to: &bytes)
        bytes.append(auxiliary)
        bytes.append(object)
        return bytes
    }

    func reply(object: Data = Data()) throws -> Self {
        let (next, overflow) = conversation.addingReportingOverflow(1)
        guard expectsReply, !overflow, next.isMultiple(of: 2) || channel != .min else {
            throw Self.invalid("invalid reply conversation/channel")
        }
        return Self(identifier: identifier, conversation: next,
            channel: next.isMultiple(of: 2) ? channel : -channel, expectsReply: false,
            kind: object.isEmpty ? .acknowledgement : .object, auxiliary: Data(), object: object)
    }

    /// Correlation only: an error reply also belongs to the request. Callers
    /// must inspect kind before interpreting the object as a successful result.
    func isReply(to request: Self) -> Bool {
        guard let expected = try? request.reply(), !expectsReply, kind != .invocation else { return false }
        return identifier == expected.identifier && conversation == expected.conversation && channel == expected.channel
    }

    static func invocation(_ selector: String, argument: NSObject?, identifier: UInt32,
                           expectsReply: Bool = true) throws -> Self {
        guard (1...4096).contains(selector.utf8.count), !selector.contains("\0") else { throw invalid("selector bounds") }
        let object = try NSKeyedArchiver.archivedData(withRootObject: selector as NSString, requiringSecureCoding: true)
        var auxiliary = Data()
        if let argument {
            let archive = try NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: true)
            guard archive.count <= maximumBody - 4096 else { throw invalid("argument bounds") }
            append(UInt64(0x1f0), to: &auxiliary)
            append(UInt64(12 + archive.count), to: &auxiliary)
            append(UInt32(10), to: &auxiliary)
            append(UInt32(2), to: &auxiliary)
            append(UInt32(archive.count), to: &auxiliary)
            auxiliary.append(archive)
        }
        return Self(identifier: identifier, conversation: 0, channel: 0, expectsReply: expectsReply,
            kind: .invocation, auxiliary: auxiliary, object: object)
    }

    /// One archived argument, still opaque. Semantic decoding is a separate
    /// bounded, data-only step; this is not a normalized accessibility tree.
    func archiveArgument() throws -> Data {
        guard auxiliary.count >= 28 else { throw Self.invalid("argument framing (auxiliaryBytes=\(auxiliary.count), minimum=28)") }
        // Upper header metadata varies with the sender's primitive buffer.
        // Recognize only the low-byte tag; never allocate or infer payload size
        // from that metadata. Declared size, argument types and length stay exact.
        guard Self.integer(auxiliary, 0, UInt64.self) & 0xff == 0xf0,
              Self.integer(auxiliary, 8, UInt64.self) == UInt64(auxiliary.count - 16),
              Self.integer(auxiliary, 16, UInt32.self) == 10,
              Self.integer(auxiliary, 20, UInt32.self) == 2,
              Self.integer(auxiliary, 24, UInt32.self) == UInt32(auxiliary.count - 28) else {
            // Header scalars only; never include an archive, token or UI text.
            throw Self.invalid("argument framing (tagWord=0x\(String(Self.integer(auxiliary, 0, UInt64.self), radix: 16)), declared=\(Self.integer(auxiliary, 8, UInt64.self)), auxiliaryBytes=\(auxiliary.count), keyType=\(Self.integer(auxiliary, 16, UInt32.self)), valueType=\(Self.integer(auxiliary, 20, UInt32.self)), archiveBytes=\(Self.integer(auxiliary, 24, UInt32.self)))")
        }
        return Data(auxiliary[28...])
    }

    private static func integer<T: FixedWidthInteger>(_ bytes: Data, _ offset: Int, _ type: T.Type) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: type)) }
    }

    private static func append<T: FixedWidthInteger>(_ number: T, to bytes: inout Data) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }

    private static func invalid(_ detail: String) -> CommandFailure {
        CommandFailure(description: "Invalid accessibility DTX \(detail).")
    }
}
