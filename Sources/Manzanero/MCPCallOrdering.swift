import Foundation
import MCP
import Synchronization

/// How a tool call is ordered against the other calls of its session.
enum MCPCallLane: Equatable, Sendable {
    /// No device, a dry run, or arguments that fail validation: runs at once.
    case free
    /// Read-only: waits for the device's earlier mutations, holds nothing.
    case observation(DeviceTarget)
    /// Waits for the device's earlier mutations and holds the device until
    /// the hold ends.
    case mutation(DeviceTarget, Hold)

    enum Hold: Sendable {
        /// Until the call returns.
        case completion
        /// Only until it is admitted: a capture (`record_screen`,
        /// `capture_frames`, `capture_console`) runs alongside the calls
        /// that follow it, which is what it is for.
        case admission
        /// Until the handoff is pending (or the call returns first): later
        /// mutations then run and are refused by the handoff pause, as
        /// before, instead of waiting for the person.
        case handoffPending
    }

    /// Classifies a call by the request the CLI's parser makes of it, the
    /// same request `CommandService` will execute.
    static func of(_ params: CallTool.Parameters) -> MCPCallLane {
        guard let definition = MCPTools.definitions.first(where: { $0.name == params.name }),
              let arguments = try? definition.command(params.arguments ?? [:]),
              let invocation = try? CLI.invocation(arguments), !invocation.dryRun,
              let addressed = invocation.request.addressed else { return .free }
        let device = DeviceTarget(platform: addressed.platform,
                                  identifier: DeviceTarget.identifier(addressed.device) ?? addressed.device)
        if invocation.request.isReadOnly { return .observation(device) }
        switch invocation.request {
        case .handoff: return .mutation(device, .handoffPending)
        case .record, .frames, .diagnostics(.console): return .mutation(device, .admission)
        default: return .mutation(device, .completion)
        }
    }

    var device: DeviceTarget? {
        switch self {
        case .free: nil
        case .observation(let device), .mutation(let device, _): device
        }
    }
}

/// Per-device arrival order for tool calls.
///
/// The SDK starts each request in a task of its own, so handlers begin in no
/// fixed order. `MCPSessionTransport` therefore registers every `tools/call`
/// here as it reads it, in arrival order, and stamps the ticket into the
/// request's `_meta`; the handler then waits in `admit` until every earlier
/// mutation of the same device has ended. Observations wait for earlier
/// mutations but hold nothing; calls to other devices or to none are not
/// ordered against each other.
final class MCPCallOrdering: Sendable {
    /// The `_meta` key that carries a call's ticket from the transport to its
    /// handler. The transport sets or removes it on every `tools/call`.
    static let ticketKey = "manzanero/ticket"

    private struct State {
        var next = 0
        /// Registered calls that still order others: waiting, or admitted
        /// mutations whose hold has not ended.
        var lanes: [Int: MCPCallLane] = [:]
        /// Request ids of calls not yet admitted, both ways.
        var tickets: [ID: Int] = [:]
        var requests: [Int: ID] = [:]
        /// Cancelled before admission; their handlers must not run.
        var abandoned: Set<Int> = []
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]

        func isClear(_ ticket: Int) -> Bool {
            guard let device = lanes[ticket]?.device else { return true }
            return !lanes.contains { other, lane in
                guard other < ticket, case .mutation(let held, _) = lane else { return false }
                return held == device
            }
        }

        mutating func admit(_ ticket: Int) {
            if let id = requests.removeValue(forKey: ticket) { tickets[id] = nil }
            switch lanes[ticket] {
            case .observation, .mutation(_, .admission): lanes[ticket] = nil
            default: break
            }
        }

        /// Admits every waiter now clear, in ticket order. One pass suffices:
        /// admitting a ticket only clears tickets above it.
        mutating func ready() -> [CheckedContinuation<Void, any Error>] {
            var resumed: [CheckedContinuation<Void, any Error>] = []
            for ticket in waiters.keys.sorted() where isClear(ticket) {
                admit(ticket)
                if let waiter = waiters.removeValue(forKey: ticket) { resumed.append(waiter) }
            }
            return resumed
        }
    }

    private let state = Mutex(State())

    /// Takes the next ticket for a call that needs ordering; nil for `.free`.
    func register(_ lane: MCPCallLane, request: ID) -> Int? {
        guard lane != .free else { return nil }
        return state.withLock { state in
            let ticket = state.next
            state.next += 1
            state.lanes[ticket] = lane
            state.tickets[request] = ticket
            state.requests[ticket] = request
            return ticket
        }
    }

    /// `notifications/cancelled` for a call not yet admitted: it gives up its
    /// place, and its handler, if it ever starts, ends without running.
    /// An admitted call is cancelled through its task instead.
    func abandon(request: ID) {
        let (cancelled, ready) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, [CheckedContinuation<Void, any Error>]) in
            guard let ticket = state.tickets.removeValue(forKey: request) else { return (nil, []) }
            state.requests[ticket] = nil
            state.lanes[ticket] = nil
            state.abandoned.insert(ticket)
            return (state.waiters.removeValue(forKey: ticket), state.ready())
        }
        cancelled?.resume(throwing: CancellationError())
        for waiter in ready { waiter.resume() }
    }

    /// Waits until the call may run. The returned slot must be released
    /// when the call ends; releasing it earlier ends its hold early.
    func admit(_ ticket: Int?) async throws -> Slot {
        guard let ticket else { return Slot(ticket: nil, ordering: self) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let (outcome, ready) = state.withLock { state -> (Result<Void, any Error>?, [CheckedContinuation<Void, any Error>]) in
                        if state.abandoned.remove(ticket) != nil || Task.isCancelled { return (.failure(CancellationError()), []) }
                        guard state.lanes[ticket] != nil else { return (.success(()), []) }
                        state.waiters[ticket] = continuation
                        return (nil, state.ready())
                    }
                    if let outcome { continuation.resume(with: outcome) }
                    for waiter in ready { waiter.resume() }
                }
            } onCancel: {
                state.withLock { $0.waiters.removeValue(forKey: ticket) }?.resume(throwing: CancellationError())
            }
        } catch {
            finish(ticket)
            throw error
        }
        return Slot(ticket: ticket, ordering: self)
    }

    /// Ends a ticket's hold. Idempotent.
    fileprivate func finish(_ ticket: Int) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.lanes[ticket] = nil
            if let id = state.requests.removeValue(forKey: ticket) { state.tickets[id] = nil }
            return state.ready()
        }
        for waiter in ready { waiter.resume() }
    }

    struct Slot: Sendable {
        let ticket: Int?
        let ordering: MCPCallOrdering
        func release() { if let ticket { ordering.finish(ticket) } }
    }
}
