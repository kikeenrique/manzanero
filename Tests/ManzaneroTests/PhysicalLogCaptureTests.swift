import Darwin
import Foundation
import Testing
@testable import Manzanero

struct PhysicalLogCaptureTests {
    /// A record packet at the reference's offsets (after its marker and length).
    static func packet(pid: UInt32 = 3619, level: UInt8 = 0, seconds: UInt32 = 1_794_960_000, microseconds: UInt32 = 42,
                       process: String = "/private/var/containers/Bundle/Application/X/Probe.app/Probe",
                       image: String = "Probe", message: String = "hola ñ", subsystem: String = "com.example.probe",
                       category: String = "ui") -> Data {
        func cString(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
        let imageBytes = cString(image), messageBytes = cString(message)
        let subsystemBytes = subsystem.isEmpty ? [] : cString(subsystem), categoryBytes = category.isEmpty ? [] : cString(category)
        var bytes = [UInt8](repeating: 0, count: OSTraceRelay.headerBytes)
        func put(_ value: UInt32, at offset: Int, size: Int = 4) { for index in 0..<size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) } }
        put(pid, at: 9); put(seconds, at: 55); put(microseconds, at: 63); bytes[68] = level
        put(UInt32(imageBytes.count), at: 107, size: 2); put(UInt32(messageBytes.count), at: 109, size: 2)
        put(UInt32(subsystemBytes.count), at: 117); put(UInt32(categoryBytes.count), at: 121)
        bytes += cString(process) + imageBytes + messageBytes + subsystemBytes + categoryBytes
        return Data(bytes)
    }

    static func capture(_ arguments: [String]) throws -> LogCapture {
        var values: [String: String?] = [:]
        var index = 0
        while index + 1 < arguments.count { values[arguments[index]] = arguments[index + 1]; index += 2 }
        return try LogCapture(device: "fixture", options: DiagnosticOptions(values: values), physical: true)
    }

    @Test func aRecordKeepsItsMicrosecondsAndLevelName() throws {
        let record = try OSTraceRelay.parse(Self.packet(level: 0x11, microseconds: 7))
        #expect(record.levelName == "fault" && record.timestamp == "2026-11-18T00:00:00.000007Z")
        #expect(try OSTraceRelay.parse(Self.packet(level: 2)).levelName == "debug")
    }

    // MARK: Resolution

    static let apps = Data(#"""
    {"result":{"apps":[{"bundleIdentifier":"com.example.probe","url":"file:///private/var/containers/Bundle/Application/X/Probe.app/"},
    {"bundleIdentifier":"com.example.other","url":"file:///private/var/containers/Bundle/Application/Y/Other.app/"}]}}
    """#.utf8)

    static func processes(_ entries: [(Int, String)]) -> Data {
        let list = entries.map { ["processIdentifier": $0.0, "executable": "file://" + $0.1] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["result": ["runningProcesses": list]])
    }

    @Test func aBundleIsItsMainExecutableAndNotAnExtension() throws {
        let running = Self.processes([(10, "/private/var/containers/Bundle/Application/X/Probe.app/PlugIns/Widget.appex/Widget"),
                                      (11, "/private/var/containers/Bundle/Application/X/Probe.app/Probe"),
                                      (12, "/usr/libexec/backboardd")])
        let resolved = try PhysicalLogCapture.resolve(.bundle("com.example.probe"), apps: { Self.apps }, processes: { running })
        #expect(resolved.pid == 11 && resolved.executable == "/private/var/containers/Bundle/Application/X/Probe.app/Probe")
    }

    @Test func aBundleNotRunningNotInstalledOrTwiceRunningIsRefused() throws {
        let none = Self.processes([(12, "/usr/libexec/backboardd")])
        for (target, running) in [(LogCapture.Target.bundle("com.example.probe"), none), (.bundle("com.example.absent"), none),
                                  (.process("backboardd"), Self.processes([(12, "/usr/libexec/backboardd"), (13, "/usr/sbin/backboardd")])),
                                  (.process("Probe"), none)] {
            let failure = #expect(throws: CommandFailure.self) { try PhysicalLogCapture.resolve(target, apps: { Self.apps }, processes: { running }) }
            #expect(failure?.code == .targetUnresolved && failure?.inputSent == CommandFailure.InputSent.none)
        }
        #expect(try PhysicalLogCapture.resolve(.process("backboardd"), apps: { Data() }, processes: { none }).pid == 12)
    }

    @Test func aPIDNeedsNoQuery() throws {
        let resolved = try PhysicalLogCapture.resolve(.pid(42), apps: { Issue.record("apps"); return Data() },
                                                      processes: { Issue.record("processes"); return Data() })
        #expect(resolved == .init(pid: 42, executable: nil))
    }

    // MARK: Filtering and bounds

    @Test func levelsSubsystemAndAnotherPIDAreFilteredOnTheMac() throws {
        var reader = PhysicalLogReader(capture: try Self.capture(["--seconds", "5", "--pid", "3619", "--level", "info", "--subsystem", "com.example.probe"]),
                                       pid: 3619, receivedBytesCeiling: 1 << 20)
        var kept: [Bool] = []
        for level: UInt8 in [0, 1, 2, 0x10, 0x11] { kept.append(reader.feed(Self.packet(level: level))) }
        kept.append(reader.feed(Self.packet(pid: 77)))
        kept.append(reader.feed(Self.packet(subsystem: "com.apple.UIKit")))
        kept.append(reader.feed(Data([1, 2, 3])))
        #expect(kept.allSatisfy { $0 })
        #expect(reader.entries.count == 4 && reader.filteredOut == 3 && reader.parseFailures == 1 && reader.receivedRecords == 8)
        let first = try #require(JSONSerialization.jsonObject(with: reader.entries[0]) as? [String: Any])
        #expect(first["process"] as? String == "Probe" && first["sender"] as? String == "Probe" && first["message"] as? String == "hola ñ")
        #expect(first["level"] as? String == "default" && first["pid"] as? Int == 3619 && first["category"] as? String == "ui")
    }

    @Test func entryByteAndReceivedLimitsStopTheCapture() throws {
        var byEntries = PhysicalLogReader(capture: try Self.capture(["--seconds", "5", "--pid", "1", "--max-entries", "2"]), pid: 1, receivedBytesCeiling: 1 << 20)
        let entries = [byEntries.feed(Self.packet(pid: 1)), byEntries.feed(Self.packet(pid: 1)), byEntries.feed(Self.packet(pid: 1))]
        #expect(entries == [true, true, false] && byEntries.stopReason == .entryLimit && byEntries.truncated)
        var byReceived = PhysicalLogReader(capture: try Self.capture(["--seconds", "5", "--pid", "1"]), pid: 1, receivedBytesCeiling: 300)
        let received = [byReceived.feed(Self.packet(pid: 2)), byReceived.feed(Self.packet(pid: 2))]
        #expect(received == [true, false] && byReceived.stopReason == .byteLimit)
    }

    // MARK: The stream, against a fake relay on a socket pair

    /// Plays the device's side: the check-in replies, the start status, the
    /// given records, then closes.
    static func fakeRelay(_ descriptor: Int32, records: [Data]) {
        func plist(_ value: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) -> Data {
            let body = try! PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
            var length = UInt32(body.count).bigEndian
            return Data(bytes: &length, count: 4) + body
        }
        let stream = OSTraceRelay.Stream(descriptor: descriptor, deadline: .now + .seconds(10))
        do {
            _ = try stream.plist()
            try stream.write(plist(["Request": "RSDCheckin"]) + plist(["Request": "StartService"]))
            let start = try stream.plist()
            guard start["Request"] as? String == "StartActivity" else { Darwin.close(descriptor); return }
            try stream.write(Data([1]) + plist(["Status": "RequestSuccessful"], .binary))
            for record in records {
                var length = UInt32(record.count).littleEndian
                try stream.write(Data([2]) + Data(bytes: &length, count: 4) + record)
            }
        } catch {}
        Darwin.close(descriptor)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamThatTheDeviceClosesReturnsWhatArrivedWithTheRoute() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let device = pair[1]
        let records = [Self.packet(pid: 5, level: 2), Self.packet(pid: 5, level: 0), Self.packet(pid: 6)]
        Thread.detachNewThread { Self.fakeRelay(device, records: records) }
        let closed = CancelFlag()
        let mine = pair[0]
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: ["serviceDirectory": "own-tunnel", "ownTunnelLink": "cable"],
                                                       close: { Darwin.close(mine); closed.value.store(true, ordering: .relaxed) })
        let capture = try Self.capture(["--seconds", "30", "--pid", "5"])
        let reader = try await PhysicalLogCapture.stream(connection, pid: 5, capture: capture)
        #expect(reader.stopReason == .closed && reader.entries.count == 1 && reader.filteredOut == 2)
        #expect(closed.isSet)
        let result = try #require(JSONSerialization.jsonObject(with: PhysicalLogCapture.result(capture, reader: reader,
            resolved: .init(pid: 5, executable: nil), route: connection.route)) as? [String: Any])
        #expect(result["stopReason"] as? String == "closed" && result["serviceDirectory"] as? String == "own-tunnel")
        #expect(result["source"] as? String == "os-trace-relay" && result["entryCount"] as? Int == 1 && result["pid"] as? Int == 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedStreamThrowsAndClosesTheSocket() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let device = pair[1]
        Thread.detachNewThread {
            let stream = OSTraceRelay.Stream(descriptor: device, deadline: .now + .seconds(10))
            _ = try? stream.plist()
            try? stream.send(["Request": "RSDCheckin"], format: .xml)
            try? stream.send(["Request": "Nope", "Error": "denied"], format: .xml)
            Darwin.close(device)
        }
        let closed = CancelFlag()
        let mine = pair[0]
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: [:],
                                                       close: { Darwin.close(mine); closed.value.store(true, ordering: .relaxed) })
        await #expect(throws: CommandFailure.self) {
            _ = try await PhysicalLogCapture.stream(connection, pid: 5, capture: try Self.capture(["--seconds", "5", "--pid", "5"]))
        }
        #expect(closed.isSet)
    }
}
