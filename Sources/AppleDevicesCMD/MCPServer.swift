import MCP

enum AppleMCPServer {
    static func make(service: CommandService) async -> AppleMCPServerSession {
        let handoff = MCPHandoffChannel()
        let server = Server(name: "appledevicescmd", version: "0.1.0-dev",
            instructions: "Apple device CLI operations. Physical input/accessibility are experimental. Inspect fresh state after input. Pair interactively using the CLI before supplying a pairing_file. Paths are relative to the server working directory. No built-in approval policy: the MCP host controls approvals.",
            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPTools.definitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            guard let server else { throw MCPError.internalError("Server unavailable") }
            return try await MCPTools.call(name: params.name, arguments: params.arguments ?? [:]) {
                try await service.execute($0, handoffConfirmation: { command in
                    try await handoff.confirm(command, server: server)
                })
            }
        }
        return AppleMCPServerSession(server: server, handoff: handoff)
    }

    static func run() async throws {
        let server = await make(service: CommandService())
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

struct AppleMCPServerSession: Sendable {
    let server: Server
    let handoff: MCPHandoffChannel

    func start(transport: any Transport) async throws {
        try await server.start(transport: transport, initializeHook: { _, capabilities in
            await handoff.configure(supportsForm: capabilities.elicitation?.form != nil)
        })
    }
    func stop() async { await server.stop() }
    func waitUntilCompleted() async { await server.waitUntilCompleted() }
}

actor MCPHandoffChannel {
    private var supportsForm = false
    func configure(supportsForm: Bool) { self.supportsForm = supportsForm }

    func confirm(_ command: HandoffCommand, server: Server) async throws -> HandoffStatus {
        try Task.checkCancellation()
        guard supportsForm else {
            throw CommandFailure(description: "This MCP host does not support form elicitation. Use a host with form support or perform the handoff in an interactive CLI terminal.")
        }
        let response = try await server.requestElicitation(
            message: "Human action needed on \(command.platform) \(command.device):\n\(command.message)\nPerform the step on the device. Do not enter credentials into this form.",
            requestedSchema: .init(title: "Device action needs a person", properties: [
                "completed": .object(["type": "boolean", "title": "I completed the requested step on the device", "default": false])
            ], required: ["completed"]), mode: .form)
        return Self.status(response)
    }

    static func status(_ response: CreateElicitation.Result) -> HandoffStatus {
        switch response.action {
        case .decline: return .declined
        case .cancel: return .cancelled
        case .accept:
            return response.content?.count == 1 && response.content?["completed"]?.boolValue == true ? .acknowledged : .notCompleted
        }
    }
}
