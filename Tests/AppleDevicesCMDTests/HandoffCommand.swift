import Foundation
import MCP
import Testing
@testable import AppleDevicesCMD

struct HandoffCommandTests {
    let device = "11111111-2222-3333-4444-555555555555"
    func request() throws -> HandoffCommand {
        try #require(try HandoffCommand.parse(["simulator", device, "handoff", "Complete the step on the device"]))
    }

    @Test func validatesExplicitTargetAndTerminalLimits() throws {
        let parsed = try request()
        #expect(parsed.timeoutSeconds == 300)
        #expect(parsed.target.identifier == device)
        for args in [
            ["simulator", "booted", "handoff", "message"],
            ["simulator", device, "handoff", ""],
            ["simulator", device, "handoff", "\u{1b}[2J"],
            ["simulator", device, "handoff", "message", "0"],
            ["simulator", device, "handoff", "message", "3601"],
            ["physical", "device-name", "handoff", "message"],
            ["physical", device, "handoff", "message"]
        ] { #expect(throws: CommandFailure.self) { try HandoffCommand.parse(args) } }
    }

    @Test(arguments: [("done\n", HandoffStatus.acknowledged), ("decline\n", .declined), ("cancel\n", .cancelled), ("\n", .cancelled), ("yes\n", .cancelled), (String(repeating: "x", count: 128) + "\n", .notCompleted)])
    func terminalRequiresExplicitCompletion(_ input: String, _ expected: HandoffStatus) throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try pipe.fileHandleForWriting.close()
        let status = try TerminalHandoff.confirm(request(), input: pipe.fileHandleForReading.fileDescriptor, requireTTY: false, prompt: { _ in })
        #expect(status == expected)
    }

    @Test func terminalTimeoutAndNonTTYDoNotAcknowledge() throws {
        let pipe = Pipe()
        let status = try TerminalHandoff.confirm(request(), input: pipe.fileHandleForReading.fileDescriptor, requireTTY: false, timeout: .milliseconds(10), prompt: { _ in })
        #expect(status == .timedOut)
        #expect(throws: CommandFailure.self) { try TerminalHandoff.confirm(request(), input: pipe.fileHandleForReading.fileDescriptor, prompt: { _ in }) }
    }

    @Test func formAcceptWithoutExactlyOneCompletedBooleanDoesNotAcknowledge() {
        #expect(MCPHandoffChannel.status(.init(action: .accept, content: ["completed": true])) == .acknowledged)
        for content: [String: Value]? in [nil, [:], ["completed": false], ["completed": "true"], ["completed": true, "other": "x"]] {
            #expect(MCPHandoffChannel.status(.init(action: .accept, content: content)) == .notCompleted)
        }
        #expect(MCPHandoffChannel.status(.init(action: .decline)) == .declined)
        #expect(MCPHandoffChannel.status(.init(action: .cancel)) == .cancelled)
    }

    actor Gate {
        var waiting = false
        var continuation: CheckedContinuation<HandoffStatus, Never>?
        func wait() async -> HandoffStatus {
            await withCheckedContinuation { continuation in self.continuation = continuation; waiting = true }
        }
        func finish() { continuation?.resume(returning: .acknowledged); continuation = nil }
    }

    @Test(.timeLimit(.minutes(1))) func pendingHandoffPausesMutationsAndUnpausesAfterResponse() async throws {
        let service = CommandService(), gate = Gate()
        let pending = Task { try await service.execute(["simulator", device, "handoff", "fixture"], handoffConfirmation: { _ in await gate.wait() }) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.waiting), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.waiting)
        do {
            _ = try await service.execute(["simulator", device, "type", "hello"])
            Issue.record("Device mutation was not paused")
        } catch { #expect(String(describing: error).contains("Automation is paused")) }
        do {
            _ = try await service.execute(["simulator", "booted", "shutdown"])
            Issue.record("Alias bypassed pending handoff")
        } catch { #expect(String(describing: error).contains("explicit device ID")) }
        do {
            _ = try await service.execute(["simulator", device, "handoff", "duplicate"], handoffConfirmation: { _ in Issue.record("Duplicate prompted"); return .acknowledged })
            Issue.record("Duplicate handoff was accepted")
        } catch { #expect(String(describing: error).contains("already pending")) }
        await gate.finish()
        #expect(try await pending.value.exitCode == 0)
        do {
            _ = try await service.execute(["simulator", device, "tap", "nan", "0"])
            Issue.record("Invalid tap was accepted")
        } catch { #expect(!String(describing: error).contains("paused")) }
    }

    @Test func acknowledgementIsNotADeviceVerificationClaim() throws {
        let output = try request().output(.acknowledged, mechanism: "test")
        let json = try #require(try JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(output.exitCode == 0)
        #expect(json["humanAcknowledged"] as? Bool == true)
        #expect(json["verified"] as? Bool == false)
        #expect(try request().output(.declined, mechanism: "test").exitCode == 1)
    }

    @Test func pendingPhysicalHandoffAllowsReadinessButRejectsCoreDeviceAliasMutation() async throws {
        let metadata = Data("{\"info\":{\"outcome\":\"success\"},\"result\":{\"properties\":{\"state\":{\"developerModeStatus\":{\"enabled\":{}}},\"connection\":{\"state\":\"connected\",\"pairingState\":\"paired\"}},\"deviceProperties\":{\"ddiServicesAvailable\":true}}}".utf8)
        let service = CommandService(readinessQuery: { _ in metadata }), gate = Gate()
        let udid = "00000000-0000000000000000"
        let pending = Task { try await service.execute(["physical", udid, "handoff", "synthetic"], handoffConfirmation: { _ in await gate.wait() }) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.waiting), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.waiting)
        do {
            let observation = try await service.execute(["physical", udid, "readiness"])
            #expect(observation.exitCode == 0)
            do {
                _ = try await service.execute(["physical", device, "terminate", "123"])
                Issue.record("CoreDevice alias bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("physical hardware UDID")) }
            for operands in [["gesture", NativeGestureSequenceTests().doubleTap], ["type", "synthetic"], ["paste", "synthetic"], ["key", "backspace"], ["pinch", "0.5", "0.5", "0.5", "1", "1"], ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "0"], ["press-id", "123", "fixture.button"], ["press-label", "123", "Button"], ["scroll-id", "fixture.row"], ["scroll-label", "123", "Row"]] {
                do {
                    _ = try await service.execute(["physical", udid] + operands)
                    Issue.record("Physical action bypassed handoff pause")
                } catch { #expect(String(describing: error).contains("Automation is paused")) }
            }
            do {
                _ = try await service.execute(["--recording-backend", "coredevice", "physical", udid, "record", "tmp/paused.mp4", "1"])
                Issue.record("Native recording bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.execute(["--physical-backend", "coredevice", "physical", udid, "button", "home"])
                Issue.record("Native backend bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.execute(["--physical-backend", "coredevice", "physical", udid, "long-press", "0.5", "0.5", "0.8"])
                Issue.record("Native long-press bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.execute(["--physical-backend", "coredevice", "physical", udid, "gesture", NativeGestureSequenceTests().doubleTap])
                Issue.record("Native gesture bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.execute(["--physical-backend", "coredevice", "physical", udid, "paste", "synthetic"])
                Issue.record("Native paste bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
        } catch {
            await gate.finish(); _ = try await pending.value; throw error
        }
        await gate.finish()
        #expect(try await pending.value.exitCode == 0)
    }

    @Test(arguments: [true, false]) func sdkFormRoundTripRespectsCompletedBoolean(_ completed: Bool) async throws {
        let session = await AppleMCPServer.make(service: CommandService())
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "handoff-test", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { params in
            guard case .form(let form) = params else { throw CommandFailure(description: "Expected form mode") }
            #expect(form.requestedSchema.required == ["completed"])
            #expect(form.requestedSchema.properties.count == 1)
            #expect(form.requestedSchema.properties["completed"]?.objectValue?["type"] == "boolean")
            return .init(action: .accept, content: ["completed": .bool(completed)])
        }
        try await session.start(transport: serverTransport)
        do {
            _ = try await client.connect(transport: clientTransport)
            let (_, isError) = try await client.callTool(name: "request_handoff", arguments: ["platform": "simulator", "device": .string(device), "message": "Synthetic device step"])
            #expect(isError == !completed)
        } catch {
            await client.disconnect(); await session.stop(); throw error
        }
        await client.disconnect(); await session.stop()
    }

    @Test(arguments: [false, true]) func unsupportedOrURLOnlyHostsNeverReceiveAForm(_ urlOnly: Bool) async throws {
        let session = await AppleMCPServer.make(service: CommandService())
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "unsupported-handoff-test", version: "1", capabilities: .init(elicitation: urlOnly ? .init(form: nil, url: .init()) : nil))
        await client.withElicitationHandler { _ in Issue.record("Unsupported host received a form"); return .init(action: .cancel) }
        try await session.start(transport: serverTransport)
        do {
            _ = try await client.connect(transport: clientTransport)
            let (_, isError) = try await client.callTool(name: "request_handoff", arguments: ["platform": "simulator", "device": .string(device), "message": "Synthetic step"])
            #expect(isError == true)
        } catch {
            await client.disconnect(); await session.stop(); throw error
        }
        await client.disconnect(); await session.stop()
    }
}
