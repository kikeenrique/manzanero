import Darwin
import Foundation
import MCP
import Synchronization

/// Owns operation tasks independently of the SDK's reader/handler lifetime.
/// Closing admissions precedes cancellation, so queued SDK handlers cannot
/// start new device work while shutdown drains previously admitted operations.
actor MCPToolOperations {
    private var closing = false
    private var tasks: [UUID: Task<CallTool.Result, any Error>] = [:]

    func checkOpen() throws {
        guard !closing else { throw CommandFailure(description: "MCP session is shut down; create a new session for another transport.") }
    }

    func perform(_ operation: @escaping @Sendable () async throws -> CallTool.Result) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        let id = UUID()
        let task = Task { @concurrent in
            try Task.checkCancellation()
            return try await operation()
        }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        closing = true
        for task in tasks.values { task.cancel() }
    }

    func drain() async {
        // cancel() must close admissions first. A snapshot suffices because no
        // new operation can enter after that point, including queued handlers.
        precondition(closing)
        let pending = Array(tasks.values)
        for task in pending { _ = await task.result }
    }
}

/// Runtime EOF watchdog. Embedded sessions drain without terminating their host.
final class MCPShutdownDeadline: Sendable {
    private struct State { var armed = false; var completed = false }
    private let state = Mutex(State())
    private let grace: DispatchTimeInterval
    private let expire: @Sendable () -> Void

    init(grace: DispatchTimeInterval = .seconds(30), expire: @escaping @Sendable () -> Void = {
        FileHandle.standardError.write(Data("MCP shutdown exceeded its 30-second cleanup grace; forcing exit. Device-side release is unknown.\n".utf8))
        Darwin._exit(1)
    }) {
        self.grace = grace; self.expire = expire
    }

    func arm() {
        let arm = state.withLock {
            guard !$0.armed, !$0.completed else { return false }
            $0.armed = true
            return true
        }
        guard arm else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if state.withLock({ !$0.completed }) { expire() }
        }
    }

    func complete() { state.withLock { $0.completed = true } }
}
