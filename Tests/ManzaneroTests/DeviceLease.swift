import Darwin
import Foundation
import Synchronization
import Testing
@testable import Manzanero

struct DeviceLeaseTests {
    private static let device = "00008110-000A1B2C3D4E5F60"

    private func registry() throws -> (DeviceLeaseRegistry, URL) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        return (DeviceLeaseRegistry(directory: directory), directory)
    }

    /// A second open file description stands in for another process: `flock`
    /// ownership belongs to the description, not to the process.
    private func foreignLock(_ directory: URL, key: String = DeviceLeaseTests.device) -> Int32 {
        let descriptor = open(directory.appendingPathComponent("\(key).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? descriptor : { _ = close(descriptor); return -1 }()
    }

    @Test func leaseExcludesAnotherOwnerUntilReleased() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try registry.acquire(device: Self.device, operation: "tap")
        #expect(foreignLock(directory) == -1)
        lease.release()
        let other = foreignLock(directory)
        #expect(other >= 0)
        _ = close(other)
    }

    @Test func foreignOwnerIsRefusedImmediatelyAndNamed() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = foreignLock(directory)
        defer { _ = close(other) }
        try #require(other >= 0)
        let note = "pid 4242, record\n"
        _ = note.withCString { pwrite(other, $0, strlen($0), 0) }
        do {
            _ = try registry.acquire(device: Self.device, operation: "tap")
            Issue.record("A device held by another owner must be refused")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("another manzanero process"))
            #expect(text.contains("pid 4242, record"))
            #expect(text.contains("no input sent"))
        }
        // The refused attempt must not have disturbed the owner's note.
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(other, &buffer, buffer.count, 0)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == note)
    }

    @Test func sameProcessSharesAndReleasesOnlyWhenLastHolderLeaves() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try registry.acquire(device: Self.device, operation: "record")
        let input = try registry.acquire(device: Self.device.lowercased(), operation: "tap")
        input.release()
        input.release()
        #expect(foreignLock(directory) == -1)
        recording.release()
        let other = foreignLock(directory)
        #expect(other >= 0)
        _ = close(other)
    }

    @Test func droppedLeaseReleasesAndClearsItsNote() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try registry.acquire(device: Self.device, operation: "tap") }
        let other = foreignLock(directory)
        defer { _ = close(other) }
        #expect(other >= 0)
        var information = stat()
        #expect(fstat(other, &information) == 0 && information.st_size == 0)
    }

    @Test func devicesAreIndependent() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try registry.acquire(device: Self.device, operation: "tap")
        let second = try registry.acquire(device: "00008110-FFFFFFFFFFFFFFFF", operation: "tap")
        first.release()
        second.release()
    }

    @Test func removedLockFileDoesNotLeaveAnUnprotectedLease() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Another owner locks the file, then the file is removed from the path.
        let orphan = foreignLock(directory)
        defer { _ = close(orphan) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(Self.device).lock"))
        let lease = try registry.acquire(device: Self.device, operation: "tap")
        defer { lease.release() }
        // The lease is on the file now at the path, so a newcomer is excluded.
        #expect(foreignLock(directory) == -1)
    }

    @Test(arguments: ["", "short", "../escape", "00008110/000A1B2C3D4E5F60", "My iPhone", String(repeating: "A", count: 65)])
    func nonUDIDIdentifiersAreRefused(device: String) throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: CommandFailure.self) { _ = try registry.acquire(device: device, operation: "tap") }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func lockFileIsPrivateAndCloseOnExec() throws {
        let (registry, directory) = try registry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try registry.acquire(device: Self.device, operation: "tap")
        defer { lease.release() }
        var information = stat()
        #expect(stat(directory.appendingPathComponent("\(Self.device).lock").path, &information) == 0)
        #expect(information.st_mode & 0o777 == 0o600)
        // A spawned Apple tool must not inherit the lock and outlive the owner.
        var found = false
        for descriptor in Int32(3)..<1024 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0,
                  String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                      .hasSuffix("\(directory.lastPathComponent)/\(Self.device).lock") else { continue }
            found = true
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
        #expect(found)
    }
}

struct DeviceLeaseServiceTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"

    private func details(mode: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": Self.uuid,
            "properties": ["state": ["developerModeStatus": mode], "hardware": ["udid": "00008110-000A1B2C3D4E5F60"]]]])
    }

    /// Holds the device the way another manzanero process would.
    private func foreignOwner(_ directory: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("\(Self.uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        return descriptor
    }

    @Test(arguments: [["tap", "0.5", "0.5"], ["button", "home"], ["type", "abc"], ["press-label", "Back"]])
    func inputIsRefusedWhileAnotherProcessOwnsTheDevice(operation: [String]) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try foreignOwner(directory)
        defer { _ = close(owner) }
        let data = try details(mode: "enabled")
        // Each alias of the device resolves to the same lease.
        for device in ["My iPhone", "00008110-000A1B2C3D4E5F60", Self.uuid] {
            let service = CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in data })
            do {
                _ = try await service.execute(["physical", device] + operation)
                Issue.record("\(operation[0]) reached dispatch while another owner held \(device)")
            } catch {
                #expect(String(describing: error).contains("another manzanero process"))
            }
        }
    }

    @Test func preparationErrorsComeBeforeOwnership() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try foreignOwner(directory)
        defer { _ = close(owner) }
        let data = try details(mode: "disabled")
        let service = CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in data })
        do {
            _ = try await service.execute(["physical", Self.uuid, "tap", "0.5", "0.5"])
            Issue.record("A disabled device reached dispatch")
        } catch {
            #expect(String(describing: error).contains("Developer Mode is disabled"))
        }
    }

    @Test func nativeRecordingIsRefusedWhileAnotherProcessOwnsTheDevice() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/lease-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try foreignOwner(directory)
        defer { _ = close(owner) }
        let data = try details(mode: "enabled")
        let service = CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in data })
        let destination = directory.appendingPathComponent("refused.mp4").path
        do {
            _ = try await service.execute(["--recording-backend", "coredevice", "physical", Self.uuid, "record", destination, "1"])
            Issue.record("Native recording started while another owner held the device")
        } catch {
            #expect(String(describing: error).contains("another manzanero process"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination))
    }
}

struct CommandServiceIsolationTests {
    /// A blocked device query must not occupy a cooperative-pool thread, or a
    /// long gesture would stall unrelated work such as MCP request handling.
    @Test(.timeLimit(.minutes(1))) func blockingQueriesRunOffTheCooperativePool() async throws {
        let entered = TestSignal(), release = DispatchSemaphore(value: 0)
        let queueLabel = Mutex<String?>(nil)
        let service = CommandService(readinessQuery: { _ in
            queueLabel.withLock { $0 = String(cString: __dispatch_queue_get_label(nil)) }
            entered.signal()
            release.wait()
            throw CommandFailure(description: "fixture stop")
        })
        let blocked = Task { try await service.execute(["physical", "fixture", "readiness"]) }
        await entered.wait()
        // While the service is blocked, far more pool tasks than there are
        // cores still complete: none of them is waiting behind the query.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { await Task.yield() } }
        }
        #expect(queueLabel.withLock { $0 } == "manzanero.command-service")
        release.signal()
        await #expect(throws: CommandFailure.self) { _ = try await blocked.value }
    }

    @Test(.timeLimit(.minutes(1))) func cancellationStillReachesBlockingWork() async throws {
        let entered = TestSignal()
        let sawCancellation = Mutex(false)
        let service = CommandService(readinessQuery: { _ in
            entered.signal()
            while !Task.isCancelled { usleep(1_000) }
            sawCancellation.withLock { $0 = true }
            throw CancellationError()
        })
        let task = Task { try await service.execute(["physical", "fixture", "readiness"]) }
        await entered.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(sawCancellation.withLock { $0 })
    }
}
