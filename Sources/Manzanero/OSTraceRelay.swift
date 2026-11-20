import Darwin
import Foundation

/// The device's log relay, `com.apple.os_trace_relay.shim.remote`: a lockdown
/// shim service, a plain TCP socket with no TLS, behind the device's service
/// directory (docs/app-logs.md#physical-devices).
///
/// The framing follows the idevice reference (MIT; `os_trace_relay.rs` and
/// `rsd_checkin` in `lib.rs`, crediting pymobiledevice3): property lists
/// behind a 4-byte big-endian length for the check-in and the start request,
/// then records behind a 0x02 byte and a 4-byte little-endian length.
enum OSTraceRelay {
    static let service = "com.apple.os_trace_relay.shim.remote"
    static let maximumPlistBytes = 1024 * 1024
    /// A record's length comes from the wire; nothing longer is allocated.
    static let maximumRecordBytes = 1024 * 1024
    static let headerBytes = 129
    /// Every level; levels are filtered on the Mac.
    static let messageFilter = 65535
    static let streamFlags = 60

    /// A blocking socket read with a deadline and a way to stop it.
    struct Stream {
        let descriptor: Int32
        let deadline: ContinuousClock.Instant
        var cancelled: @Sendable () -> Bool = { false }

        func read(_ count: Int) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
            while data.count < count {
                if cancelled() { throw CancellationError() }
                let left = deadline - ContinuousClock.now
                guard left > .zero else { throw CommandFailure(.timeout, "Log relay read deadline passed.", inputSent: .none) }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(min(100, max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)))
                let ready = poll(&event, 1, milliseconds)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let got = Darwin.read(descriptor, &buffer, min(buffer.count, count - data.count))
                if got < 0, errno == EINTR || errno == EAGAIN { continue }
                guard got > 0 else { throw Closed() }
                data.append(contentsOf: buffer[0..<got])
            }
            return data
        }

        func write(_ data: Data) throws {
            var sent = 0
            try data.withUnsafeBytes { bytes in
                while sent < data.count {
                    let wrote = Darwin.write(descriptor, bytes.baseAddress! + sent, data.count - sent)
                    if wrote < 0, errno == EINTR { continue }
                    guard wrote > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    sent += wrote
                }
            }
        }

        func send(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat) throws {
            let body = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            var length = UInt32(body.count).bigEndian
            try write(Data(bytes: &length, count: 4) + body)
        }

        func plist() throws -> [String: Any] {
            let length = try read(4).reduce(0) { $0 << 8 | Int($1) }
            guard (1...OSTraceRelay.maximumPlistBytes).contains(length) else {
                throw CommandFailure(.transportFailed, "Log relay plist length \(length) is out of bounds.", inputSent: .none)
            }
            guard let value = try PropertyListSerialization.propertyList(from: read(length), format: nil) as? [String: Any] else {
                throw CommandFailure(.transportFailed, "Log relay reply is not a dictionary.", inputSent: .none)
            }
            return value
        }

        /// One record's bytes, after its 0x02 marker and length.
        func packet() throws -> Data {
            let marker = try read(1)[0]
            guard marker == 0x02 else { throw CommandFailure(.transportFailed, "Log relay record marker was \(marker), not 2.", inputSent: .none) }
            let length = try read(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard (1...OSTraceRelay.maximumRecordBytes).contains(length) else {
                throw CommandFailure(.transportFailed, "Log relay record length \(length) is out of bounds.", inputSent: .none)
            }
            return try read(length)
        }
    }

    /// The device closed the socket.
    struct Closed: Error, CustomStringConvertible {
        var description: String { "Log relay closed the socket." }
    }

    struct Record: Equatable {
        let pid: UInt32
        let level: UInt8
        let seconds: UInt32
        let microseconds: UInt32
        let process: String
        let image: String
        let message: String
        let subsystem: String
        let category: String

        /// The level's name, in the words simulator `logs` uses.
        var levelName: String {
            switch level {
            case 0: "default"
            case 1: "info"
            case 2: "debug"
            case 0x10: "error"
            case 0x11: "fault"
            default: "unknown-\(level)"
            }
        }

        var timestamp: String {
            DiagnosticTime.iso8601(Date(timeIntervalSince1970: TimeInterval(seconds)), fraction: String(format: "%06u", min(microseconds, 999_999)))
        }
    }

    /// One record after its 0x02 byte and length. Offsets as in the reference.
    static func parse(_ packet: Data) throws -> Record {
        let bytes = [UInt8](packet)
        func invalid(_ what: String) -> CommandFailure { CommandFailure(.transportFailed, "Log record: \(what).", inputSent: .none) }
        guard bytes.count >= headerBytes else { throw invalid("shorter than the fixed header (\(bytes.count) bytes)") }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
        // 9 padding, pid 4, 42 (procid, image UUID), seconds 4, 4 padding,
        // microseconds 4, 1 padding, level 1, 38 (mach time, thread, sender
        // UUID), image-name size 2, message size 2, 2, sender offset 4,
        // subsystem size 4, category size 4, 4.
        let pid = u32(9), seconds = u32(55), microseconds = u32(63), level = bytes[68]
        let imageSize = u16(107), messageSize = u16(109)
        let subsystemSize = Int(u32(117)), categorySize = Int(u32(121))
        var offset = headerBytes
        guard let end = bytes[offset...].firstIndex(of: 0) else { throw invalid("process path is not terminated") }
        let process = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        func take(_ size: Int, _ what: String) throws -> String {
            guard size >= 0, offset + size <= bytes.count else { throw invalid("\(what) runs past the record") }
            defer { offset += size }
            return String(decoding: bytes[offset..<(offset + max(size - 1, 0))], as: UTF8.self)
        }
        let image = try take(imageSize, "image name")
        let message = try take(messageSize, "message")
        // A record without a subsystem can still carry non-zero sizes there
        // (seen from locationd on 2026-11-20); it ends after the message.
        let labelled = subsystemSize > 0 && categorySize > 0 && offset < bytes.count
        let subsystem = labelled ? try take(subsystemSize, "subsystem") : ""
        let category = labelled ? try take(categorySize, "category") : ""
        return Record(pid: pid, level: level, seconds: seconds, microseconds: microseconds, process: process, image: image,
                      message: message, subsystem: subsystem, category: category)
    }

    /// The check-in every fresh socket to the service starts with.
    static func checkIn(_ stream: Stream) throws {
        try stream.send(["Label": "manzanero", "ProtocolVersion": "2", "Request": "RSDCheckin"], format: .xml)
        let checkin = try stream.plist(), started = try stream.plist()
        guard checkin["Request"] as? String == "RSDCheckin", started["Request"] as? String == "StartService" else {
            let error = started["Error"] ?? checkin["Error"] ?? "unexpected check-in replies"
            throw CommandFailure(.transportFailed, "The log relay refused the check-in: \(error).", inputSent: .none)
        }
    }

    /// The PIDs the device lists as running (`PidList`), on a socket that
    /// has checked in: the reply is one byte, then `{Payload: {"<pid>": …}}`.
    static func pidList(_ stream: Stream) throws -> Set<Int32> {
        try stream.send(["Request": "PidList"], format: .binary)
        _ = try stream.read(1)
        guard let payload = try stream.plist()["Payload"] as? [String: Any] else {
            throw CommandFailure(.transportFailed, "The log relay's process list has no Payload.", inputSent: .none)
        }
        return Set(payload.keys.compactMap { Int32($0) })
    }

    /// Check-in and a stream for one process (`pid`), or every process
    /// (`-1`), on a fresh socket to the service. Throws unless the device
    /// answers `RequestSuccessful`.
    static func start(_ stream: Stream, pid: Int32) throws {
        try checkIn(stream)
        try stream.send(["Request": "StartActivity", "Pid": Int(pid), "MessageFilter": messageFilter, "StreamFlags": streamFlags], format: .binary)
        _ = try stream.read(1)
        let status = try stream.plist()
        guard status["Status"] as? String == "RequestSuccessful" else {
            throw CommandFailure(.transportFailed, "The log relay refused the stream: \(status["Status"] ?? status.keys.sorted()).", inputSent: .none)
        }
    }
}
