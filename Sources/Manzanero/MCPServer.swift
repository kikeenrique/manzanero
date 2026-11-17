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
                let result = try await MCPTools.call(name: params.name, arguments: params.arguments ?? [:]) {
                    try await execute($0) { command in
                        // The handoff is pending now: later mutations of the
                        // device run and meet the handoff pause.
                        slot.release()
                        return try await handoff.confirm(command, server: server)
                    }
                }
                // What the host's form actually returned, so a result that is
                // not an acknowledgement can be told apart from a host fault.
                if let answer = await handoff.takeAnswer() {
                    // In the structured result too: some hosts show only that.
                    var structured = result.structuredContent?.objectValue ?? [:]
                    structured["formAnswer"] = .string(answer)
                    return .init(content: result.content + [.text(text: answer, annotations: nil, _meta: nil)],
                                 structuredContent: .object(structured), isError: result.isError)
                }
                return result
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
        let response = try await server.requestElicitation(message: Self.message(command), requestedSchema: Self.schema, mode: .form)
        lastAnswer = Self.describe(response)
        return Self.status(response)
    }

    /// What the person reads. The host's buttons are fixed, Accept and
    /// Decline, and a prompt on the device often has an accepting and a
    /// refusing answer of its own (Allow / Don't Allow), so the form must not
    /// read as that prompt's answer. It asks its own question, whether the
    /// step is finished, and says what each button means for that question,
    /// including that either choice made on the device counts as finished.
    ///
    /// Three lines and no blank ones: Claude Code shows the first three
    /// lines of a form's message and folds the rest ("+4 more lines"), which
    /// hid the button meanings of a longer text. They come first, so that a
    /// long step cannot push them out of sight, and the step is kept on one
    /// line.
    static func message(_ command: HandoffCommand) -> String {
        let step = command.message.split(whereSeparator: \.isNewline).joined(separator: " ")
        return """
            Accept = step finished (any choice on the device). Decline = not done.
            Step: \(step)
            Device: \(command.platform) \(command.device)
            """
    }

    /// No fields. A host adds its own Accept and Decline to every form, and
    /// those are the answer. A field of the form's own asked the same thing a
    /// second time: a checkbox was submitted unticked four times by a person
    /// who had done the step, and a required done/not-done choice was shown
    /// in an error state beside the host's buttons (docs/verification.md).
    static let schema = Elicitation.RequestSchema(title: "Device step", properties: [:], required: [])

    private var lastAnswer: String?
    /// The description of the last form answer, once.
    func takeAnswer() -> String? {
        defer { lastAnswer = nil }
        return lastAnswer
    }

    /// The shape of a form answer without free text: the action, and the
    /// name and type of any field a host sent back, with the value only for
    /// Booleans and numbers.
    static func describe(_ response: CreateElicitation.Result) -> String {
        let fields = (response.content ?? [:]).sorted { $0.key < $1.key }.prefix(8).map { key, value -> String in
            let name = String(key.prefix(64))
            switch value {
            case .bool(let flag): return "\(name)=\(flag) (boolean)"
            case .int(let number): return "\(name)=\(number) (integer)"
            case .double(let number): return "\(name)=\(number) (number)"
            case .string(let text): return "\(name) (string, \(text.utf8.count) bytes)"
            case .null: return "\(name) (null)"
            default: return "\(name) (other type)"
            }
        }
        let content = response.content == nil ? "no content" : fields.isEmpty ? "empty content" : fields.joined(separator: ", ")
        return "Form answer from the host: action \(response.action); \(content). Accept without fields acknowledges; decline and cancel do not."
    }

    /// Accept acknowledges, decline and cancel do not. The form has no
    /// fields, so an accepted answer that carries any is not what was asked
    /// and is not an acknowledgement.
    static func status(_ response: CreateElicitation.Result) -> HandoffStatus {
        switch response.action {
        case .decline: return .declined
        case .cancel: return .cancelled
        case .accept: return (response.content ?? [:]).isEmpty ? .acknowledged : .notCompleted
        }
    }
}
