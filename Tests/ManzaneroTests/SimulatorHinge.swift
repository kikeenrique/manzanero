import Foundation
import MCP
import Testing
@testable import Manzanero

/// Folding the iPhone Duo simulator against injected bridge calls, display
/// information and waits.
@Suite(.cleansLeaseDirectories)
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

    /// One streamhingeangle sample as the bridge passes it on (iOS 27.2, at rest after hinge 90).
    static func sample(angle: Double = 94.617134094238281, mechanical: Double = 90) -> Data {
        func degrees(_ value: Double, _ symbol: String = "°") -> [String: Any] {
            ["value": value, "unit": ["symbol": symbol, "converter": ["coefficient": 1.0, "constant": 0.0]]]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "angle": degrees(angle), "mechanicalAngle": degrees(mechanical), "minAngle": degrees(0), "maxAngle": degrees(180),
            "velocity": degrees(0, "°/s"), "isAngleValid": true, "isVelocityValid": true, "timestamp": 554572.886528])
    }

    @Test func hingeWithoutAnAngleReadsOneSampleAndSendsNoInput() async throws {
        let moved = Moved([Self.unfolded])
        var environment = Self.environment(moved)
        final class Reads: @unchecked Sendable { var value = 0 }
        let reads = Reads()
        environment.hingeAngle = { device in
            #expect(device == Self.uuid)
            reads.value += 1
            return Self.sample()
        }
        // An observation: no lease, so a registry that refuses every lease must not matter.
        let service = CommandService(leases: try SimulatorAccessibilityTests.unusableLeases(), simulator: environment)
        let result = try SimulatorInputTests.json(await service.run(["hinge", "--simulator", Self.uuid]))
        #expect(reads.value == 1 && moved.angles.isEmpty && moved.reads == 1)
        #expect(result["angle"] as? Double == 94.617134094238281 && result["mechanicalAngle"] as? Double == 90)
        #expect(result["minAngle"] as? Double == 0 && result["maxAngle"] as? Double == 180 && result["isAngleValid"] as? Bool == true)
        #expect(result["readOnly"] as? Bool == true && (result["activeDisplay"] as? [String: Any])?["name"] as? String == "LCD-1")
        let input = try #require(try simulatorInput(["hinge", "--simulator", Self.uuid]))
        #expect(input.operation == SimulatorHinge.angleOperation && input.isObservation)
        #expect(try request(["hinge", "--simulator", Self.uuid]).isReadOnly)
        #expect(try !request(["hinge", "10", "--simulator", Self.uuid]).isReadOnly)
    }

    @Test(arguments: [(0.0, "closed"), (5.0, "closed"), (5.5, "partially-open"), (94.6, "partially-open"),
                      (174.9, "partially-open"), (175.0, "flat"), (180.0, "flat")])
    func postureIsDerivedFromTheAngle(_ angle: Double, _ posture: String) throws {
        #expect(HingeSample.posture(angle) == posture)
        let json = try HingeSample(Self.sample(angle: angle, mechanical: angle)).json
        #expect(json["posture"] as? String == posture && (json["postureSource"] as? String)?.hasPrefix("derived") == true)
    }

    @Test func displaysAddsTheDerivedPostureOnFoldablesOnly() throws {
        final class Reads: @unchecked Sendable { var value = 0 }
        let reads = Reads()
        func list(_ data: Data, _ sample: @escaping @Sendable () throws -> Data) throws -> [String: Any] {
            var environment = Fixture.environment(data)
            environment.hingeAngle = { _ in reads.value += 1; return try sample() }
            let output = try SimulatorDisplayRequest.list(device: Self.uuid).execute(environment: environment, run: { _ in Data() })
            return try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        }
        let unfolded = try list(Self.unfolded) { Self.sample(angle: 180, mechanical: 180) }
        let hinge = try #require(unfolded["hinge"] as? [String: Any])
        #expect(hinge["angle"] as? Double == 180 && hinge["posture"] as? String == "flat" && hinge["postureSource"] != nil)
        // A failed read is reported in place; the displays still list.
        let failed = try list(Self.folded) { throw CommandFailure(.transportFailed, "no sample", inputSent: .none) }
        #expect(((failed["hinge"] as? [String: Any])?["error"] as? String)?.contains("no sample") == true && failed["displays"] != nil)
        #expect(reads.value == 2)
        // A one-display phone: no hinge key and no read, as before.
        let phone = try list(Self.phone) { Issue.record("Read a phone's hinge"); return Data() }
        #expect(phone["hinge"] == nil && reads.value == 2)
    }

    @Test func angleSampleWithoutAnAngleIsATransportFailure() throws {
        #expect(try HingeSample(Self.sample(angle: 0, mechanical: 0)).angle == 0)
        for data in [Data("{}".utf8), Data("[1]".utf8), Data("{\"angle\": {\"value\": \"x\"}}".utf8)] {
            let failure = try #require(throws: CommandFailure.self) { try HingeSample(data) }
            #expect(failure.code == .transportFailed && failure.inputSent == .none)
        }
    }

    @Test func angleReadIsRefusedOnNonFoldableSimulators() async throws {
        let moved = Moved([Self.phone])
        var environment = Self.environment(moved)
        environment.hingeAngle = { _ in Issue.record("Read the angle of a phone"); return Data() }
        let service = CommandService(leases: SimulatorAccessibilityTests.usableLeases(), simulator: environment)
        let failure = await #expect(throws: CommandFailure.self) { _ = try await service.run(["hinge", "--simulator", Self.uuid]) }
        #expect(failure?.code == .unsupportedOperation && failure?.inputSent == CommandFailure.InputSent.none)
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
        let read = try #require(MCPTools.definitions.first { $0.name == "get_hinge_angle" })
        #expect(read.tool.annotations.readOnlyHint == true)
        #expect(try read.command(["device": .string(Self.uuid)]) == ["hinge", "--simulator=\(Self.uuid)"])
        let readPlan = try SimulatorInputTests.json(await Self.service(moved).run(["hinge", "--simulator", Self.uuid], dryRun: true))
        #expect(readPlan["readOnly"] as? Bool == true && moved.reads == 0)
    }
}
