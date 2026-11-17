import Foundation
import Synchronization
import Testing
@testable import Manzanero

/// `handoff --until`: the device is watched and the handoff ends by itself.
struct HandoffWatchTests {
    let fixture = CoreDeviceInputTests()

    /// A service whose lock state is `locked()` at each look, with no pause
    /// worth waiting for between looks.
    func service(locked: @escaping @Sendable () -> Bool, looked: TestSignal? = nil) throws -> CommandService {
        let details = try fixture.details()
        return CommandService(readinessQuery: { _ in details }, uiReadinessQuery: { plan in
            // One reading of the lock per look; the display query is the other call.
            guard plan.arguments[3] == "lockState" else { return try DeviceUIReadinessTests().response(plan.arguments[3]) }
            looked?.signal()
            return try DeviceUIReadinessTests().response("lockState", passcode: locked())
        }, handoffWatchPause: .milliseconds(5))
    }

    func result(_ output: CommandOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    }

    @Test func endsByItselfWhenTheDeviceShowsTheCondition() async throws {
        let looks = Mutex(0)
        let output = try await service(locked: { looks.withLock { $0 += 1; return $0 < 3 } })
            .run(["handoff", "Unlock the phone", "--until", "unlocked", "--device", fixture.udid])
        let value = try result(output)
        #expect(output.exitCode == 0 && value["status"] as? String == "observed" && value["mechanism"] as? String == "device-observation")
        // The device showed it; nobody said so.
        #expect(value["verified"] as? Bool == true && value["humanAcknowledged"] as? Bool == false)
        #expect(value["polls"] as? Int == 3 && value["alreadyMet"] as? Bool == false)
        #expect((value["observation"] as? [String: Any])?["passcodeRequired"] as? Bool == false)
        #expect((value["until"] as? [String: Any])?["until"] as? String == "unlocked")
    }

    @Test func aStepAlreadyDoneReturnsAtOnce() async throws {
        let value = try result(try await service(locked: { false }).run(["handoff", "Unlock the phone", "--until", "unlocked", "--device", fixture.udid]))
        #expect(value["status"] as? String == "observed" && value["polls"] as? Int == 1 && value["alreadyMet"] as? Bool == true)
    }

    /// Paired reads the details the readiness report reads: unpaired at
    /// first, as after a passcode change, then paired.
    @Test func pairedIsReadFromTheDeviceDetails() async throws {
        let looks = Mutex(0), fixture = fixture
        func details(_ connection: String, _ pairing: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["identifier": fixture.uuid,
                "properties": ["hardware": ["udid": fixture.udid], "connection": ["state": connection, "pairingState": pairing]]]])
        }
        let unpaired = try details("disconnected", "unpaired"), paired = try details("connected", "paired")
        let service = CommandService(readinessQuery: { _ in looks.withLock { $0 += 1; return $0 < 3 } ? unpaired : paired },
                                     uiReadinessQuery: { _ in Issue.record("Paired needs no UI query"); return Data() }, handoffWatchPause: .milliseconds(5))
        let value = try result(try await service.run(["handoff", "Pair the phone", "--until", "paired", "--device", fixture.udid]))
        #expect(value["status"] as? String == "observed" && value["polls"] as? Int == 3 && value["alreadyMet"] as? Bool == false)
        #expect(value["observation"] as? [String: String] == ["connection": "connected", "pairing": "paired"])
    }

    @Test func neverWatchesForeverAndATimeoutIsNotSuccess() async throws {
        let output = try await service(locked: { true }).run(["handoff", "Unlock the phone", "1", "--until", "unlocked", "--device", fixture.udid])
        let value = try result(output)
        #expect(output.exitCode == 1 && value["status"] as? String == "timedOut" && value["verified"] as? Bool == false)
        #expect((value["polls"] as? Int ?? 0) > 1 && value["timeoutSeconds"] as? Int == 1)
        #expect((value["observation"] as? [String: Any])?["passcodeRequired"] as? Bool == true)
    }

    @Test func aLookThatFailsIsNotSeenYetRatherThanAnError() async throws {
        let details = try fixture.details()
        let looks = Mutex(0)
        let service = CommandService(readinessQuery: { _ in
            if looks.withLock({ $0 += 1; return $0 == 1 }) { throw CommandFailure(description: "phone unreachable") }
            return details
        }, uiReadinessQuery: { try DeviceUIReadinessTests().response($0.arguments[3]) }, handoffWatchPause: .milliseconds(5))
        let value = try result(try await service.run(["handoff", "Unlock the phone", "--until", "unlocked", "--device", fixture.udid]))
        #expect(value["status"] as? String == "observed" && value["polls"] as? Int == 2)
    }

    @Test func theDeviceStaysPausedWhileItIsWatched() async throws {
        let locked = Mutex(true), looked = TestSignal()
        let service = try service(locked: { locked.withLock { $0 } }, looked: looked)
        let watching = Task { try await service.run(["handoff", "Unlock the phone", "30", "--until", "unlocked", "--device", fixture.udid]) }
        await looked.wait()
        let refused = await #expect(throws: CommandFailure.self) { try await service.run(["tap", "0.5", "0.5", "--device", fixture.udid]) }
        #expect(refused?.code == .handoffPending && refused?.inputSent == CommandFailure.InputSent.none)
        locked.withLock { $0 = false }
        #expect(try result(try await watching.value)["status"] as? String == "observed")
    }

    @Test func cancellingTheCallEndsTheWatch() async throws {
        let looked = TestSignal()
        let service = try service(locked: { true }, looked: looked)
        let watching = Task { try await service.run(["handoff", "Unlock the phone", "30", "--until", "unlocked", "--device", fixture.udid]) }
        await looked.wait()
        watching.cancel()
        await #expect(throws: CancellationError.self) { try await watching.value }
        // The pause went with it.
        let dry = try await service.run(["handoff", "Again", "--until", "unlocked", "--device", fixture.udid], dryRun: true)
        #expect(String(decoding: dry.data, as: UTF8.self).contains("unlocked"))
    }

    @Test func conditionsAreCheckedBeforeAnyDeviceQuery() throws {
        func command(_ arguments: [String]) throws -> CommandRequest { try CLI.invocation(arguments).request }
        let udid = fixture.udid, simulator = fixture.uuid
        // Element conditions are wait's own, with its selector and index.
        guard case .handoff(let gone) = try command(["handoff", "Answer the prompt", "--until", "gone", "--label", "Allow", "--index", "2", "--device", udid]) else {
            Issue.record("Not a handoff"); return
        }
        #expect(gone.condition == .element(operation: "wait-label", operands: ["Allow", "--index", "2", "--until", "gone", "--timeout", "3"],
                                            until: "gone", by: "label", text: "Allow"))
        guard case .handoff(let value) = try command(["handoff", "Type it", "120", "--until", "value", "--id", "field", "--value", "ok", "--simulator", simulator]) else {
            Issue.record("Not a handoff"); return
        }
        #expect(value.timeoutSeconds == 120 && value.condition == .element(operation: "wait-id",
            operands: ["field", "--until", "value", "--value", "ok", "--timeout", "3"], until: "value", by: "identifier", text: "field"))
        // Without --until nothing changes: a person answers.
        guard case .handoff(let plain) = try command(["handoff", "Do it", "--device", udid]) else { Issue.record("Not a handoff"); return }
        #expect(plain.condition == nil)
        for arguments in [["handoff", "x", "--until", "sideways", "--device", udid],
                          ["handoff", "x", "--until", "gone", "--device", udid],
                          ["handoff", "x", "--until", "gone", "--id", "a", "--label", "b", "--device", udid],
                          ["handoff", "x", "--until", "unlocked", "--label", "Allow", "--device", udid],
                          ["handoff", "x", "--until", "unlocked", "--simulator", simulator],
                          ["handoff", "x", "--until", "paired", "--simulator", simulator],
                          ["handoff", "x", "--until", "value", "--id", "a", "--device", udid],
                          ["handoff", "x", "--until", "gone", "--label", "a", "--index", "0", "--device", udid],
                          ["handoff", "x", "--label", "Allow", "--device", udid]] {
            let failure = #expect(throws: CommandFailure.self) { try command(arguments) }
            #expect(failure?.code == .usage && failure?.inputSent == CommandFailure.InputSent.none)
        }
    }

    @Test func dryRunDescribesTheWatchAndQueriesNothing() async throws {
        let service = CommandService(readinessQuery: { _ in Issue.record("Dry run queried details"); return Data() },
                                     uiReadinessQuery: { _ in Issue.record("Dry run queried UI state"); return Data() })
        let plan = try result(try await service.run(["handoff", "Answer the prompt", "90", "--until", "gone", "--label", "Allow", "--device", fixture.udid], dryRun: true))
        #expect(plan["timeoutSeconds"] as? Int == 90 && (plan["until"] as? [String: Any])?["until"] as? String == "gone")
        #expect(((plan["until"] as? [String: Any])?["selector"] as? [String: String]) == ["by": "label", "text": "Allow"])
        #expect((plan["action"] as? String)?.contains("Nobody has to answer") == true)
    }

    @Test func mcpToolPassesTheConditionToTheSameParser() throws {
        let tool = try #require(MCPTools.definitions.first { $0.name == "request_handoff" })
        #expect(try tool.command(["platform": "physical", "device": .string(fixture.udid), "message": "Answer the prompt",
                                  "until": "gone", "by": "label", "text": "Allow", "index": 2, "timeout_seconds": 90])
            == ["handoff", "--device=\(fixture.udid)", "--until=gone", "--label=Allow", "--index=2", "--", "Answer the prompt", "90"])
        #expect(try tool.command(["platform": "physical", "device": .string(fixture.udid), "message": "Unlock", "until": "unlocked"])
            == ["handoff", "--device=\(fixture.udid)", "--until=unlocked", "--", "Unlock"])
        // Without until the call is what it was.
        #expect(try tool.command(["platform": "physical", "device": .string(fixture.udid), "message": "Do it"])
            == ["handoff", "--device=\(fixture.udid)", "--", "Do it"])
        #expect(tool.fields.first { $0.name == "until" }?.required == false)
    }
}
