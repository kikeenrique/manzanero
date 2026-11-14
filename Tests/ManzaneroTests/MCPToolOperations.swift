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
    @Test(arguments: [1, 3]) func shutdownCancelsOwnedWorkAndDrainsItsCleanupBeforeReturning(count: Int) async throws {
        let owner = MCPToolOperations(), gate = ShutdownGate()
        let started = Mutex(0), cleaning = Mutex(0), cleaned = Mutex(0), drained = Mutex(false)
        let calls = (0..<count).map { _ in
            Task {
                try await owner.perform {
                    started.withLock { $0 += 1 }
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch {
                        cleaning.withLock { $0 += 1 }
                        await gate.wait()
                        cleaned.withLock { $0 += 1 }
                        throw error
                    }
                    return .init()
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while started.withLock({ $0 < count }), ContinuousClock.now < deadline { await Task.yield() }
        await owner.cancel()
        let drain = Task { await owner.drain(); drained.withLock { $0 = true }; #expect(cleaned.withLock { $0 == count }) }
        while cleaning.withLock({ $0 < count }), ContinuousClock.now < deadline { await Task.yield() }
        let cleanupStarted = cleaning.withLock { $0 == count }
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

    @Test func callerCancellationReachesOwnedTask() async {
        let owner = MCPToolOperations(), started = Mutex(false), cleaned = Mutex(false)
        let call = Task {
            try await owner.perform {
                defer { cleaned.withLock { $0 = true } }
                started.withLock { $0 = true }
                try await Task.sleep(for: .seconds(30))
                return .init()
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !started.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        call.cancel()
        if case .failure(let error) = await call.result { #expect(error is CancellationError) }
        else { Issue.record("Caller cancellation became a tool response") }
        #expect(cleaned.withLock { $0 })
        await owner.cancel(); await owner.drain()
    }

    @Test func sessionStopResolvesPendingElicitationBeforeDraining() async throws {
        let session = await AppleMCPServer.make(service: CommandService()), gate = ShutdownGate()
        let formRequested = Mutex(false)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "shutdown-test", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { _ in
            formRequested.withLock { $0 = true }
            await gate.wait()
            return .init(action: .cancel)
        }
        try await session.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)
        let call = Task {
            try await client.callTool(name: "request_handoff", arguments: ["platform": "simulator",
                "device": .string(HandoffCommandTests().device), "message": "Synthetic shutdown step"])
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !formRequested.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        let requested = formRequested.withLock { $0 }
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

    @Test func EOFDeadlineArmsOnceAndCompletionDisarmsIt() async throws {
        let expired = Mutex(0)
        let deadline = MCPShutdownDeadline(grace: .milliseconds(10), expire: { expired.withLock { $0 += 1 } })
        deadline.arm(); deadline.arm()
        let limit = ContinuousClock.now + .seconds(2)
        while expired.withLock({ $0 == 0 }), ContinuousClock.now < limit { await Task.yield() }
        #expect(expired.withLock { $0 } == 1)
        deadline.complete()
        let finished = MCPShutdownDeadline(grace: .milliseconds(10), expire: { Issue.record("Completed shutdown expired") })
        finished.arm(); finished.complete(); finished.arm()
        try await Task.sleep(for: .milliseconds(30))
    }
}
