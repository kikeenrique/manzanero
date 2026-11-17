import AppleDeviceBridge
import Darwin
import Foundation
import MCP
import Testing
@testable import Manzanero

/// Quarantine after an input whose release is unknown: the mark, the refusal
/// and `clear-quarantine`. Nothing here contacts a device.
@Suite(.cleansLeaseDirectories)
struct DeviceQuarantineTests {
    private static let device = "00008110-000A1B2C3D4E5F60"
    static let uuid = SimulatorDeviceTests.uuid

    private func registry() -> (DeviceLeaseRegistry, URL) {
        let directory = LeaseDirectories.register("tmp/quarantine-test-\(UUID().uuidString)")
        return (DeviceLeaseRegistry(directory: directory), directory)
    }

    /// Leaves `note` under a free lock, as an owner that exited without releasing does.
    private func abandon(_ directory: URL, note: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("\(Self.device).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        _ = note.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        _ = close(descriptor)
    }

    @Test func aMarkedDeviceRefusesInputUntilCleared() throws {
        let (registry, _) = registry()
        #expect(try registry.quarantine(device: Self.device) == nil)
        #expect(registry.markUncertain(device: Self.device, reason: "tap by pid 7 ended with an unknown outcome"))
        let failure = try #require(throws: CommandFailure.self) { _ = try registry.acquire(device: Self.device, operation: "tap") }
        #expect(failure.code == .deviceQuarantined && failure.inputSent == .none)
        #expect(failure.retry == .afterAction && failure.action == .clearQuarantine)
        #expect(failure.description.contains("tap by pid 7 ended with an unknown outcome") && failure.description.contains("clear-quarantine"))
        // The refusal left no lock behind, and every alias of the device is covered.
        #expect(throws: CommandFailure.self) { _ = try registry.acquire(device: Self.device.lowercased(), operation: "key") }
        // A capture holds no contact and is not refused.
        try registry.acquire(device: Self.device, operation: "record").release()

        let reason = try #require(try registry.clearQuarantine(device: Self.device))
        #expect(reason.hasPrefix("tap by pid 7 ended with an unknown outcome, since 20"))
        try registry.acquire(device: Self.device, operation: "tap").release()
        #expect(try registry.clearQuarantine(device: Self.device) == nil)
    }

    @Test func theFirstReasonIsKeptAndSharedHoldersAreRefusedToo() throws {
        let (registry, _) = registry()
        let recording = try registry.acquire(device: Self.device, operation: "record")
        defer { recording.release() }
        try registry.acquire(device: Self.device, operation: "tap").release()
        registry.markUncertain(device: Self.device, reason: "first")
        registry.markUncertain(device: Self.device, reason: "second")
        let failure = try #require(throws: CommandFailure.self) { _ = try registry.acquire(device: Self.device, operation: "tap") }
        #expect(failure.code == .deviceQuarantined && failure.description.contains("first") && !failure.description.contains("second"))
    }

    @Test func anInputOwnerThatExitedWithoutReleasingQuarantinesTheDevice() throws {
        let (registry, directory) = registry()
        try abandon(directory, note: "pid 4242, long-press\n")
        let failure = try #require(throws: CommandFailure.self) { _ = try registry.acquire(device: Self.device, operation: "tap") }
        #expect(failure.code == .deviceQuarantined)
        #expect(failure.description.contains("the previous owner (pid 4242, long-press) exited without releasing the device"))
        // The refused attempt released the lock and cleared the stale note.
        #expect(throws: CommandFailure.self) { _ = try registry.acquire(device: Self.device, operation: "tap") }
        _ = try registry.clearQuarantine(device: Self.device)
        try registry.acquire(device: Self.device, operation: "tap").release()
    }

    @Test func clearingFindsAnAbandonedOwnerBeforeAnyNewOwnerDoes() throws {
        let (registry, directory) = registry()
        try abandon(directory, note: "pid 4242, type\n")
        let reason = try #require(try registry.clearQuarantine(device: Self.device))
        #expect(reason.contains("the previous owner (pid 4242, type) exited without releasing the device"))
        // The note is gone with the mark, so the next owner is not refused.
        try registry.acquire(device: Self.device, operation: "tap").release()
        #expect(try registry.quarantine(device: Self.device) == nil)
        // A lock this process holds is an owner at work, not an abandoned one.
        let held = try registry.acquire(device: Self.device, operation: "long-press")
        #expect(try registry.clearQuarantine(device: Self.device) == nil)
        held.release()
    }

    @Test func aCaptureOwnerThatExitedDoesNotQuarantine() throws {
        for operation in DeviceLeaseRegistry.streamOperations {
            let (registry, directory) = registry()
            try abandon(directory, note: "pid 4242, \(operation)\n")
            try registry.acquire(device: Self.device, operation: "tap").release()
            #expect(try registry.quarantine(device: Self.device) == nil)
        }
        // A normal release leaves no note, so the next owner finds nothing.
        let (registry, _) = registry()
        try registry.acquire(device: Self.device, operation: "long-press").release()
        try registry.acquire(device: Self.device, operation: "tap").release()
        #expect(try registry.quarantine(device: Self.device) == nil)
    }

    @Test func onlyOperationsThatPressSomethingCanQuarantine() {
        for operation in ["tap", "long-press", "swipe", "gesture", "multi-tap", "button", "key", "type", "paste", "wake", "remote", "crown", "detect-layout"] {
            #expect(DeviceQuarantine.canLeaveInputHeld(operation))
        }
        for operation in ["press-id", "press-label", "scroll-id", "scroll-label", "tree", "fold", "unfold", "hinge"]
            + DirectAccessibilitySetValue.operations + AccessibilityWait.operations {
            #expect(!DeviceQuarantine.canLeaveInputHeld(operation))
        }
    }

    final class Calls: @unchecked Sendable {
        var touches = 0
        var fail = true
    }

    private func service(_ calls: Calls) -> CommandService {
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.touch = { _, _ in
            calls.touches += 1
            if calls.fail {
                throw CommandFailure.inputDispatch(status: ADCInputOutcomeUnknown, message: "Fixture: completion barrier unconfirmed; do not replay automatically.")
            }
        }
        return CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                              readinessQuery: { _ in Issue.record("Simulator command queried CoreDevice"); return Data() })
    }

    @Test func anUnknownOutcomeQuarantinesTheSimulatorUntilClearQuarantine() async throws {
        let calls = Calls(), service = service(calls)
        let tap = ["tap", "0.5", "0.5", "--simulator", Self.uuid]
        let unknown = await #expect(throws: CommandFailure.self) { _ = try await service.run(tap) }
        #expect(unknown?.code == .inputOutcomeUnknown && unknown?.inputSent == .possible && calls.touches == 1)

        calls.fail = false
        let refused = await #expect(throws: CommandFailure.self) { _ = try await service.run(tap) }
        #expect(refused?.code == .deviceQuarantined && refused?.inputSent == CommandFailure.InputSent.none && calls.touches == 1)
        #expect(refused?.description.contains("tap by pid \(getpid()) ended with an unknown outcome") == true)

        let plan = try SimulatorInputTests.json(await service.run(["clear-quarantine", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["operation"] as? String == "clear-quarantine" && plan["status"] == nil)
        let still = await #expect(throws: CommandFailure.self) { _ = try await service.run(tap) }
        #expect(still?.code == .deviceQuarantined)

        let cleared = try SimulatorInputTests.json(await service.run(["clear-quarantine", "--simulator", Self.uuid]))
        #expect(cleared["status"] as? String == "cleared" && cleared["inputSent"] as? Bool == false)
        #expect((cleared["reason"] as? String)?.contains("unknown outcome") == true)
        _ = try await service.run(tap)
        #expect(calls.touches == 2)
        let again = try SimulatorInputTests.json(await service.run(["clear-quarantine", "--simulator", Self.uuid]))
        #expect(again["status"] as? String == "not-quarantined" && again["reason"] is NSNull)
    }

    @Test func aFailureBeforeAnyInputDoesNotQuarantine() async throws {
        let calls = Calls()
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.touch = { _, _ in
            calls.touches += 1
            if calls.fail { throw CommandFailure.inputDispatch(status: 1, message: "Fixture: HID service not ready; no input sent.") }
        }
        let service = CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment,
                                     readinessQuery: { _ in Issue.record("Simulator command queried CoreDevice"); return Data() })
        let tap = ["tap", "0.5", "0.5", "--simulator", Self.uuid]
        let failure = await #expect(throws: CommandFailure.self) { _ = try await service.run(tap) }
        #expect(failure?.code == .transportFailed)
        calls.fail = false
        _ = try await service.run(tap)
        #expect(calls.touches == 2)
    }

    @Test func theMCPToolBuildsTheSameCommand() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "clear_quarantine" })
        #expect(try tool.command(["platform": "simulator", "device": .string(Self.uuid)]) == ["clear-quarantine", "--simulator=\(Self.uuid)"])
        #expect(try request(["clear-quarantine", "--device", Self.device]) == .clearQuarantine(Target(platform: .physical, identifier: Self.device)))
        #expect(try request(["clear-quarantine", "--device", Self.device]).isReadOnly)
    }
}
