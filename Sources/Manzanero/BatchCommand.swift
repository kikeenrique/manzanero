import Foundation

/// `batch`: several existing commands for one device in one call, run in the
/// order given. Every step is parsed by the same parser as a single command,
/// before anything runs, so a mistake in a later step sends nothing. Each
/// step then runs exactly as it would alone, with its own lease, handoff
/// pause and quarantine check; the batch stops at the first step that fails
/// or answers a non-zero exit code, and never repeats a step.
struct BatchCommand: Sendable, Equatable {
    let target: Target
    /// The steps as given, without a target.
    let steps: [[String]]
    /// The same steps parsed for `target`, in the same order.
    let requests: [CommandRequest]

    static let maximumSteps = 30
    static let usage = "batch takes a JSON array of 1...\(maximumSteps) steps, each an array of the words of one command without its target, for example '[[\"tap\",\"0.5\",\"0.5\"],[\"wait\",\"--id\",\"done\"]]'."
    /// Options the batch supplies or that make no sense inside it.
    static let refusedOptions = ["--device", "--simulator", "--dry-run", ErrorFormat.option]

    init(target: Target, json: String) throws {
        guard json.utf8.count <= 262_144, let data = json.data(using: .utf8),
              let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String]],
              (1...Self.maximumSteps).contains(steps.count), steps.allSatisfy({ !$0.isEmpty }) else {
            throw CommandFailure.usage(Self.usage)
        }
        try self.init(target: target, steps: steps)
    }

    init(target: Target, steps: [[String]]) throws {
        guard (1...Self.maximumSteps).contains(steps.count) else { throw CommandFailure.usage(Self.usage) }
        let option = (target.platform == .simulator ? "--simulator=" : "--device=") + target.identifier
        var requests: [CommandRequest] = []
        for (index, step) in steps.enumerated() {
            let number = index + 1
            // Words after `--` are operands, so only the options before it count.
            let options = step.prefix { $0 != "--" }
            guard !step.isEmpty, !options.contains(where: { word in Self.refusedOptions.contains { word == $0 || word.hasPrefix($0 + "=") } }) else {
                throw CommandFailure.usage("batch step \(number) must be one command without --device, --simulator, --dry-run or \(ErrorFormat.option): the batch supplies them. Nothing was run.")
            }
            // The target goes before `--`, so operands after it stay operands.
            let split = step.firstIndex(of: "--") ?? step.endIndex
            let arguments = Array(step[..<split]) + [option] + Array(step[split...])
            let request: CommandRequest
            do {
                request = try CLI.invocation(arguments).request
            } catch let failure as CommandFailure {
                throw CommandFailure(failure.code, "batch step \(number) (\(step[0])): \(failure.description) Nothing was run.", inputSent: .none)
            }
            if case .batch = request { throw CommandFailure.usage("batch step \(number): a batch cannot hold another batch. Nothing was run.") }
            if case .pair = request { throw CommandFailure.usage("batch step \(number): pair waits for a PIN and runs on its own, not inside a batch. Nothing was run.") }
            if case .handoff = request { throw CommandFailure.usage("batch step \(number): handoff waits for a person and runs on its own, not inside a batch. Nothing was run.") }
            guard let addressed = request.addressed, addressed.device == target.identifier, addressed.platform == target.platform.rawValue else {
                throw CommandFailure.usage("batch step \(number) (\(step[0])) does not act on the batch's device. Nothing was run.")
            }
            requests.append(request)
        }
        self.target = target
        self.steps = steps
        self.requests = requests
    }

    /// The batch's own receipt. `results` holds one entry per step that ran.
    static func receipt(_ batch: BatchCommand, results: [[String: Any]], failedStep: Int?, dryRun: Bool) -> [String: Any] {
        var receipt: [String: Any] = ["operation": "batch", "platform": batch.target.platform.rawValue, "device": batch.target.identifier,
            "stepCount": batch.steps.count, "completedSteps": failedStep.map { $0 - 1 } ?? results.count,
            "status": failedStep == nil ? (dryRun ? "planned" : "completed") : "failed",
            "failedStep": failedStep.map { $0 as Any } ?? NSNull(), "steps": results,
            "notRun": batch.steps.dropFirst(results.count).map { $0 as Any }]
        if failedStep != nil {
            receipt["note"] = "The batch stopped at the failed step. Earlier steps took effect and are not undone; no step is repeated. Inspect the device before continuing."
        }
        return receipt
    }

    /// A step's output: the JSON a command printed, or its text.
    static func output(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    }
}
