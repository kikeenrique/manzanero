import MCP

enum AppleMCPServer {
    static func make(service: CommandService) async -> Server {
        let server = Server(name: "appledevicescmd", version: "0.1.0-dev",
            instructions: "Apple device CLI operations. Physical input/accessibility are experimental. Inspect fresh state after input. Pair interactively using the CLI before supplying a pairing_file. Paths are relative to the server working directory. No built-in approval policy: the MCP host controls approvals.",
            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPTools.definitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await MCPTools.call(name: params.name, arguments: params.arguments ?? [:]) {
                try await service.execute($0)
            }
        }
        return server
    }

    static func run() async throws {
        let server = await make(service: CommandService())
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
