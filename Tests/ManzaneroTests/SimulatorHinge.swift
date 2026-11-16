import Foundation
import MCP
import Testing
@testable import Manzanero

/// Folding the iPhone Duo simulator against injected bridge calls, display
/// information and waits.
struct SimulatorHingeTests {
    static let uuid = SimulatorDeviceTests.uuid
    typealias Fixture = SimulatorDisplaysTests

    /// The Duo's display information with each integrated display's backlight.
    static func duo(outer: String, inner: String) -> Data {
        Fixture.json([
            Fixture.display(1, "LCD", device: "primary", primary: true, size: [1398, 2034], backlight: outer, active: outer == "activeOn"),
            Fixture.display(2, "TVOut", device: "external-0", kind: "external"),
            Fixture.display(3, "LCD-1", device: "primary-1", size: [2007, 2853], backlight: inner, active: inner == "activeOn"),
            Fixture.display(5, "Resizable", device: "resizable", kind: "virtual")])
    }

    static let folded = duo(outer: "activeOn", inner: "off")
    static let unfolded = duo(outer: "off", inner: "activeOn")
    static let both = duo(outer: "activeOn", inner: "activeOn")
    /// An ordinary phone: one integrated display.
    static let phone = Fixture.json([Fixture.display(1, "LCD", device: "primary", primary: true, size: [1170, 2532], backlight: "activeOn", active: true)])

    final class Moved: @unchecked Sendable {
        var angles: [Double] = []
        var displays: [Data]
        var reads = 0
        var pauses: [Duration] = []
        var onPause: (() throws -> Void)?
        init(_ displays: [Data]) { self.displays = displays }
    }

    static func environment(_ moved: Moved) -> SimulatorEnvironment {
        var environment = SimulatorInputTests.environment(SimulatorInputTests.Sent())
        environment.displayInfo = { device in
            #expect(device == uuid)
            defer { moved.reads += 1 }
            return moved.displays[min(moved.reads, moved.displays.count - 1)]
        }
        environment.hinge = { device, degrees in
            #expect(device == uuid)
            moved.angles.append(degrees)
        }
        environment.pause = { duration in
            moved.pauses.append(duration)
            try moved.onPause?()
        }
        // A clock that does not move: the wait is bounded by its read count.
        let start = ContinuousClock.now
        environment.now = { start }
        return environment
    }

    static func service(_ moved: Moved) -> CommandService {
        CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment(moved),
                       readinessQuery: { _ in Issue.record("Simulator hinge queried CoreDevice"); return Data() })
    }

    @Test func operandsAreCheckedAndPhysicalDevicesRefusedBeforeContact() throws {
        #expect(try simulatorInput(["fold", "--simulator", Self.uuid])?.operands == [])
        #expect(try simulatorInput(["hinge", "90", "--simulator", Self.uuid])?.operands == ["90.0"])
        #expect(try simulatorInput(["hinge", "0", "--simulator", Self.uuid])?.operands == ["0.0"])
        for degrees in ["-1", "180.5", "nan", "inf", "open", ""] {
            let failure = try #require(throws: CommandFailure.self) { try request(["hinge", degrees, "--simulator", Self.uuid]) }
            #expect(failure.code == .usage && failure.inputSent == .none)
        }
        for args in [["fold"], ["unfold"], ["hinge", "90"]] {
            let failure = try #require(throws: CommandFailure.self) { try request(args + ["--device", "phone"]) }
            #expect(failure.code == .unsupportedOperation && failure.inputSent == .none)
        }
        #expect(throws: CommandFailure.self) { try request(["fold", "now", "--simulator", Self.uuid]) }
    }

    @Test func foldSendsZeroAndWaitsUntilOnlyTheOuterDisplayIsAwake() async throws {
        // Unfolded at first; both displays read awake while folding.
        let moved = Moved([Self.unfolded, Self.unfolded, Self.both, Self.both, Self.folded])
        let receipt = try SimulatorInputTests.json(await Self.service(moved).run(["fold", "--simulator", Self.uuid]))
        #expect(moved.angles == [0])
        #expect(receipt["displayObserved"] as? Bool == true && receipt["displayReads"] as? Int == 4)
        #expect((receipt["activeDisplay"] as? [String: Any])?["name"] as? String == "LCD")
        #expect((receipt["expectedDisplay"] as? [String: Any])?["id"] as? Int == 1)
        #expect(moved.pauses == Array(repeating: SimulatorHinge.pollInterval, count: 3))
        #expect(receipt["note"] == nil && receipt["degrees"] as? Double == 0)
    }

    @Test func unfoldSendsOneEightyAndWaitsForTheInnerDisplay() async throws {
        let moved = Moved([Self.folded, Self.unfolded])
        let receipt = try SimulatorInputTests.json(await Self.service(moved).run(["unfold", "--simulator", Self.uuid]))
        #expect(moved.angles == [180] && moved.pauses.isEmpty)
        #expect(receipt["displayObserved"] as? Bool == true && receipt["displayReads"] as? Int == 1)
        #expect((receipt["activeDisplay"] as? [String: Any])?["name"] as? String == "LCD-1")
    }

    @Test func waitIsBoundedAndReportsAnUnobservedDisplay() async throws {
        let moved = Moved([Self.folded])
        let receipt = try SimulatorInputTests.json(await Self.service(moved).run(["unfold", "--simulator", Self.uuid]))
        #expect(moved.angles == [180])
        #expect(receipt["displayObserved"] as? Bool == false && receipt["displayReads"] as? Int == SimulatorHinge.pollLimit)
        #expect(moved.reads == 1 + SimulatorHinge.pollLimit && moved.pauses.count == SimulatorHinge.pollLimit - 1)
        #expect((receipt["activeDisplay"] as? [String: Any])?["name"] as? String == "LCD")
        #expect((receipt["note"] as? String)?.contains("did not show LCD-1 awake") == true)
    }

    @Test func wallClockAlsoBoundsTheWait() async throws {
        let moved = Moved([Self.folded])
        var environment = Self.environment(moved)
        // Each reading of the clock is a whole wait limit later.
        final class Ticks: @unchecked Sendable { var value = 0 }
        let ticks = Ticks(), start = ContinuousClock.now
        environment.now = { defer { ticks.value += 1 }; return start.advanced(by: SimulatorHinge.waitLimit * ticks.value) }
        let service = CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment)
        let receipt = try SimulatorInputTests.json(await service.run(["unfold", "--simulator", Self.uuid]))
        #expect(receipt["displayObserved"] as? Bool == false && receipt["displayReads"] as? Int == 1)
    }

    @Test func cancellationDuringTheWaitStopsReading() async throws {
        let moved = Moved([Self.folded])
        moved.onPause = { throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await Self.service(moved).run(["unfold", "--simulator", Self.uuid])
        }
        #expect(moved.angles == [180] && moved.reads == 2 && moved.pauses.count == 1)
    }

    @Test(arguments: [["fold"], ["unfold"], ["hinge", "45"]])
    func nonFoldableSimulatorIsRefusedBeforeInput(_ args: [String]) async throws {
        let moved = Moved([Self.phone])
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await Self.service(moved).run(args + ["--simulator", Self.uuid])
        }
        #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
        #expect(moved.angles.isEmpty && moved.reads == 1)
    }

    @Test func hingeSendsTheAngleAndPromisesNoDisplay() async throws {
        let moved = Moved([Self.folded, Self.both])
        let receipt = try SimulatorInputTests.json(await Self.service(moved).run(["hinge", "110", "--simulator", Self.uuid]))
        #expect(moved.angles == [110] && moved.reads == 2 && moved.pauses.isEmpty)
        #expect(receipt["displayObserved"] as? Bool == false && receipt["activeDisplay"] is NSNull)
        #expect(receipt["expectedDisplay"] == nil && (receipt["note"] as? String)?.contains("depends on the path") == true)
    }

    @Test func dryRunReadsNothingAndMCPToolsMapToTheCommands() async throws {
        let moved = Moved([Self.folded])
        let plan = try SimulatorInputTests.json(await Self.service(moved).run(["unfold", "--simulator", Self.uuid], dryRun: true))
        #expect(plan["degrees"] as? Double == 180 && plan["service"] as? String == SimulatorHinge.service)
        #expect(plan["deviceLease"] as? String == "simulator UUID" && moved.reads == 0 && moved.angles.isEmpty)
        let fold = try #require(MCPTools.definitions.first { $0.name == "fold_device" })
        #expect(try fold.command(["device": .string(Self.uuid), "state": "unfold"]) == ["unfold", "--simulator=\(Self.uuid)"])
        let hinge = try #require(MCPTools.definitions.first { $0.name == "set_hinge_angle" })
        let args = try hinge.command(["device": .string(Self.uuid), "degrees": 90])
        #expect(args == ["hinge", "--simulator=\(Self.uuid)", "--", "90"])
        #expect(try simulatorInput(args)?.operands == ["90.0"])
    }
}
