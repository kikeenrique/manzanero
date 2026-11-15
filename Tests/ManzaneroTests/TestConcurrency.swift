import Foundation
import Synchronization
import Testing

// Shared synchronization for tests that coordinate concurrent work.
//
// Swift Testing runs tests in parallel on the Swift concurrency cooperative
// pool, which has one thread per core. On a small CI runner that is two or
// three threads for the whole suite. Tests therefore must not:
//   - wait for another task by spinning (`while !done { await Task.yield() }`):
//     the spinner keeps a pool thread and a core busy, starving the work it
//     waits for and any Dispatch timer the product schedules;
//   - bound such a wait with a short wall-clock limit: how long the pool takes
//     to reach the other task says nothing about the code under test;
//   - block a pool thread (C calls, sockets, child processes) while another
//     pool task must make progress for the blocking call to return.
// Use `TestSignal` to wait for an event, `ManualTestClock` for deadlines that
// the code under test measures, and `DedicatedThreadExecutor` (or the
// `.dedicatedThread` trait) to keep blocking work off the pool. Pair unbounded
// waits with `.timeLimit` so a regression fails instead of hanging.

/// An event that waiters park on until `signal()` has been called `count`
/// times. Waiting suspends without holding a thread.
final class TestSignal: Sendable {
    private struct State {
        var remaining: Int
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state: Mutex<State>

    init(count: Int = 1) {
        precondition(count > 0)
        state = Mutex(State(remaining: count))
    }

    var isSignaled: Bool { state.withLock { $0.remaining <= 0 } }

    func signal() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.remaining -= 1
            guard state.remaining <= 0 else { return [] }
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in ready { waiter.resume() }
    }

    /// Suspends until the signal completes. Returns whether it did; only
    /// cancellation, such as an exceeded `.timeLimit`, ends the wait early.
    @discardableResult
    func wait() async -> Bool {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if state.remaining <= 0 || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
        return isSignaled
    }
}

/// A clock that only moves when the test advances it, so deadline expiry is
/// ordered by the test rather than by how quickly a loaded runner schedules tasks.
final class ManualTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = [:]
    }

    private let state = Mutex(State())
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ready = state.sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// A task executor backed by one thread of its own. Work that prefers it
/// (`withTaskExecutorPreference`, `Task(executorPreference:)`) runs there
/// instead of on the cooperative pool, so it may block without starving other
/// tests, while still running inside its Swift task: `Task.isCancelled`, task
/// locals and Swift Testing's issue attribution keep working.
final class DedicatedThreadExecutor: TaskExecutor, @unchecked Sendable {
    // `condition` guards every stored property below.
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var stopped = false
    private var running = false
    private var owner: pthread_t?
    private let name: String

    @TaskLocal static var current: DedicatedThreadExecutor?

    init(name: String = "manzanero.tests.dedicated") {
        self.name = name
        condition.lock()
        startThread()
        condition.unlock()
    }

    /// Requires `condition` to be held.
    private func startThread() {
        running = true
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        // A job that arrives after stop() (a task that outlived its test)
        // still runs, on a fresh thread if the first one already exited.
        if !running { startThread() }
        condition.signal()
        condition.unlock()
    }

    /// Lets the thread exit once queued jobs have run. Call it when no task
    /// is expected to prefer this executor any more.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    /// Whether the caller is running on this executor's thread.
    var isCurrentThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let owner else { return false }
        return pthread_equal(owner, pthread_self()) != 0
    }

    private func run() {
        condition.lock()
        owner = pthread_self()
        condition.unlock()
        while true {
            condition.lock()
            while jobs.isEmpty && !stopped { condition.wait() }
            if jobs.isEmpty {
                running = false
                owner = nil
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    /// Runs `operation` in the current task with a fresh dedicated thread as
    /// its preferred executor, and releases the thread afterwards.
    static func run<T>(_ operation: () async throws -> T) async throws -> T {
        let executor = DedicatedThreadExecutor()
        defer { executor.stop() }
        return try await $current.withValue(executor) {
            try await withTaskExecutorPreference(executor, operation: operation)
        }
    }
}

/// Runs each test of a suite (or one test) on its own dedicated thread. For
/// suites whose synchronous bodies block on sockets, C schedules or child
/// processes and so would otherwise hold a cooperative pool thread.
struct DedicatedThreadTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await DedicatedThreadExecutor.run { try await function() }
    }
}

extension Trait where Self == DedicatedThreadTrait {
    static var dedicatedThread: Self { Self() }
}

@Suite(.dedicatedThread)
struct DedicatedThreadTraitTests {
    @Test func synchronousBodyRunsOffTheCooperativePool() {
        #expect(DedicatedThreadExecutor.current?.isCurrentThread == true)
    }

    @Test func asyncBodyResumesOnItsThreadAfterSuspension() async throws {
        try await Task.sleep(for: .milliseconds(1))
        #expect(DedicatedThreadExecutor.current?.isCurrentThread == true)
    }
}

struct TestSignalTests {
    @Test(.timeLimit(.minutes(1))) func releasesEveryWaiterOnlyAfterTheLastSignal() async {
        let signal = TestSignal(count: 2), released = TestSignal(count: 2)
        let waiters = (0..<2).map { _ in Task { let value = await signal.wait(); released.signal(); return value } }
        signal.signal()
        #expect(!signal.isSignaled && !released.isSignaled)
        signal.signal()
        #expect(await released.wait())
        for waiter in waiters { #expect(await waiter.value) }
        #expect(await signal.wait())
    }

    @Test func cancellationEndsAWaitWithoutTheSignal() async {
        let signal = TestSignal()
        let waiter = Task { await signal.wait() }
        waiter.cancel()
        #expect(await waiter.value == false)
    }
}
