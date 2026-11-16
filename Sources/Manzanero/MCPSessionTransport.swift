import Foundation
import Logging
import MCP

/// The transport the MCP server reads from: the host's transport with one
/// correction to how the pinned SDK (0.12.1) dispatches what it reads.
///
/// The SDK's receive loop starts every request in a task of its own and
/// handles notifications inline, so a request can run before an earlier one
/// has. In strict mode a request other than `ping` that reaches the server
/// before the `initialize` handler has recorded initialization is rejected,
/// and the loop discards that rejection (`_ = try? await handleRequest`), so
/// the client gets no response at all. A client that sends `initialize`,
/// `notifications/initialized` and a `tools/call` without waiting for the
/// first answer loses the call. This transport therefore holds every message
/// after an `initialize` request, except `ping`, until the server has sent
/// that request's response, and then passes them on in arrival order.
///
/// The same dispatch leaves tool calls in no fixed order, so this is also
/// where arrival order is recorded: each `tools/call` after initialization is
/// registered with `MCPCallOrdering` as it is read and carries its ticket to
/// the handler in `params._meta`, and `notifications/cancelled` withdraws a
/// call that has not started.
actor MCPSessionTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    private let ordering: MCPCallOrdering
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var pump: Task<Void, Never>?
    /// The `initialize` request whose response has not been sent yet.
    private var initializing: ID?
    /// Whether an `initialize` request has been answered with a result. The
    /// SDK refuses tool calls before that and never runs their handlers, so
    /// they are not registered.
    private var initialized = false
    private var held: [Data] = []
    /// Set once the host's transport has ended; delivered after `held`.
    private var ended: Result<Void, any Error>?

    init(_ inner: any Transport, ordering: MCPCallOrdering = MCPCallOrdering(),
         logger: Logger = Logger(label: "manzanero.mcp.transport")) {
        self.inner = inner
        self.ordering = ordering
        self.logger = logger
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        try await inner.connect()
        let source = await inner.receive()
        pump = Task {
            do {
                for try await data in source { self.accept(data) }
                self.end(.success(()))
            } catch {
                self.end(.failure(error))
            }
        }
    }

    func disconnect() async {
        pump?.cancel()
        pump = nil
        held.removeAll()
        continuation.finish()
        await inner.disconnect()
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ data: Data) async throws {
        defer {
            if let initializing, let message = Self.object(data), message["method"] == nil,
               Self.id(message["id"]) == initializing {
                self.initializing = nil
                if message["result"] != nil { initialized = true }
                flush()
            }
        }
        try await inner.send(data)
    }

    private func accept(_ data: Data) {
        if initializing != nil, Self.object(data)?["method"]?.stringValue != "ping" {
            held.append(data)
            return
        }
        deliver(data)
    }

    private func deliver(_ data: Data) {
        let value = try? JSONDecoder().decode(Value.self, from: data)
        if let message = value?.objectValue {
            if message["method"]?.stringValue == "initialize", let id = Self.id(message["id"]) { initializing = id }
            continuation.yield(order(message).flatMap { Self.encode(.object($0)) } ?? data)
        } else if let items = value?.arrayValue {
            let ordered = items.map { item in item.objectValue.flatMap(order).map(Value.object) }
            continuation.yield(ordered.contains { $0 != nil }
                ? Self.encode(.array(zip(items, ordered).map { $1 ?? $0 })) ?? data : data)
        } else {
            continuation.yield(data)
        }
    }

    /// Registers a `tools/call` in arrival order and stamps its ticket, or
    /// withdraws a cancelled call. Returns the message to pass on when it
    /// changed.
    private func order(_ message: [String: Value]) -> [String: Value]? {
        switch message["method"]?.stringValue {
        case "notifications/cancelled":
            if let id = Self.id(message["params"]?.objectValue?["requestId"]) { ordering.abandon(request: id) }
            return nil
        case "tools/call":
            guard let id = Self.id(message["id"]), var params = message["params"]?.objectValue else { return nil }
            var meta = params["_meta"]?.objectValue ?? [:]
            let stamped = meta[MCPCallOrdering.ticketKey] != nil
            // A ticket is only ever this transport's: one a client sent is removed.
            meta[MCPCallOrdering.ticketKey] = nil
            if initialized, let parsed = Self.decode(CallTool.Parameters.self, .object(params)),
               let ticket = ordering.register(MCPCallLane.of(parsed), request: id) {
                meta[MCPCallOrdering.ticketKey] = .int(ticket)
            } else if !stamped {
                return nil
            }
            params["_meta"] = .object(meta)
            var ordered = message
            ordered["params"] = .object(params)
            return ordered
        default:
            return nil
        }
    }

    /// Passes on held messages in order until another `initialize` holds them.
    private func flush() {
        while initializing == nil, !held.isEmpty { deliver(held.removeFirst()) }
        if held.isEmpty { finishIfEnded() }
    }

    private func end(_ result: Result<Void, any Error>) {
        ended = result
        if held.isEmpty { finishIfEnded() }
    }

    private func finishIfEnded() {
        switch ended {
        case .success: continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        case nil: break
        }
    }

    // MARK: JSON-RPC envelope

    static func object(_ data: Data) -> [String: Value]? {
        (try? JSONDecoder().decode(Value.self, from: data))?.objectValue
    }

    static func id(_ value: Value?) -> ID? {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): .number(number)
        default: nil
        }
    }

    static func encode(_ value: Value) -> Data? { try? JSONEncoder().encode(value) }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Value) -> T? {
        encode(value).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
