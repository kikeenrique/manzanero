import Foundation
import MCP
import Testing
@testable import Manzanero

struct HandoffCommandTests {
    let device = "11111111-2222-3333-4444-555555555555"
    func request() throws -> HandoffCommand {
        try HandoffCommand(platform: "simulator", device: device, message: "Complete the step on the device", timeout: nil)
    }

    @Test func validatesExplicitTargetAndTerminalLimits() throws {
        let parsed = try request()
        #expect(parsed.timeoutSeconds == 300)
        #expect(parsed.target.identifier == device)
        for (platform, target, message, timeout) in [
            ("simulator", "booted", "message", nil),
            ("simulator", device, "", nil),
            ("simulator", device, "\u{1b}[2J", nil),
            ("simulator", device, "message", "0"),
            ("simulator", device, "message", "3601"),
            ("physical", "device-name", "message", nil),
            ("physical", device, "message", nil)
        ] as [(String, String, String, String?)] {
            #expect(throws: CommandFailure.self) { try HandoffCommand(platform: platform, device: target, message: message, timeout: timeout) }
        }
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

    @Test func theHostsOwnButtonsAreTheAnswer() throws {
        // The form has no fields: Accept is done, Decline and Cancel are not.
        #expect(MCPHandoffChannel.schema.properties.isEmpty && MCPHandoffChannel.schema.required == [])
        for content: [String: Value]? in [nil, [:]] {
            #expect(MCPHandoffChannel.status(.init(action: .accept, content: content)) == .acknowledged)
        }
        #expect(MCPHandoffChannel.status(.init(action: .decline)) == .declined)
        #expect(MCPHandoffChannel.status(.init(action: .cancel)) == .cancelled)
        // An accepted answer carrying fields nobody asked for is not an acknowledgement.
        for content: [String: Value] in [["completed": false], ["completed": true], ["outcome": "done"]] {
            #expect(MCPHandoffChannel.status(.init(action: .accept, content: content)) == .notCompleted)
        }
        // The form asks its own question, whether the step is finished, and says what
        // each of the host's buttons means for it: a device prompt's own Allow / Don't
        // Allow must not be read into Accept / Decline.
        // Three lines, no blank ones, the button meanings first: one host shows only
        // the first three lines of a form's message. A step given on several lines
        // is joined into one.
        let command = try HandoffCommand(platform: "physical", device: "00008110-000A11112222801E", message: "Answer the notification prompt\non the phone", timeout: nil)
        #expect(MCPHandoffChannel.message(command) == """
            Accept = step finished (any choice on the device). Decline = not done.
            Step: Answer the notification prompt on the phone
            Device: physical 00008110-000A11112222801E
            """)
        #expect(MCPHandoffChannel.message(command).split(separator: "\n", omittingEmptySubsequences: false).count == 3)
        // The description names fields and types, and no text a person typed.
        let unticked = MCPHandoffChannel.describe(.init(action: .accept, content: ["completed": false]))
        #expect(unticked.hasPrefix("Form answer from the host: action accept; completed=false (boolean)."))
        let text = MCPHandoffChannel.describe(.init(action: .accept, content: ["outcome": "secret words"]))
        #expect(text.contains("outcome (string, 12 bytes)") && !text.contains("secret"))
        #expect(MCPHandoffChannel.describe(.init(action: .accept, content: [:])).contains("empty content"))
        #expect(MCPHandoffChannel.describe(.init(action: .decline)).contains("action decline; no content"))
    }

    actor Gate {
        var waiting = false
        var continuation: CheckedContinuation<HandoffStatus, Never>?
        /// Signalled once the confirmation is parked, so tests wait without polling.
        nonisolated let entered = TestSignal()
        func wait() async -> HandoffStatus {
            await withCheckedContinuation { continuation in
                self.continuation = continuation; waiting = true
                entered.signal()
            }
        }
        func finish() { continuation?.resume(returning: .acknowledged); continuation = nil }
    }

    @Test(.timeLimit(.minutes(1))) func pendingHandoffPausesMutationsAndUnpausesAfterResponse() async throws {
        let service = CommandService(), gate = Gate()
        let pending = Task { try await service.run(["handoff", "fixture", "--simulator", device], handoffConfirmation: { _ in await gate.wait() }) }
        try #require(await gate.entered.wait())
        try #require(await gate.waiting)
        do {
            _ = try await service.run(["type", "hello", "--simulator", device])
            Issue.record("Device mutation was not paused")
        } catch { #expect(String(describing: error).contains("Automation is paused")) }
        do {
            _ = try await service.run(["shutdown", "--simulator", "booted"])
            Issue.record("Alias bypassed pending handoff")
        } catch { #expect(String(describing: error).contains("explicit device ID")) }
        do {
            _ = try await service.run(["handoff", "duplicate", "--simulator", device], handoffConfirmation: { _ in Issue.record("Duplicate prompted"); return .acknowledged })
            Issue.record("Duplicate handoff was accepted")
        } catch { #expect(String(describing: error).contains("already pending")) }
        await gate.finish()
        #expect(try await pending.value.exitCode == 0)
        do {
            _ = try await service.run(["tap", "nan", "0", "--simulator", device])
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

    @Test(.timeLimit(.minutes(1))) func pendingPhysicalHandoffAllowsReadinessButRejectsCoreDeviceAliasMutation() async throws {
        let metadata = Data("{\"info\":{\"outcome\":\"success\"},\"result\":{\"properties\":{\"state\":{\"developerModeStatus\":{\"enabled\":{}}},\"connection\":{\"state\":\"connected\",\"pairingState\":\"paired\"}},\"deviceProperties\":{\"ddiServicesAvailable\":true}}}".utf8)
        let service = CommandService(readinessQuery: { _ in metadata }), gate = Gate()
        let udid = "00000000-0000000000000000"
        let pending = Task { try await service.run(["handoff", "synthetic", "--device", udid], handoffConfirmation: { _ in await gate.wait() }) }
        try #require(await gate.entered.wait())
        try #require(await gate.waiting)
        do {
            for command in [["multi-tap", "0.25", "0.25", "0.75", "0.25"],
                            ["multi-drag", "1"] + Array(repeating: "0.5", count: 12)] {
                do {
                    _ = try await service.run(command + ["--device", udid])
                    Issue.record("Standalone multitouch bypassed handoff pause")
                } catch { #expect(String(describing: error).contains("Automation is paused")) }
            }
            let observation = try await service.run(["readiness", "--device", udid])
            #expect(observation.exitCode == 0)
            // An AX wait is an observation like a tree: it proceeds (and here
            // stops at the fixture's missing identity) instead of pausing.
            for command in [["tree"], ["wait", "--id", "fixture.button", "--until", "gone"], ["wait", "--label", "Button", "--pid", "123"]] {
                do {
                    _ = try await service.run(command + ["--device", udid])
                    Issue.record("Fixture details unexpectedly reached a device connection")
                } catch { #expect(!String(describing: error).contains("paused")) }
            }
            do {
                _ = try await service.run(["terminate", "123", "--device", device])
                Issue.record("CoreDevice alias bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("physical hardware UDID")) }
            for command in [["gesture", NativeGestureSequenceTests().doubleTap], ["type", "synthetic"], ["paste", "synthetic"], ["key", "backspace"],
                            ["pinch", "0.5", "0.5", "0.5", "1", "1"], ["multi-drag", "1", "0", "0", "1", "1", "1", "1", "0", "0"],
                            ["press", "--id", "fixture.button", "--pid", "123"], ["press", "--label", "Button", "--pid", "123"],
                            ["scroll", "--id", "fixture.row"], ["scroll", "--label", "Row", "--pid", "123"]] {
                do {
                    _ = try await service.run(command + ["--device", udid])
                    Issue.record("Physical action bypassed handoff pause")
                } catch { #expect(String(describing: error).contains("Automation is paused")) }
            }
            do {
                _ = try await service.run(["record", "tmp/paused.mp4", "1", "--backend", "coredevice", "--device", udid])
                Issue.record("Native recording bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.run(["button", "home", "--device", udid])
                Issue.record("Native backend bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.run(["long-press", "0.5", "0.5", "0.8", "--device", udid])
                Issue.record("Native long-press bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.run(["gesture", NativeGestureSequenceTests().doubleTap, "--device", udid])
                Issue.record("Native gesture bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
            do {
                _ = try await service.run(["paste", "synthetic", "--device", udid])
                Issue.record("Native paste bypassed handoff pause")
            } catch { #expect(String(describing: error).contains("Automation is paused")) }
        } catch {
            await gate.finish(); _ = try await pending.value; throw error
        }
        await gate.finish()
        #expect(try await pending.value.exitCode == 0)
    }

    @Test(arguments: [true, false]) func sdkFormRoundTripRespectsTheButton(_ completed: Bool) async throws {
        let session = await AppleMCPServer.make(service: CommandService())
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "handoff-test", version: "1", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { params in
            guard case .form(let form) = params else { throw CommandFailure(description: "Expected form mode") }
            #expect(form.requestedSchema.properties.isEmpty)
            #expect(form.message.hasPrefix("Accept = step finished (any choice on the device). Decline = not done.\nStep: "))
            return .init(action: completed ? .accept : .decline)
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
