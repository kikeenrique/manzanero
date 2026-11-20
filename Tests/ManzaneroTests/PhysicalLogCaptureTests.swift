import Darwin
import Foundation
import Synchronization
import Testing
@testable import Manzanero

struct PhysicalLogCaptureTests {
    /// A record packet at the reference's offsets (after its marker and length).
    static func packet(pid: UInt32 = 3619, level: UInt8 = 0, seconds: UInt32 = 1_794_960_000, microseconds: UInt32 = 42,
                       process: String = "/private/var/containers/Bundle/Application/X/Probe.app/Probe",
                       image: String = "Probe", message: String = "hola ñ", subsystem: String = "com.example.probe",
                       category: String = "ui", labelSizes: (UInt32, UInt32)? = nil) -> Data {
        func cString(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
        let imageBytes = cString(image), messageBytes = cString(message)
        let subsystemBytes = subsystem.isEmpty ? [] : cString(subsystem), categoryBytes = category.isEmpty ? [] : cString(category)
        var bytes = [UInt8](repeating: 0, count: OSTraceRelay.headerBytes)
        func put(_ value: UInt32, at offset: Int, size: Int = 4) { for index in 0..<size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) } }
        put(pid, at: 9); put(seconds, at: 55); put(microseconds, at: 63); bytes[68] = level
        put(UInt32(imageBytes.count), at: 107, size: 2); put(UInt32(messageBytes.count), at: 109, size: 2)
        put(labelSizes?.0 ?? UInt32(subsystemBytes.count), at: 117); put(labelSizes?.1 ?? UInt32(categoryBytes.count), at: 121)
        bytes += cString(process) + imageBytes + messageBytes + subsystemBytes + categoryBytes
        return Data(bytes)
    }

    /// Options as the CLI gives them; a repeated option collects its values.
    static func capture(_ arguments: [String], flags: [String] = []) throws -> LogCapture {
        var values: [String: String?] = [:], lists: [String: [String]] = [:]
        var index = 0
        while index + 1 < arguments.count {
            if ["--bundle", "--process", "--subsystem", "--category"].contains(arguments[index]) {
                lists[arguments[index], default: []].append(arguments[index + 1])
            } else { values[arguments[index]] = arguments[index + 1] }
            index += 2
        }
        return try LogCapture(device: "fixture", options: DiagnosticOptions(values: values, flags: Dictionary(uniqueKeysWithValues: flags.map { ($0, true) }),
                                                                            lists: lists), physical: true)
    }

    @Test func aRecordKeepsItsMicrosecondsAndLevelName() throws {
        let record = try OSTraceRelay.parse(Self.packet(level: 0x11, microseconds: 7))
        #expect(record.levelName == "fault" && record.timestamp == "2026-11-18T00:00:00.000007Z")
        #expect(try OSTraceRelay.parse(Self.packet(level: 2)).levelName == "debug")
    }

    /// As seen from locationd on 2026-11-20: sizes in the subsystem fields
    /// and nothing after the message.
    @Test func aRecordThatEndsAfterItsMessageHasNoSubsystem() throws {
        let record = try OSTraceRelay.parse(Self.packet(subsystem: "", category: "", labelSizes: (0x9ba4_0000, 11)))
        #expect(record.subsystem == "" && record.category == "" && record.message == "hola ñ")
        // Bytes that are there but too few are still refused.
        var short = Self.packet(subsystem: "", category: "", labelSizes: (40, 11))
        short.append(contentsOf: [0x61, 0])
        #expect(throws: CommandFailure.self) { try OSTraceRelay.parse(short) }
    }

    @Test func theOptionsTakeOneAGroupOrAllAndRefuseMixtures() throws {
        #expect(try Self.capture(["--seconds", "600", "--pid", "1"]).targets == [.pid(1)])
        let group = try Self.capture(["--seconds", "5", "--bundle", "a.b", "--bundle", "c.d", "--process", "locationd"])
        #expect(group.targets == [.bundle("a.b"), .bundle("c.d"), .process("locationd")])
        #expect(try Self.capture(["--seconds", "5"], flags: ["--all"]).all)
        for invalid in [(["--seconds", "5"], [String]()), (["--seconds", "5", "--pid", "1"], ["--all"]),
                        (["--seconds", "5", "--pid", "1", "--bundle", "a.b"], []), (["--seconds", "601", "--pid", "1"], []),
                        (["--seconds", "5", "--category", "ui"], ["--all"]), (["--seconds", "5", "--match", "a\"b"], ["--all"])] {
            #expect(throws: CommandFailure.self) { try Self.capture(invalid.0, flags: invalid.1) }
        }
    }

    // MARK: Selection

    static let apps = Data(#"""
    {"result":{"apps":[{"bundleIdentifier":"com.example.probe","url":"file:///private/var/containers/Bundle/Application/X/Probe.app/"},
    {"bundleIdentifier":"com.example.other","url":"file:///private/var/containers/Bundle/Application/Y/Other.app/"}]}}
    """#.utf8)

    static func processes(_ entries: [(Int, String)]) -> Data {
        let list = entries.map { ["processIdentifier": $0.0, "executable": "file://" + $0.1] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["result": ["runningProcesses": list]])
    }

    @Test func oneBundleIsItsMainExecutableAndEndsWithIt() throws {
        let running = Self.processes([(10, "/private/var/containers/Bundle/Application/X/Probe.app/PlugIns/Widget.appex/Widget"),
                                      (11, "/private/var/containers/Bundle/Application/X/Probe.app/Probe"),
                                      (12, "/usr/libexec/backboardd")])
        let selection = try PhysicalLogCapture.select(try Self.capture(["--seconds", "5", "--bundle", "com.example.probe"]),
                                                      apps: { Self.apps }, processes: { running })
        #expect(selection.pid == 11 && selection.pids == [11] && selection.executable == "/private/var/containers/Bundle/Application/X/Probe.app/Probe")
    }

    @Test func oneTargetNotRunningOrNotInstalledIsRefusedAndSeveralNamesStreamEveryProcess() throws {
        let none = Self.processes([(12, "/usr/libexec/backboardd")])
        for target in [["--bundle", "com.example.probe"], ["--bundle", "com.example.absent"], ["--process", "Probe"]] {
            let failure = #expect(throws: CommandFailure.self) {
                try PhysicalLogCapture.select(try Self.capture(["--seconds", "5"] + target), apps: { Self.apps }, processes: { none })
            }
            #expect(failure?.code == .targetUnresolved && failure?.inputSent == CommandFailure.InputSent.none)
        }
        let twice = Self.processes([(12, "/usr/libexec/backboardd"), (13, "/usr/sbin/backboardd")])
        let selection = try PhysicalLogCapture.select(try Self.capture(["--seconds", "5", "--process", "backboardd"]),
                                                      apps: { Data() }, processes: { twice })
        #expect(selection.pid == nil && selection.names == ["backboardd"])
    }

    @Test func aGroupNeedsNoRunningProcessAndAPIDNeedsNoQuery() throws {
        let group = try PhysicalLogCapture.select(try Self.capture(["--seconds", "5", "--bundle", "com.example.probe", "--process", "locationd"]),
                                                  apps: { Self.apps }, processes: { Issue.record("processes"); return Data() })
        #expect(group.pid == nil && group.folders == ["/var/containers/Bundle/Application/X/Probe.app/"] && group.names == ["locationd"])
        let one = try PhysicalLogCapture.select(try Self.capture(["--seconds", "5", "--pid", "42"]), apps: { Issue.record("apps"); return Data() },
                                                processes: { Issue.record("processes"); return Data() })
        #expect(one == .init(pid: 42, pids: [42]))
        let all = try PhysicalLogCapture.select(try Self.capture(["--seconds", "5"], flags: ["--all"]), apps: { Data() }, processes: { Data() })
        #expect(all.pid == nil && all.everyProcess)
    }

    @Test func aSelectionMatchesByPIDNameOrFolderWithOrWithoutPrivate() {
        let selection = PhysicalLogCapture.Selection(pids: [5], names: ["locationd"], folders: ["/var/containers/Bundle/Application/X/Probe.app/"])
        #expect(selection.accepts(pid: 5, path: "/usr/bin/anything"))
        #expect(selection.accepts(pid: 9, path: "/usr/libexec/locationd"))
        #expect(selection.accepts(pid: 9, path: "/private/var/containers/Bundle/Application/X/Probe.app/PlugIns/W.appex/W"))
        #expect(selection.accepts(pid: 9, path: "/var/containers/Bundle/Application/X/Probe.app/Probe"))
        #expect(!selection.accepts(pid: 9, path: "/var/containers/Bundle/Application/X/Probe.appendix/Probe"))
    }

    // MARK: Filtering and bounds

    static func reader(_ capture: LogCapture, _ selection: PhysicalLogCapture.Selection, ceiling: Int = 1 << 20) -> PhysicalLogReader {
        PhysicalLogReader(capture: capture, selection: selection, receivedBytesCeiling: ceiling)
    }

    @Test func levelsSubsystemsMatchAndAnotherProcessAreFilteredOnTheMac() throws {
        var reader = Self.reader(try Self.capture(["--seconds", "5", "--pid", "3619", "--level", "info", "--subsystem", "com.example.probe",
                                                   "--subsystem", "com.example.net"]), .init(pid: 3619, pids: [3619]))
        var kept: [Bool] = []
        for level: UInt8 in [0, 1, 2, 0x10, 0x11] { kept.append(reader.feed(Self.packet(level: level))) }
        kept.append(reader.feed(Self.packet(subsystem: "com.example.net")))
        kept.append(reader.feed(Self.packet(pid: 77)))
        kept.append(reader.feed(Self.packet(subsystem: "com.apple.UIKit")))
        kept.append(reader.feed(Data([1, 2, 3])))
        #expect(kept.allSatisfy { $0 })
        #expect(reader.entries.count == 5 && reader.filteredOut == 3 && reader.parseFailures == 1 && reader.receivedRecords == 9)
        #expect(reader.firstParseFailure?.contains("3 bytes") == true)
        let first = try #require(JSONSerialization.jsonObject(with: reader.entries[0]) as? [String: Any])
        #expect(first["process"] as? String == "Probe" && first["sender"] as? String == "Probe" && first["message"] as? String == "hola ñ")

        var matching = Self.reader(try Self.capture(["--seconds", "5", "--match", "needle"], flags: ["--all"]), .init())
        _ = matching.feed(Self.packet(message: "a needle here")); _ = matching.feed(Self.packet(pid: 9, message: "hay"))
        #expect(matching.entries.count == 1 && matching.filteredOut == 1)
    }

    @Test func entryByteAndReceivedLimitsStopTheCapture() throws {
        var byEntries = Self.reader(try Self.capture(["--seconds", "5", "--pid", "1", "--max-entries", "2"]), .init(pid: 1, pids: [1]))
        let entries = [byEntries.feed(Self.packet(pid: 1)), byEntries.feed(Self.packet(pid: 1)), byEntries.feed(Self.packet(pid: 1))]
        #expect(entries == [true, true, false] && byEntries.stopReason == .entryLimit && byEntries.truncated)
        var byReceived = Self.reader(try Self.capture(["--seconds", "5", "--pid", "1"]), .init(pid: 1, pids: [1]), ceiling: 300)
        let received = [byReceived.feed(Self.packet(pid: 2)), byReceived.feed(Self.packet(pid: 2))]
        #expect(received == [true, false] && byReceived.stopReason == .byteLimit)
    }

    // MARK: The stream, against a fake relay on socket pairs

    static func plist(_ value: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) -> Data {
        let body = try! PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Plays the device's side of a stream: the check-in replies, the start
    /// status, the given records, then holds the socket open for `hold`
    /// seconds before closing it.
    /// The PID a fake relay was asked to stream.
    final class Started: Sendable {
        let pid = Mutex<Int?>(nil)
        var value: Int? { pid.withLock { $0 } }
    }

    static func fakeRelay(_ descriptor: Int32, records: [Data], hold: Double = 0, startedPid: Started? = nil) {
        let stream = OSTraceRelay.Stream(descriptor: descriptor, deadline: .now + .seconds(20))
        do {
            _ = try stream.plist()
            try stream.write(plist(["Request": "RSDCheckin"]) + plist(["Request": "StartService"]))
            let start = try stream.plist()
            guard start["Request"] as? String == "StartActivity" else { Darwin.close(descriptor); return }
            startedPid?.pid.withLock { $0 = start["Pid"] as? Int }
            try stream.write(Data([1]) + plist(["Status": "RequestSuccessful"], .binary))
            for record in records {
                var length = UInt32(record.count).littleEndian
                try stream.write(Data([2]) + Data(bytes: &length, count: 4) + record)
            }
            Thread.sleep(forTimeInterval: hold)
        } catch {}
        Darwin.close(descriptor)
    }

    /// Plays the device's process list on one socket, as the phone did on
    /// 2026-11-20: one `PidList` answered, then the socket closed.
    static func fakeProcessList(_ descriptor: Int32, pids: [Int]) {
        let stream = OSTraceRelay.Stream(descriptor: descriptor, deadline: .now + .seconds(20))
        do {
            _ = try stream.plist()
            try stream.write(plist(["Request": "RSDCheckin"]) + plist(["Request": "StartService"]))
            guard try stream.plist()["Request"] as? String == "PidList" else { Darwin.close(descriptor); return }
            let payload = Dictionary(uniqueKeysWithValues: pids.map { ("\($0)", ["ProcessName": "p"]) })
            try stream.write(Data([1]) + plist(["Payload": payload], .binary))
        } catch {}
        Darwin.close(descriptor)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRelaysProcessListIsReadOnAFreshSocketEachTime() throws {
        let opened = Mutex(0)
        let lists: [[Int]] = [[1, 5], [1]]
        let another: () throws -> Int32 = {
            let (mine, device) = Self.socketPair()
            let pids = opened.withLock { count -> [Int] in defer { count += 1 }; return lists[count] }
            Thread.detachNewThread { Self.fakeProcessList(device, pids: pids) }
            return mine
        }
        #expect(try PhysicalLogCapture.relayLists(5, another: another))
        #expect(try !PhysicalLogCapture.relayLists(5, another: another))
        #expect(opened.withLock { $0 } == 2)
    }

    static func socketPair() -> (mine: Int32, device: Int32) {
        var pair: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        return (pair[0], pair[1])
    }

    @Test(.timeLimit(.minutes(1)))
    func everyProcessIsAskedForAndTheMacKeepsTheGroup() async throws {
        let (mine, device) = Self.socketPair()
        let records = [Self.packet(pid: 5, level: 0, process: "/usr/libexec/locationd"), Self.packet(pid: 6), Self.packet(pid: 7, process: "/usr/bin/other")]
        let started = Started()
        Thread.detachNewThread { Self.fakeRelay(device, records: records, startedPid: started) }
        let closed = CancelFlag()
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: ["serviceDirectory": "own-tunnel", "ownTunnelLink": "cable"],
                                                       close: { Darwin.close(mine); closed.set() })
        let capture = try Self.capture(["--seconds", "30", "--bundle", "com.example.probe", "--process", "locationd"])
        let selection = PhysicalLogCapture.Selection(names: ["locationd"], folders: ["/var/containers/Bundle/Application/X/Probe.app/"])
        let outcome = try await PhysicalLogCapture.stream(connection, selection: selection, capture: capture)
        #expect(started.value == -1)
        #expect(outcome.reader.stopReason == .closed && outcome.reader.entries.count == 2 && outcome.reader.filteredOut == 1)
        #expect(closed.isSet && outcome.processWatch == nil)
        let result = try #require(JSONSerialization.jsonObject(with: PhysicalLogCapture.result(capture, outcome: outcome,
            selection: selection, route: connection.route)) as? [String: Any])
        #expect(result["deviceStream"] as? String == "every process" && result["serviceDirectory"] as? String == "own-tunnel")
    }

    @Test(.timeLimit(.minutes(1)))
    func oneProcessEndsTheCaptureWhenTheDeviceNoLongerListsIt() async throws {
        let (mine, device) = Self.socketPair()
        let started = Started()
        Thread.detachNewThread { Self.fakeRelay(device, records: [Self.packet(pid: 5)], hold: 20, startedPid: started) }
        let looks = Mutex(0)
        let watch = PhysicalLogCapture.ProcessWatch(source: "relay", isRunning: { looks.withLock { $0 += 1; return $0 < 3 } })
        let closed = CancelFlag()
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: [:], close: { Darwin.close(mine); closed.set() })
        let capture = try Self.capture(["--seconds", "30", "--pid", "5"])
        let begun = ContinuousClock.now
        let outcome = try await PhysicalLogCapture.stream(connection, selection: .init(pid: 5, pids: [5]), capture: capture,
                                                          watch: watch, watchInterval: .milliseconds(100))
        #expect(started.value == 5 && looks.withLock { $0 } == 3)
        #expect(outcome.reader.stopReason == .processEnded && outcome.reader.entries.count == 1)
        #expect(outcome.processWatch == "relay" && closed.isSet)
        #expect(ContinuousClock.now - begun < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1)))
    func aWatchThatFailsLeavesTheCaptureToItsOtherLimitsAndSaysWhy() async throws {
        let (mine, device) = Self.socketPair()
        Thread.detachNewThread { Self.fakeRelay(device, records: [Self.packet(pid: 5)], hold: 1) }
        let watch = PhysicalLogCapture.ProcessWatch(source: "devicectl", isRunning: { throw CommandFailure(.timeout, "slow", inputSent: .none) })
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: [:], close: { Darwin.close(mine) })
        let outcome = try await PhysicalLogCapture.stream(connection, selection: .init(pid: 5, pids: [5]),
                                                          capture: try Self.capture(["--seconds", "30", "--pid", "5"]), watch: watch)
        #expect(outcome.reader.stopReason == .closed && outcome.processWatch?.hasPrefix("devicectl unavailable:") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedStreamThrowsAndClosesTheSocket() async throws {
        let (mine, device) = Self.socketPair()
        Thread.detachNewThread {
            let stream = OSTraceRelay.Stream(descriptor: device, deadline: .now + .seconds(10))
            _ = try? stream.plist()
            try? stream.send(["Request": "RSDCheckin"], format: .xml)
            try? stream.send(["Request": "Nope", "Error": "denied"], format: .xml)
            Darwin.close(device)
        }
        let closed = CancelFlag()
        let connection = PhysicalLogCapture.Connection(descriptor: mine, route: [:], close: { Darwin.close(mine); closed.set() })
        await #expect(throws: CommandFailure.self) {
            _ = try await PhysicalLogCapture.stream(connection, selection: .init(pid: 5, pids: [5]),
                                                    capture: try Self.capture(["--seconds", "5", "--pid", "5"]))
        }
        #expect(closed.isSet)
    }
}
