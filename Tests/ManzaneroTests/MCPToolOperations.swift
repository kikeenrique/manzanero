import Foundation
import MCP
import Synchronization
import Testing
@testable import Manzanero

private actor ShutdownGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct MCPToolOperationsTests {
    // The waits below are signals, not wall-clock polls: on a runner with few
    // cores, how soon the pool reaches the owned tasks is not under test. The
    // time limit turns a lost signal into a failure instead of a hang.
    @Test(.timeLimit(.minutes(1)), arguments: [1, 3])
    func shutdownCancelsOwnedWorkAndDrainsItsCleanupBeforeReturning(count: Int) async throws {
        let owner = MCPToolOperations(), gate = ShutdownGate()
        let started = TestSignal(count: count), cleaning = TestSignal(count: count)
        let cleaned = Mutex(0), drained = Mutex(false)
        let calls = (0..<count).map { _ in
            Task { @Sendable in
                try await owner.perform {
                    started.signal()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch {
                        cleaning.signal()
                        await gate.wait()
                        cleaned.withLock { $0 += 1 }
                        throw error
                    }
                    return .init()
                }
            }
        }
        #expect(await started.wait())
        await owner.cancel()
        let drain = Task { await owner.drain(); drained.withLock { $0 = true }; #expect(cleaned.withLock { $0 == count }) }
        let cleanupStarted = await cleaning.wait()
        // Every owned cleanup is now parked on the gate, so drain must still
        // be waiting; give it a moment in which it could wrongly return.
        try await Task.sleep(for: .milliseconds(20))
        #expect(cleanupStarted && !drained.withLock { $0 })
        await gate.release()
        await drain.value
        for call in calls {
            if case .failure(let error) = await call.result { #expect(error is CancellationError) }
            else { Issue.record("Shutdown did not cancel owned tool") }
        }
        #expect(drained.withLock { $0 })
    }

    @Test func closedAdmissionsNeverExecuteQueuedOperations() async {
        let owner = MCPToolOperations()
        await owner.cancel()
        do {
            _ = try await owner.perform { Issue.record("Shutdown admitted new tool"); return .init() }
            Issue.record("Closed owner returned success")
        } catch { #expect(error is CancellationError) }
        await owner.drain()
        await owner.cancel()
        await owner.drain()
    }

    @Test(.timeLimit(.minutes(1))) func callerCancellationReachesOwnedTask() async {
        let owner = MCPToolOperations(), started = TestSignal(), cleaned = Mutex(false)
        let call = Task {
            try await owner.perform {
                defer { cleaned.withLock { $0 = true } }
                started.signal()
                try await Task.sleep(for: .seconds(30))
                return .init()
            }
        }
        #expect(await started.wait())
        call.cancel()
        if case .failure(let error) = await call.result { #expect(error is CancellationError) }
        else { Issue.record("Caller cancellation became a tool response") }
        #expect(cleaned.withLock { $0 })
        await owner.cancel(); await owner.drain()
    }

    @Test(.timeLimit(.minutes(1))) func sessionStopResolvesPendingElicitationBeforeDraining() async throws {
        let session = await AppleMCPServer.make(service: CommandService()), gate = ShutdownGate()
        let formRequested = TestSignal()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "shutdown-test", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { _ in
            formRequested.signal()
            await gate.wait()
            return .init(action: .cancel)
        }
        try await session.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        let call = Task {
            try await client.callTool(name: "request_handoff", arguments: ["platform": "simulator",
                "device": .string(HandoffCommandTests().device), "message": "Synthetic shutdown step"])
        }
        let requested = await formRequested.wait()
        await session.stop()
        await gate.release()
        await client.disconnect()
        _ = await call.result
        #expect(requested)
        do {
            try await session.start(transport: serverTransport)
            Issue.record("Closed session restarted with closed tool admissions")
        } catch { #expect(String(describing: error).contains("session is shut down")) }
    }

    // The watchdog fires from a Dispatch timer. Spinning on the cooperative
    // pool while waiting for it kept every core of a small runner busy and
    // delayed the timer past a 2 s poll limit; the test now parks on a signal.
    @Test(.timeLimit(.minutes(1))) func EOFDeadlineArmsOnceAndCompletionDisarmsIt() async throws {
        let expired = Mutex(0), fired = TestSignal()
        let deadline = MCPShutdownDeadline(grace: .milliseconds(10), expire: {
            expired.withLock { $0 += 1 }
            fired.signal()
        })
        deadline.arm(); deadline.arm()
        #expect(await fired.wait())
        // A second timer from the repeated arm() would be due by now.
        try await Task.sleep(for: .milliseconds(30))
        #expect(expired.withLock { $0 } == 1)
        deadline.complete()
        let finished = MCPShutdownDeadline(grace: .milliseconds(10), expire: { Issue.record("Completed shutdown expired") })
        finished.arm(); finished.complete(); finished.arm()
        try await Task.sleep(for: .milliseconds(30))
    }
}
