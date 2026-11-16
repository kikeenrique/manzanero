import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

/// Stands in for `CommandService` behind a real MCP session: records when
/// each call starts and ends, and holds a call while its gate is closed.
/// Calls are named by operation, numeric operands and device (`tap 0.1 A`).
private final class FakeDevices: Sendable {
    static let a = "11111111-2222-3333-4444-555555555555"
    static let b = "66666666-7777-8888-9999-AAAAAAAAAAAA"

    private let log = Mutex<[String]>([])
    private let gates: [String: TestSignal]
    private let starts: [String: TestSignal]
    /// Signalled when a gated call is cancelled; its cleanup then waits for
    /// `cleanupGate`, which cancellation does not end.
    let cleaning = TestSignal()
    let cleanupGate = TestSignal()

    init(gated: [String] = [], watched: [String] = []) {
        gates = Dictionary(uniqueKeysWithValues: gated.map { ($0, TestSignal()) })
        starts = Dictionary(uniqueKeysWithValues: Set(gated + watched).map { ($0, TestSignal()) })
    }

    var events: [String] { log.withLock { $0 } }
    func open(_ name: String) { gates[name]!.signal() }
    func started(_ name: String) async -> Bool { await starts[name]!.wait() }
    func hasStarted(_ name: String) -> Bool { events.contains("start \(name)") }
    func position(_ event: String) -> Int { events.firstIndex(of: event) ?? Int.max }

    static func name(_ arguments: [String]) -> String {
        let device = arguments.contains { $0.contains(a) } ? "A" : arguments.contains { $0.contains(b) } ? "B" : "-"
        return ([arguments[0]] + arguments.dropFirst().filter { Double($0) != nil } + [device]).joined(separator: " ")
    }

    func execute(_ arguments: [String], confirm: AppleMCPServer.HandoffConfirmation) async throws -> CommandOutput {
        let name = Self.name(arguments)
        log.withLock { $0.append("start \(name)") }
        starts[name]?.signal()
        defer { log.withLock { $0.append("end \(name)") } }
        if case .handoff(let handoff) = try CLI.invocation(arguments).request {
            _ = try await confirm(handoff)
        }
        if let gate = gates[name], await !gate.wait() {
            cleaning.signal()
            // An unstructured task does not inherit the cancellation.
            await Task { await cleanupGate.wait() }.value
            throw CancellationError()
        }
        return CommandOutput(data: Data("{}".utf8))
    }

    /// A started session and a client that has initialized it.
    func session(form: Bool = false) async throws -> (AppleMCPServerSession, RawMCPClient) {
        let session = await AppleMCPServer.make { [self] arguments, confirm in try await execute(arguments, confirm: confirm) }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await session.start(transport: serverTransport)
        var client = try await RawMCPClient(clientTransport)
        try await client.initialize(form: form)
        try await client.response(0)
        return (session, client)
    }
}

private func target(_ device: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    extra.merging(["platform": "simulator", "device": device]) { $1 }
}

struct MCPCallOrderingTests {
    @Test func callsAreClassifiedByTheRequestTheParserMakes() throws {
        func lane(_ name: String, _ arguments: [String: Value]) -> MCPCallLane {
            MCPCallLane.of(.init(name: name, arguments: arguments))
        }
        let device = DeviceTarget(platform: "simulator", identifier: FakeDevices.a)
        let sim: [String: Value] = ["platform": "simulator", "device": .string(FakeDevices.a.lowercased())]
        #expect(lane("tap", sim.merging(["x": 0.5, "y": 0.5]) { $1 }) == .mutation(device, .completion))
        #expect(lane("get_ui_tree", sim) == .observation(device))
        #expect(lane("wait_for_element", sim.merging(["by": "label", "text": "OK"]) { $1 }) == .observation(device))
        #expect(lane("record_screen", sim.merging(["path": "tmp/ordering.mp4", "seconds": 5]) { $1 }) == .mutation(device, .admission))
        #expect(lane("request_handoff", sim.merging(["message": "Unlock"]) { $1 }) == .mutation(device, .handoffPending))
        #expect(lane("list_displays", ["device": .string(FakeDevices.a)]) == .observation(device))
        #expect(lane("doctor", [:]) == .free)
        #expect(lane("list_keyboard_layouts", [:]) == .free)
        #expect(lane("tap", sim.merging(["x": 2, "y": 0.5]) { $1 }) == .free)
        #expect(lane("no_such_tool", sim) == .free)
    }

    /// Mutations of one device run one at a time in arrival order; an
    /// observation sent after them sees their effects; another device is
    /// not held up.
    @Test(.timeLimit(.minutes(1))) func mutationsOfOneDeviceRunInArrivalOrder() async throws {
        let devices = FakeDevices(gated: ["tap 0.1 0.1 A", "tap 0.2 0.2 A"], watched: ["tap 0.3 0.3 B"])
        var (session, client) = try await devices.session()
        try await client.call(1, "tap", target(FakeDevices.a, ["x": 0.1, "y": 0.1]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.2, "y": 0.2]))
        try await client.call(3, "tap", target(FakeDevices.a, ["x": 0.25, "y": 0.25]))
        try await client.call(4, "get_ui_tree", target(FakeDevices.a))
        try await client.call(5, "tap", target(FakeDevices.b, ["x": 0.3, "y": 0.3]))
        #expect(await devices.started("tap 0.1 0.1 A"))
        // Sent last, to another device: it runs while device A is held.
        #expect(await devices.started("tap 0.3 0.3 B"))
        try await client.response(5)
        #expect(!devices.hasStarted("tap 0.2 0.2 A") && !devices.hasStarted("tap 0.25 0.25 A") && !devices.hasStarted("tree A"))
        devices.open("tap 0.1 0.1 A")
        #expect(await devices.started("tap 0.2 0.2 A"))
        #expect(!devices.hasStarted("tap 0.25 0.25 A") && !devices.hasStarted("tree A"))
        devices.open("tap 0.2 0.2 A")
        for id in 1...4 { try await client.response(id) }
        #expect(devices.position("end tap 0.1 0.1 A") < devices.position("start tap 0.2 0.2 A"))
        #expect(devices.position("end tap 0.2 0.2 A") < devices.position("start tap 0.25 0.25 A"))
        #expect(devices.position("end tap 0.25 0.25 A") < devices.position("start tree A"))
        await session.stop()
    }

    /// A wait sent before the action that satisfies it keeps polling while
    /// that action runs: observations hold nothing.
    @Test(.timeLimit(.minutes(1))) func anEarlierObservationDoesNotHoldUpALaterMutation() async throws {
        let devices = FakeDevices(gated: ["wait A"], watched: ["tap 0.5 0.5 A"])
        var (session, client) = try await devices.session()
        try await client.call(1, "wait_for_element", target(FakeDevices.a, ["by": "label", "text": "Done"]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.5, "y": 0.5]))
        #expect(await devices.started("wait A"))
        #expect(await devices.started("tap 0.5 0.5 A"))
        try await client.response(2)
        devices.open("wait A")
        try await client.response(1)
        await session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledQueuedCallGivesUpItsPlace() async throws {
        let devices = FakeDevices(gated: ["tap 0.1 0.1 A"], watched: ["tap 0.3 0.3 A"])
        var (session, client) = try await devices.session()
        try await client.call(1, "tap", target(FakeDevices.a, ["x": 0.1, "y": 0.1]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.2, "y": 0.2]))
        try await client.send(["method": "notifications/cancelled", "params": ["requestId": 2, "reason": "test"]])
        try await client.call(3, "tap", target(FakeDevices.a, ["x": 0.3, "y": 0.3]))
        #expect(await devices.started("tap 0.1 0.1 A"))
        devices.open("tap 0.1 0.1 A")
        try await client.response(1)
        try await client.response(3)
        #expect(!devices.hasStarted("tap 0.2 0.2 A"))
        #expect(client.arrival == [0, 1, 3])
        await session.stop()
    }

    /// The next mutation waits for the cancelled one's cleanup, not only for
    /// its cancellation.
    @Test(.timeLimit(.minutes(1))) func cancellingTheRunningMutationAdmitsTheNextAfterCleanup() async throws {
        let devices = FakeDevices(gated: ["tap 0.1 0.1 A"], watched: ["tap 0.2 0.2 A"])
        var (session, client) = try await devices.session()
        try await client.call(1, "tap", target(FakeDevices.a, ["x": 0.1, "y": 0.1]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.2, "y": 0.2]))
        #expect(await devices.started("tap 0.1 0.1 A"))
        try await client.send(["method": "notifications/cancelled", "params": ["requestId": 1]])
        #expect(await devices.cleaning.wait())
        #expect(!devices.hasStarted("tap 0.2 0.2 A"))
        devices.cleanupGate.signal()
        try await client.response(2)
        #expect(devices.position("end tap 0.1 0.1 A") < devices.position("start tap 0.2 0.2 A"))
        #expect(client.arrival == [0, 2])
        await session.stop()
    }

    /// A capture is ordered after earlier mutations but holds its device
    /// only until it starts, so input can follow it while it records.
    @Test(.timeLimit(.minutes(1))) func aCaptureStartsInOrderAndThenLetsLaterCallsRun() async throws {
        let devices = FakeDevices(gated: ["tap 0.1 0.1 A", "record 5 A"], watched: ["tap 0.2 0.2 A"])
        var (session, client) = try await devices.session()
        try await client.call(1, "tap", target(FakeDevices.a, ["x": 0.1, "y": 0.1]))
        try await client.call(2, "record_screen", target(FakeDevices.a, ["path": "tmp/ordering-\(UUID().uuidString).mp4", "seconds": 5]))
        try await client.call(3, "tap", target(FakeDevices.a, ["x": 0.2, "y": 0.2]))
        #expect(await devices.started("tap 0.1 0.1 A"))
        #expect(!devices.hasStarted("record 5 A"))
        devices.open("tap 0.1 0.1 A")
        #expect(await devices.started("record 5 A"))
        #expect(await devices.started("tap 0.2 0.2 A"))
        try await client.response(3)
        devices.open("record 5 A")
        try await client.response(2)
        #expect(devices.position("end tap 0.1 0.1 A") < devices.position("start record 5 A"))
        await session.stop()
    }

    /// A pending handoff releases its device, so a later mutation is not
    /// queued behind the person: it runs and meets the handoff pause.
    @Test(.timeLimit(.minutes(1))) func aPendingHandoffReleasesItsDevice() async throws {
        let devices = FakeDevices(watched: ["tap 0.5 0.5 A"])
        var (session, client) = try await devices.session(form: true)
        try await client.call(1, "request_handoff", target(FakeDevices.a, ["message": "Unlock the device"]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.5, "y": 0.5]))
        let form = try await client.request(method: "elicitation/create")
        #expect(await devices.started("tap 0.5 0.5 A"))
        try await client.response(2)
        try await client.send(["id": form["id"]!, "result": ["action": "cancel"]])
        let handoff = try await client.response(1)
        #expect(handoff["result"] != nil)
        await session.stop()
    }

    /// Shutdown cancels calls still waiting for their device, so draining
    /// does not wait for them.
    @Test(.timeLimit(.minutes(1))) func shutdownEndsCallsWaitingForTheirDevice() async throws {
        let devices = FakeDevices(gated: ["tap 0.1 0.1 A"])
        var (session, client) = try await devices.session()
        try await client.call(1, "tap", target(FakeDevices.a, ["x": 0.1, "y": 0.1]))
        try await client.call(2, "tap", target(FakeDevices.a, ["x": 0.2, "y": 0.2]))
        try await client.call(3, "get_ui_tree", target(FakeDevices.a))
        #expect(await devices.started("tap 0.1 0.1 A"))
        devices.cleanupGate.signal()
        await session.stop()
        #expect(!devices.hasStarted("tap 0.2 0.2 A") && !devices.hasStarted("tree A"))
    }
}
