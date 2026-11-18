import Foundation
import MCP
import Testing
@testable import Manzanero

/// `batch`: several commands for one device, parsed before any runs and
/// stopped at the first failure. Run against the Apple TV simulator doubles.
@Suite(.cleansLeaseDirectories)
struct BatchCommandTests {
    static let uuid = SimulatorDeviceTests.uuid
    static let target = Target(platform: .simulator, identifier: uuid)

    private func json(_ output: CommandOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    @Test func stepsRunInOrderWithOneResultEach() async throws {
        let pressed = SimulatorRemoteTests.Pressed()
        let service = SimulatorRemoteTests.service(family: "Apple TV", pressed)
        let output = try await service.run(["batch", #"[["remote","up"],["remote","home"],["key","down"]]"#, "--simulator", Self.uuid])
        let receipt = try json(output)
        #expect(output.exitCode == 0 && receipt["status"] as? String == "completed")
        #expect(receipt["completedSteps"] as? Int == 3 && receipt["failedStep"] is NSNull)
        // remote up and key down are keys; remote home is a button.
        #expect(pressed.keys == [82, 81] && pressed.remote.map(\.usage) == [0x40])
        let steps = try #require(receipt["steps"] as? [[String: Any]])
        #expect(steps.map { $0["step"] as? Int } == [1, 2, 3] && steps.allSatisfy { $0["exitCode"] as? Int == 0 })
        #expect((steps[1]["output"] as? [String: Any])?["remote"] as? String == "home")
        #expect((receipt["notRun"] as? [Any])?.isEmpty == true)
    }

    @Test func aFailingStepStopsTheBatchAndTheRestIsNotRun() async throws {
        let pressed = SimulatorRemoteTests.Pressed()
        // Touch is refused on an Apple TV: the second step fails when it runs.
        let service = SimulatorRemoteTests.service(family: "Apple TV", pressed)
        let output = try await service.run(["batch", #"[["remote","left"],["tap","0.5","0.5"],["remote","right"]]"#, "--simulator", Self.uuid])
        let receipt = try json(output)
        #expect(output.exitCode == 1 && receipt["status"] as? String == "failed")
        #expect(receipt["failedStep"] as? Int == 2 && receipt["completedSteps"] as? Int == 1)
        #expect(pressed.keys == [80] && pressed.touches == 0)
        let steps = try #require(receipt["steps"] as? [[String: Any]])
        #expect(steps.count == 2)
        let error = try #require(steps[1]["error"] as? [String: Any])
        #expect(error["code"] as? String == CommandFailure.Code.unsupportedOperation.rawValue && error["inputSent"] as? String == "none")
        #expect(receipt["notRun"] as? [[String]] == [["remote", "right"]])
    }

    @Test func everyStepIsCheckedBeforeAnyRuns() async throws {
        let pressed = SimulatorRemoteTests.Pressed()
        let service = SimulatorRemoteTests.service(family: "Apple TV", pressed)
        let failure = await #expect(throws: CommandFailure.self) {
            _ = try await service.run(["batch", #"[["remote","up"],["remote","sideways"]]"#, "--simulator", Self.uuid])
        }
        #expect(failure?.code == .usage && failure?.description.contains("batch step 2") == true)
        #expect(failure?.inputSent == CommandFailure.InputSent.none && pressed.keys.isEmpty)
    }

    @Test func whatAStepMayNotBe() throws {
        let refused: [[[String]]] = [
            [], [[]],
            [["remote", "up", "--simulator", Self.uuid]], [["remote", "up", "--device=x"]], [["remote", "up", "--dry-run"]],
            [["keyboard-layouts"]], [["doctor"]],
            [["batch", "[[\"remote\",\"up\"]]"]],
            [["handoff", "Do it", "5", "--until", "focused", "--id", "x"]],
            Array(repeating: ["remote", "up"], count: BatchCommand.maximumSteps + 1),
        ]
        for steps in refused {
            #expect(throws: CommandFailure.self) { try BatchCommand(target: Self.target, steps: steps) }
        }
        for text in ["", "{}", "[1]", #"[["remote",1]]"#, "[[]]", "not json"] {
            #expect(throws: CommandFailure.self) { try BatchCommand(target: Self.target, json: text) }
        }
        // Words after `--` are operands, so a negative number is not an option.
        let crown = try BatchCommand(target: Self.target, steps: [["crown", "--", "-200"]])
        #expect(crown.requests == [.simulatorInput(try SimulatorInput(device: Self.uuid, operation: "crown", operands: ["-200"]))])
    }

    @Test func aBatchIsReadOnlyOnlyWhenEveryStepIs() throws {
        let reading = CommandRequest.batch(try BatchCommand(target: Self.target, steps: [["tree"], ["wait", "--id", "x"]]))
        let acting = CommandRequest.batch(try BatchCommand(target: Self.target, steps: [["tree"], ["remote", "up"]]))
        #expect(reading.isReadOnly && !acting.isReadOnly)
        // Any simulator step runs under the signal scope, so the batch does.
        #expect(reading.signalContext == "batch" && acting.signalContext == "batch")
        #expect(acting.addressed?.device == Self.uuid && acting.addressed?.operation == "batch")
    }

    @Test func aDryRunPlansEveryStepAndSendsNothing() async throws {
        let pressed = SimulatorRemoteTests.Pressed()
        let service = SimulatorRemoteTests.service(family: "Apple TV", pressed)
        let receipt = try json(await service.run(["batch", #"[["remote","menu"],["remote","select"]]"#, "--simulator", Self.uuid], dryRun: true))
        #expect(receipt["status"] as? String == "planned" && receipt["completedSteps"] as? Int == 2)
        let steps = try #require(receipt["steps"] as? [[String: Any]])
        #expect((steps[0]["output"] as? [String: Any])?["usage"] as? Int == 0x46)
        #expect(pressed.keys.isEmpty && pressed.remote.isEmpty)
    }

    @Test func mcpToolCarriesTheStepsAsTheSameCommand() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "run_batch" })
        let steps: Value = .array([.array(["remote", "up"]), .array(["wait", "--id", "x", "--timeout", "2"])])
        let args = try tool.command(["device": .string(Self.uuid), "platform": "simulator", "steps": steps])
        #expect(args.prefix(3) == ["batch", "--simulator=\(Self.uuid)", "--"])
        #expect(try request(args) == .batch(try BatchCommand(target: Self.target, steps: [["remote", "up"], ["wait", "--id", "x", "--timeout", "2"]])))
        for bad: Value in [.array([]), .array(["remote"]), .array([.array([])]), .array([.array([1])]), "remote up"] {
            #expect(throws: MCPError.self) { try tool.command(["device": .string(Self.uuid), "platform": "simulator", "steps": bad]) }
        }
    }
}
