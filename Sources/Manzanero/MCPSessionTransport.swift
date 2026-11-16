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
actor MCPSessionTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var pump: Task<Void, Never>?
    /// The `initialize` request whose response has not been sent yet.
    private var initializing: ID?
    private var held: [Data] = []
    /// Set once the host's transport has ended; delivered after `held`.
    private var ended: Result<Void, any Error>?

    init(_ inner: any Transport, logger: Logger = Logger(label: "manzanero.mcp.transport")) {
        self.inner = inner
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
            if let initializing, Self.response(in: data) == initializing {
                self.initializing = nil
                flush()
            }
        }
        try await inner.send(data)
    }

    private func accept(_ data: Data) {
        if initializing != nil, Self.method(of: data) != "ping" {
            held.append(data)
            return
        }
        deliver(data)
    }

    private func deliver(_ data: Data) {
        if let request = Self.request(in: data), request.method == "initialize" {
            initializing = request.id
        }
        continuation.yield(data)
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

    static func method(of data: Data) -> String? { object(data)?["method"]?.stringValue }

    /// A request: a method and an id.
    static func request(in data: Data) -> (method: String, id: ID)? {
        guard let message = object(data), let method = message["method"]?.stringValue, let id = id(message["id"]) else { return nil }
        return (method, id)
    }

    /// The id a response answers: an id and no method.
    static func response(in data: Data) -> ID? {
        guard let message = object(data), message["method"] == nil else { return nil }
        return id(message["id"])
    }
}
