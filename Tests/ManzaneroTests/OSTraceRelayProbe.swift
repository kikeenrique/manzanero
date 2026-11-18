import Darwin
import Foundation
import Testing
@testable import Manzanero

/// Opt-in experiment (docs/app-logs-research.md, Q6): does the phone's log
/// relay answer over Apple's native tunnel, and can it be opened again after
/// its socket is closed? Read-only on the device: it starts a log stream for
/// one process and reads a bounded number of records. Not a command.
///
/// The framing follows the idevice reference (MIT; `os_trace_relay.rs` and
/// `rsd_checkin` in `lib.rs`): plists behind a 4-byte big-endian length for
/// the check-in and the start request, then records behind a 0x02 byte and a
/// 4-byte little-endian length.
struct OSTraceRelayProbeTests {
    static let service = "com.apple.os_trace_relay.shim.remote"
    static let maximumPlistBytes = 1024 * 1024
    static let maximumRecordBytes = 1024 * 1024
    static let headerBytes = 129

    struct Stream {
        let descriptor: Int32
        let deadline: ContinuousClock.Instant

        func read(_ count: Int) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
            while data.count < count {
                let left = deadline - ContinuousClock.now
                guard left > .zero else { throw CommandFailure(.timeout, "Log relay read deadline passed.", inputSent: .none) }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(min(100, max(1, left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000)))
                let ready = poll(&event, 1, milliseconds)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let got = Darwin.read(descriptor, &buffer, min(buffer.count, count - data.count))
                if got < 0, errno == EINTR || errno == EAGAIN { continue }
                guard got > 0 else { throw CommandFailure(.transportFailed, "Log relay closed the socket.", inputSent: .none) }
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
            guard (1...OSTraceRelayProbeTests.maximumPlistBytes).contains(length) else {
                throw CommandFailure(.transportFailed, "Log relay plist length \(length) is out of bounds.", inputSent: .none)
            }
            guard let value = try PropertyListSerialization.propertyList(from: read(length), format: nil) as? [String: Any] else {
                throw CommandFailure(.transportFailed, "Log relay reply is not a dictionary.", inputSent: .none)
            }
            return value
        }
    }

    struct Record {
        let pid: UInt32
        let level: UInt8
        let seconds: UInt32
        let process: String
        let image: String
        let message: String
        let subsystem: String
        let category: String
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
        let pid = u32(9), seconds = u32(55), level = bytes[68]
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
        let subsystem = subsystemSize > 0 && categorySize > 0 ? try take(subsystemSize, "subsystem") : ""
        let category = subsystemSize > 0 && categorySize > 0 ? try take(categorySize, "category") : ""
        return Record(pid: pid, level: level, seconds: seconds, process: process, image: image,
                      message: message, subsystem: subsystem, category: category)
    }

    /// Check-in, start a stream for `pid`, read at most `limit` records
    /// within `seconds`, close. Returns what was seen.
    static func stream(_ directory: RSDDirectoryConnection, pid: Int32, limit: Int, seconds: Int) throws -> [String: Any] {
        let descriptor = try directory.openShimService(service)
        defer { Darwin.close(descriptor) }
        var result: [String: Any] = ["socketOpened": true]
        let setup = Stream(descriptor: descriptor, deadline: .now + .seconds(8))
        try setup.send(["Label": "manzanero", "ProtocolVersion": "2", "Request": "RSDCheckin"], format: .xml)
        let checkin = try setup.plist(), started = try setup.plist()
        result["checkin"] = checkin["Request"] as? String ?? "?"
        result["startService"] = started["Request"] as? String ?? "?"
        guard checkin["Request"] as? String == "RSDCheckin", started["Request"] as? String == "StartService" else {
            result["checkinKeys"] = checkin.keys.sorted(); result["startServiceKeys"] = started.keys.sorted()
            result["error"] = started["Error"] ?? checkin["Error"] ?? "unexpected check-in replies"
            return result
        }
        try setup.send(["Request": "StartActivity", "Pid": Int(pid), "MessageFilter": 65535, "StreamFlags": 60], format: .binary)
        result["leadingByte"] = Int(try setup.read(1)[0])
        let status = try setup.plist()
        result["startActivity"] = status["Status"] as? String ?? "?"
        guard status["Status"] as? String == "RequestSuccessful" else {
            result["startActivityKeys"] = status.keys.sorted()
            return result
        }
        let reading = Stream(descriptor: descriptor, deadline: .now + .seconds(seconds))
        var records: [Record] = [], bytes = 0, parseFailures: [String] = []
        let begun = ContinuousClock.now
        do {
            while records.count + parseFailures.count < limit {
                let marker = try reading.read(1)[0]
                guard marker == 0x02 else { throw CommandFailure(.transportFailed, "Log relay record marker was \(marker), not 2.", inputSent: .none) }
                let length = try reading.read(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                guard (1...maximumRecordBytes).contains(length) else {
                    throw CommandFailure(.transportFailed, "Log relay record length \(length) is out of bounds.", inputSent: .none)
                }
                let packet = try reading.read(length)
                bytes += 5 + length
                do { records.append(try parse(packet)) } catch { parseFailures.append(String(describing: error)) }
            }
            result["stoppedBy"] = "record limit"
        } catch let failure as CommandFailure where failure.code == .timeout {
            result["stoppedBy"] = "deadline"
        }
        let elapsed = begun.duration(to: .now)
        result["elapsedMilliseconds"] = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        result["records"] = records.count
        result["bytes"] = bytes
        result["parseFailures"] = parseFailures
        result["levels"] = Dictionary(grouping: records, by: { String($0.level) }).mapValues(\.count)
        result["pids"] = Array(Set(records.map { Int($0.pid) })).sorted()
        // Records per subsystem, and the levels seen in each: the question
        // is whether an app's own debug-level lines arrive.
        result["subsystems"] = Dictionary(grouping: records, by: { $0.subsystem.isEmpty ? "(none)" : $0.subsystem }).mapValues { group in
            ["records": group.count, "levels": Dictionary(grouping: group, by: { String($0.level) }).mapValues(\.count)] as [String: Any]
        }
        result["processes"] = Array(Set(records.map(\.process))).sorted()
        // A sample, for a person to judge the decoding; kept under tmp/ only.
        result["sample"] = records.prefix(8).map {
            ["pid": Int($0.pid), "level": Int($0.level), "seconds": Int($0.seconds), "image": $0.image,
             "subsystem": $0.subsystem, "category": $0.category, "message": String($0.message.prefix(160))] as [String: Any]
        }
        return result
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANZANERO_OS_TRACE_DEVICE"] != nil))
    func liveRelayStreamsBoundedRecordsAndReopens() async throws {
        let device = try #require(ProcessInfo.processInfo.environment["MANZANERO_OS_TRACE_DEVICE"])
        let pid = try #require(Int32(ProcessInfo.processInfo.environment["MANZANERO_OS_TRACE_PID"] ?? ""))
        try #require(pid > 0)
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/os-trace-relay/run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata: [String: Any] = ["device": device, "pid": Int(pid), "stage": "identity", "service": Self.service]
        var assertion: NativeTunnelAssertion?
        var directory: RSDDirectoryConnection?
        func finish() throws {
            directory?.close()
            if let release = assertion?.close() { metadata["assertionRelease"] = release.status; metadata["assertionReleaseConfirmed"] = release.confirmed }
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("result.json"))
        }
        do {
            let plan = try CoreDeviceInput(device: device, operation: "tree", operands: []).identityPlan()
            let details = try ToolRunner().run(plan.arguments, executable: plan.executable, timeout: 20)
            let address = try RSDPortDiscovery.tunnelAddress(details: details, expectedUDID: device)
            metadata["stage"] = "assertion"
            assertion = try NativeTunnelAssertion(device: device, details: details)
            let seconds = Int(ProcessInfo.processInfo.environment["MANZANERO_OS_TRACE_SECONDS"] ?? "") ?? 5
            let limit = Int(ProcessInfo.processInfo.environment["MANZANERO_OS_TRACE_LIMIT"] ?? "") ?? 50
            try #require((1...60).contains(seconds) && (1...5000).contains(limit))
            // Each stream gets a directory of its own: the first one was no
            // longer usable five seconds after its handshake.
            func open(_ stage: String) async throws -> RSDDirectoryConnection {
                metadata["stage"] = "\(stage)-port-discovery"
                let port = try await RSDPortDiscovery.discover(tunnelAddress: address)
                metadata["stage"] = "\(stage)-directory-handshake"
                let opened = try RSDDirectoryConnection(tunnelAddress: address, port: port, expectedUDID: device)
                directory = opened
                return opened
            }
            let opened = try await open("first")
            metadata["stage"] = "first-stream"
            let first = try Self.stream(opened, pid: pid, limit: limit, seconds: seconds)
            metadata["first"] = first
            metadata["directoryActiveAfterFirstStream"] = opened.isActive
            opened.close()
            let reopened = try await open("second")
            metadata["stage"] = "second-stream"
            let second = try Self.stream(reopened, pid: pid, limit: 5, seconds: 3)
            metadata["second"] = second
            metadata["stage"] = "done"
            metadata["outcome"] = "completed"
            try finish()
            #expect(first["startActivity"] as? String == "RequestSuccessful")
            #expect(second["startActivity"] as? String == "RequestSuccessful")
        } catch {
            metadata["outcome"] = "failed"
            metadata["error"] = String(describing: error)
            try? finish()
            throw error
        }
    }

    /// The record layout, checked without a device: a packet built field by
    /// field at the reference's offsets parses back.
    @Test func aRecordBuiltAtTheReferenceOffsetsParses() throws {
        func cString(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
        let image = cString("Preferences"), message = cString("hola ñ"), subsystem = cString("com.example"), category = cString("ui")
        var packet = [UInt8](repeating: 0, count: Self.headerBytes)
        func put(_ value: UInt32, at offset: Int, bytes: Int = 4) { for index in 0..<bytes { packet[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) } }
        put(3619, at: 9); put(1_794_960_000, at: 55); packet[68] = 2
        put(UInt32(image.count), at: 107, bytes: 2); put(UInt32(message.count), at: 109, bytes: 2)
        put(UInt32(subsystem.count), at: 117); put(UInt32(category.count), at: 121)
        packet += cString("/Applications/Preferences.app/Preferences") + image + message + subsystem + category
        let record = try Self.parse(Data(packet))
        #expect(record.pid == 3619 && record.level == 2 && record.seconds == 1_794_960_000)
        #expect(record.process == "/Applications/Preferences.app/Preferences" && record.image == "Preferences")
        #expect(record.message == "hola ñ" && record.subsystem == "com.example" && record.category == "ui")
        #expect(throws: CommandFailure.self) { try Self.parse(Data(packet.prefix(100))) }
        #expect(throws: CommandFailure.self) { try Self.parse(Data(packet.dropLast(4))) }
    }
}
