import MCP

enum AppleMCPServer {
    typealias HandoffConfirmation = @Sendable (HandoffCommand) async throws -> HandoffStatus
    /// Runs one tool's command line; `CommandService.run` outside tests.
    typealias Execute = @Sendable ([String], @escaping HandoffConfirmation) async throws -> CommandOutput

    static func make(service: CommandService) async -> AppleMCPServerSession {
        await make { arguments, confirmation in
            // The tool's command line goes through the CLI's parser.
            try await service.run(arguments, handoffConfirmation: confirmation)
        }
    }

    static func make(execute: @escaping Execute) async -> AppleMCPServerSession {
        let handoff = MCPHandoffChannel()
        let operations = MCPToolOperations()
        let ordering = MCPCallOrdering()
        let server = Server(name: "manzanero", version: manzaneroVersion,
            instructions: "Apple device CLI operations. Physical input/accessibility are experimental. Inspect fresh state after input. Paths are relative to the server working directory. No built-in approval policy: the MCP host controls approvals.",
            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPTools.definitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            guard let server else { throw MCPError.internalError("Server unavailable") }
            let ticket = params._meta?[MCPCallOrdering.ticketKey]?.intValue
            return try await operations.perform {
                // Waiting for the device's earlier mutations is part of the
                // owned operation, so cancellation and shutdown reach it.
                let slot = try await ordering.admit(ticket)
                defer { slot.release() }
                try Task.checkCancellation()
                return try await MCPTools.call(name: params.name, arguments: params.arguments ?? [:]) {
                    try await execute($0) { command in
                        // The handoff is pending now: later mutations of the
                        // device run and meet the handoff pause.
                        slot.release()
                        return try await handoff.confirm(command, server: server)
                    }
                }
            }
        }
        return AppleMCPServerSession(server: server, handoff: handoff, operations: operations, ordering: ordering)
    }

    static func run() async throws {
        let server = await make(service: CommandService())
        let deadline = MCPShutdownDeadline()
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await server.start(transport: StdioTransport())
                try Task.checkCancellation()
                await server.server.waitUntilCompleted()
            } catch {
                await server.stop()
                throw error
            }
            if !Task.isCancelled { deadline.arm() }
            await server.stop()
            deadline.complete()
        } onCancel: {
            // The CLI signal scope supplies the process deadline on signals.
            Task { await server.stop() }
        }
    }
}

struct AppleMCPServerSession: Sendable {
    let server: Server
    let handoff: MCPHandoffChannel
    let operations: MCPToolOperations
    let ordering: MCPCallOrdering

    /// `initializing` runs inside the `initialize` request, before the SDK
    /// records the session as initialized; tests use it to widen that window.
    func start(transport: any Transport, initializing: (@Sendable () async -> Void)? = nil) async throws {
        try await operations.checkOpen()
        try await server.start(transport: MCPSessionTransport(transport, ordering: ordering), initializeHook: { _, capabilities in
            await handoff.configure(supportsForm: capabilities.elicitation?.form != nil)
            await initializing?()
        })
    }
    func stop() async {
        await operations.cancel()
        // Resolve pending SDK elicitation continuations before draining tools.
        await server.stop()
        await operations.drain()
    }
    func waitUntilCompleted() async {
        await server.waitUntilCompleted()
        await stop()
    }
}

actor MCPHandoffChannel {
    private var supportsForm = false
    func configure(supportsForm: Bool) { self.supportsForm = supportsForm }

    func confirm(_ command: HandoffCommand, server: Server) async throws -> HandoffStatus {
        try Task.checkCancellation()
        guard supportsForm else {
            throw CommandFailure(.hostRequirement, "This MCP host does not support form elicitation. Use a host with form support or perform the handoff in an interactive CLI terminal.", inputSent: .none)
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
