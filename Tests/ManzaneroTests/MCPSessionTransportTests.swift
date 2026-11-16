import Foundation
import MCP
import Testing
@testable import Manzanero

/// A client that writes JSON-RPC messages itself, so a test can send them
/// without waiting for answers, as a pipelining host does.
struct RawMCPClient {
    let transport: InMemoryTransport
    private var messages: AsyncThrowingStream<Data, any Error>.Iterator
    /// Responses and server requests read so far, by id.
    private(set) var responses: [Int: [String: Any]] = [:]
    private(set) var arrival: [Int] = []

    init(_ transport: InMemoryTransport) async throws {
        self.transport = transport
        try await transport.connect()
        messages = await transport.receive().makeAsyncIterator()
    }

    func send(_ message: [String: Any]) async throws {
        var envelope = message
        envelope["jsonrpc"] = "2.0"
        try await transport.send(JSONSerialization.data(withJSONObject: envelope))
    }

    func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) async throws {
        try await send(["id": id, "method": method, "params": params])
    }

    func initialize(_ id: Int = 0, form: Bool = false) async throws {
        var capabilities: [String: Any] = [:]
        if form { capabilities["elicitation"] = ["form": [String: Any]()] }
        let params: [String: Any] = ["protocolVersion": "2025-11-25", "capabilities": capabilities,
                                     "clientInfo": ["name": "raw-test", "version": "1"]]
        try await request(id, "initialize", params)
        try await send(["method": "notifications/initialized"])
    }

    func call(_ id: Int, _ name: String, _ arguments: [String: Any]) async throws {
        try await request(id, "tools/call", ["name": name, "arguments": arguments])
    }

    /// Reads until a message with this id has arrived; returns it.
    @discardableResult
    mutating func response(_ id: Int) async throws -> [String: Any] {
        while responses[id] == nil {
            guard let data = try await messages.next() else { throw MCPError.connectionClosed }
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageID = message["id"] as? Int else { continue }
            responses[messageID] = message
            arrival.append(messageID)
        }
        return responses[id]!
    }
}

struct MCPSessionTransportTests {
    /// The pinned SDK starts each request in a task of its own; a call that
    /// reached its strict initialization check before `initialize` finished
    /// was rejected and the rejection discarded, so it never got a response.
    /// The initialize hook here stays suspended until a ping sent after the
    /// calls has been answered, so the calls have reached the server first.
    @Test(.timeLimit(.minutes(1))) func requestsSentBehindInitializeAreAnswered() async throws {
        let session = await AppleMCPServer.make(service: CommandService()), pinged = TestSignal()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await session.start(transport: serverTransport, initializing: { await pinged.wait() })
        var client = try await RawMCPClient(clientTransport)
        try await client.initialize()
        try await client.request(1, "tools/list")
        try await client.call(2, "decode_accessibility_archive", ["path": "tmp/missing-\(UUID().uuidString).archive"])
        try await client.request(3, "ping")
        try await client.response(3)
        pinged.signal()
        let initialized = try await client.response(0)
        let listed = try await client.response(1)
        let called = try await client.response(2)
        #expect(initialized["result"] != nil)
        #expect(((listed["result"] as? [String: Any])?["tools"] as? [Any])?.count == MCPTools.definitions.count)
        #expect((called["result"] as? [String: Any])?["isError"] as? Bool == true)
        // The held requests are released by the initialize response.
        #expect(client.arrival.firstIndex(of: 0)! < client.arrival.firstIndex(of: 1)!)
        await session.stop()
        await clientTransport.disconnect()
    }
}
