import Darwin
import Foundation
import Synchronization

/// One CLI runtime owns these process-wide handlers. Direct HID and MCP runtime
/// shutdown use the scope; MCP request cancellation remains a separate path.
enum CLIInputSignals {
    static func applies(to args: [String], dryRun: Bool) -> Bool {
        !dryRun && (try? CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(args))) != nil
    }

    final class Controller: Sendable {
        private struct State {
            var task: Task<CommandOutput, any Error>?
            var signal: Int32?
            var finished = false
        }
        private let state = Mutex(State())
        private let forceExit: @Sendable (Int32) -> Void
        private let diagnostic: @Sendable (String) -> Void
        private let queue: DispatchQueue
        private let grace: DispatchTimeInterval
        private let context: String

        init(queue: DispatchQueue, grace: DispatchTimeInterval = .seconds(30), context: String = "physical input",
             forceExit: @escaping @Sendable (Int32) -> Void = { Darwin._exit($0) },
             diagnostic: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
            self.queue = queue; self.grace = grace; self.context = context; self.forceExit = forceExit; self.diagnostic = diagnostic
        }

        func bind(_ task: Task<CommandOutput, any Error>) {
            let cancel = state.withLock { state in
                guard !state.finished else { return true }
                state.task = task
                return state.signal != nil
            }
            if cancel { task.cancel() }
        }

        func receive(_ signal: Int32) {
            guard signal == SIGINT || signal == SIGTERM else { return }
            let decision = state.withLock { state -> (first: Bool, task: Task<CommandOutput, any Error>?)? in
                guard !state.finished else { return nil }
                if state.signal != nil { return (false, nil) }
                state.signal = signal
                return (true, state.task)
            }
            guard let decision else { return }
            if !decision.first { forceExit(128 + signal); return }
            decision.task?.cancel()
            diagnostic("Interrupted by \(signal == SIGINT ? "SIGINT" : "SIGTERM"); stopping \(context) and attempting release. UI effect and release remain unverified. A second signal forces exit.\n")
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                let pending = state.withLock { $0.finished ? nil : $0.signal }
                if let pending {
                    diagnostic("\(context) cleanup exceeded its 30-second grace period; forcing exit. Device-side release is unknown.\n")
                    forceExit(128 + pending)
                }
            }
        }

        func finish() -> Int32? {
            state.withLock {
                $0.finished = true
                $0.task = nil
                return $0.signal.map { 128 + $0 }
            }
        }
    }

    static func run(context: String = "physical input", _ operation: @escaping @Sendable () async throws -> CommandOutput) async throws -> CommandOutput {
        let queue = DispatchQueue(label: "manzanero.cli.input-signals")
        let controller = Controller(queue: queue, context: context)
        let oldInterrupt = Darwin.signal(SIGINT, SIG_IGN)
        let oldTerminate = Darwin.signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { controller.receive(signal) }
            source.resume()
            return source
        }
        defer {
            sources.forEach { $0.cancel() }
            Darwin.signal(SIGINT, oldInterrupt)
            Darwin.signal(SIGTERM, oldTerminate)
        }
        let task = Task { @concurrent in
            try Task.checkCancellation()
            return try await operation()
        }
        controller.bind(task)
        let result = await task.result
        if let code = controller.finish() {
            return CommandOutput(data: Data(), exitCode: code)
        }
        return try result.get()
    }
}
