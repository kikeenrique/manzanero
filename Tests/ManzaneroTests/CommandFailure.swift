import AppleDeviceBridge
import Darwin
import Foundation
import MCP
import Testing
@testable import Manzanero

/// Structured failures: classification at the source, text unchanged.
struct CommandFailureTests {
    private static let uuid = "6F1D2C3B-4A59-4E87-9C10-0A1B2C3D4E5F"
    private static let udid = "00008110-000A1B2C3D4E5F60"

    private func failure(_ body: () async throws -> Void) async -> (any Error)? {
        do { try await body(); return nil } catch { return error }
    }

    private func details(mode: String = "enabled") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success", "version": "651.32"], "result": [
            "identifier": Self.uuid,
            "properties": ["state": ["developerModeStatus": mode], "hardware": ["udid": Self.udid]]]])
    }

    private func json(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["error"] as? [String: Any])
    }

    // MARK: Model

    @Test func unclassifiedFailuresSayTheyAreUnclassified() {
        let failure = CommandFailure(description: "fixture")
        #expect(failure.description == "fixture")
        #expect(failure.code == .unclassified && failure.inputSent == .unknown)
        #expect(failure.retry == .afterInspection && failure.action == nil)
    }

    @Test func retryAndActionDefaultFromCodeAndInputSent() {
        #expect(CommandFailure.usage("x").retry == .no)
        #expect(CommandFailure.unsupported("x").retry == .no)
        let off = CommandFailure(.displayOff, "x", inputSent: .none)
        #expect(off.retry == .afterAction && off.action == .wake)
        #expect(CommandFailure(.deviceBusy, "x", inputSent: .none).action == .wait)
        #expect(CommandFailure(.handoffPending, "x", inputSent: .none).action == .wait)
        #expect(CommandFailure(.deviceNotReady, "x", inputSent: .none).action == .human)
        #expect(CommandFailure(.preconditionChanged, "x", inputSent: .none).retry == .safe)
        // Anything that may have reached the device needs inspection first.
        for code in CommandFailure.Code.allCases {
            #expect(CommandFailure(code, "x", inputSent: .possible).retry == .afterInspection)
            #expect(CommandFailure(code, "x", inputSent: .unknown).retry == .afterInspection)
        }
    }

    @Test func wrappingKeepsTheInnerClassificationAndUsesTheNewMessage() {
        let inner = CommandFailure(.displayOff, "inner", inputSent: .none)
        let outer = CommandFailure("outer: \(inner)", wrapping: inner)
        #expect(outer.description == "outer: inner" && outer.code == .displayOff && outer.action == .wake)
        #expect(CommandFailure("c", wrapping: CancellationError()).code == .cancelled)
        let foreign = CommandFailure("f", wrapping: POSIXError(.EIO))
        #expect(foreign.code == .unclassified && foreign.inputSent == .unknown)
        let quiet = CommandFailure(description: "u").noInputSent()
        #expect(quiet.code == .unclassified && quiet.inputSent == .none && quiet.retry == .safe)
        let sent = CommandFailure(.transportFailed, "t", inputSent: .none).inputPossiblySent()
        #expect(sent.inputSent == .possible && sent.retry == .afterInspection)
    }

    @Test func bridgeInputStatusSeparatesBeforeSendFromAttemptedInput() {
        let attempted = CommandFailure.inputDispatch(status: ADCInputOutcomeUnknown, message: "attempted")
        #expect(attempted.code == .inputOutcomeUnknown && attempted.inputSent == .possible && attempted.retry == .afterInspection)
        let before = CommandFailure.inputDispatch(status: 1, message: "before")
        #expect(before.code == .transportFailed && before.inputSent == .none && before.retry == .safe)
        #expect(attempted.description == "attempted" && before.description == "before")
    }

    // MARK: CLI output

    @Test func textFormatIsTheExistingOutput() {
        let errors: [any Error] = [CommandFailure.usage("Unknown command. Run manzanero --help."),
                                   CommandFailure(description: "plain"), POSIXError(.ENOENT), CancellationError()]
        for error in errors {
            #expect(ErrorFormat.text.render(error) == Data("\(error)\n".utf8))
        }
    }

    @Test func jsonFormatIsOneObjectOnOneLine() throws {
        let data = ErrorFormat.json.render(CommandFailure(.displayOff, "Primary display is off. \"Quoted\" a/b", inputSent: .none))
        #expect(data.last == 10 && data.dropLast().contains(10) == false)
        let error = try json(data)
        #expect(error["code"] as? String == "display-off")
        #expect(error["message"] as? String == "Primary display is off. \"Quoted\" a/b")
        #expect(error["inputSent"] as? String == "none" && error["retry"] as? String == "after-action")
        #expect(error["action"] as? String == "wake")
        let usage = try json(ErrorFormat.json.render(CommandFailure.usage("u")))
        #expect(usage["action"] is NSNull && Set(usage.keys) == ["code", "message", "inputSent", "retry", "action"])
        let posix: any Error = POSIXError(.ENOENT)
        let foreign = try json(ErrorFormat.json.render(posix))
        #expect(foreign["code"] as? String == "unclassified" && foreign["inputSent"] as? String == "unknown")
        #expect(foreign["message"] as? String == "\(posix)")
        #expect(try json(ErrorFormat.json.render(CancellationError()))["code"] as? String == "cancelled")
    }

    @Test func formatSelectionPrefersTheOptionOverTheEnvironment() throws {
        #expect(try ErrorFormat.select(nil, environment: [:]) == .text)
        #expect(try ErrorFormat.select(.json, environment: [:]) == .json)
        #expect(try ErrorFormat.select(nil, environment: ["MANZANERO_ERROR_FORMAT": "json"]) == .json)
        #expect(try ErrorFormat.select(nil, environment: ["MANZANERO_ERROR_FORMAT": ""]) == .text)
        #expect(try ErrorFormat.select(.text, environment: ["MANZANERO_ERROR_FORMAT": "json"]) == .text)
        #expect(throws: CommandFailure.self) { try ErrorFormat.select(nil, environment: ["MANZANERO_ERROR_FORMAT": "yaml"]) }
    }

    /// A parse failure leaves no parsed option, so the raw arguments are scanned.
    @Test func formatScanFindsTheOptionAnywhereBeforeTheTerminator() throws {
        #expect(try ErrorFormat.scan(["tap", "0.5", "0.5", "--device", "U"], environment: [:]) == .text)
        #expect(try ErrorFormat.scan(["--error-format", "json", "tap", "--device", "U"], environment: [:]) == .json)
        #expect(try ErrorFormat.scan(["tap", "--device", "U", "--error-format=json"], environment: [:]) == .json)
        #expect(try ErrorFormat.scan(["doctor", "--error-format", "text"], environment: ["MANZANERO_ERROR_FORMAT": "json"]) == .text)
        #expect(try ErrorFormat.scan(["type", "--device", "U", "--", "--error-format", "json"], environment: [:]) == .text)
        for (arguments, environment) in [(["--error-format"], [String: String]()), (["doctor", "--error-format", "xml"], [:]),
                                         (["doctor"], ["MANZANERO_ERROR_FORMAT": "yaml"])] {
            #expect(throws: CommandFailure.self) { try ErrorFormat.scan(arguments, environment: environment) }
        }
    }

    // MARK: MCP

    @Test func mcpErrorsCarryStructuredContentBesideTheText() async throws {
        let result = try await MCPTools.call(name: "tap", arguments: ["platform": "physical", "device": "fixture", "x": 0.5, "y": 0.5]) { _ in
            throw CommandFailure(.deviceBusy, "Device is controlled by another manzanero process. Wait for it to finish or stop it; no input sent.", inputSent: .none)
        }
        #expect(result.isError == true)
        guard case .text(let message, _, _) = result.content.first else { Issue.record("Missing text content"); return }
        #expect(message == "Device is controlled by another manzanero process. Wait for it to finish or stop it; no input sent.")
        let error = try #require(result.structuredContent?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("device-busy") && error["inputSent"] == .string("none"))
        #expect(error["retry"] == .string("after-action") && error["action"] == .string("wait"))
        #expect(error["message"] == .string(message))
        let unclassified = try await MCPTools.call(name: "list_devices", arguments: ["platform": "simulator"]) { _ in
            throw CommandFailure(description: "fixture unavailable")
        }
        let fields = try #require(unclassified.structuredContent?.objectValue?["error"]?.objectValue)
        #expect(fields["code"] == .string("unclassified") && fields["action"] == .null)
    }

    // MARK: Tagged sites, with the exact existing text

    @Test(arguments: [
        (["frobnicate"], "Unknown command. Run manzanero --help.", "usage"),
        (["physical", "U", "tap", "2", "0.5"], "Physical input coordinates must be normalized numbers from 0 to 1.", "usage"),
        (["physical", "U", "button", "power"], "Supported physical buttons: home, lock, volume-up, volume-down.", "usage"),
        (["simulator", "U", "tap", "0.5", "0.5"], "Simulator tap requires the simulator's UUID (see devices --simulators); names and 'booted' are not accepted.", "usage"),
        (["simulator", "11111111-2222-3333-4444-555555555555", "wake"], "Simulator wake is not implemented yet; simulator input covers touch with one to five contacts, gesture sequences, button, key and type. Wake remains physical-only. No input sent.", "unsupported-operation"),
        (["physical", "U", "frobnicate"], "Unsupported physical-device operation: frobnicate.", "unsupported-operation"),
        (["--physical-backend", "helper", "physical", "U", "tap", "0.5", "0.5"], "Unsupported physical backend: helper. coredevice is the only physical backend and the default; --physical-backend may be omitted.", "unsupported-operation"),
        (["physical", "U", "wait-id", "sel", "--timeout", "99"], "--timeout must be a number of seconds in 0...60. Native AX wait usage: wait (--id <identifier> | --label <label>) [--pid <positive-pid>] [--until visible|gone|enabled|disabled|value] [--value <exact-text>] [--timeout <seconds 0...60, default 10>] [--interval <seconds 0.25...5, default 0.5>].", "usage"),
        (["physical", "U", "gesture", #"{"frames":[{"ms":0,"touches":[]}]}"#], "Gesture requires 2...512 frames, starting at ms=0 with a touch and ending with touches:[].", "usage"),
    ])
    func parseFailuresKeepTheirTextAndSayNothingWasSent(_ args: [String], _ message: String, _ code: String) async throws {
        // Parsing fails before any device query, so these run without a dry run.
        let error = try #require(await failure { _ = try await CommandService().execute(args) } as? CommandFailure)
        #expect(error.description == message)
        #expect(error.code.rawValue == code && error.inputSent == .none && error.retry == .no)
    }

    @Test func developerModeAndLeaseFailuresKeepTheirTextAndSayNothingWasSent() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/failure-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disabled = try details(mode: "disabled")
        let blocked = try #require(await failure {
            _ = try await CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in disabled })
                .execute(["physical", Self.uuid, "tap", "0.5", "0.5"])
        } as? CommandFailure)
        #expect(blocked.description.hasPrefix("Cannot tap: Developer Mode is disabled. On the iPhone, open Settings"))
        #expect(blocked.code == .deviceNotReady && blocked.inputSent == .none && blocked.action == .human)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = open(directory.appendingPathComponent("\(Self.uuid).lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
        defer { _ = close(owner) }
        let enabled = try details()
        let busy = try #require(await failure {
            _ = try await CommandService(leases: DeviceLeaseRegistry(directory: directory), readinessQuery: { _ in enabled })
                .execute(["physical", Self.uuid, "tap", "0.5", "0.5"])
        } as? CommandFailure)
        #expect(busy.description.hasPrefix("Device is controlled by another manzanero process"))
        #expect(busy.description.hasSuffix("Wait for it to finish or stop it; no input sent."))
        #expect(busy.code == .deviceBusy && busy.inputSent == .none && busy.retry == .afterAction && busy.action == .wait)
    }

    @Test func unclassifiedReadinessFailuresBeforeInputSayNothingWasSent() async throws {
        let service = CommandService(readinessQuery: { _ in throw CommandFailure(description: "fixture details unavailable") })
        for args in [["physical", Self.uuid, "tap", "0.5", "0.5"], ["physical", Self.uuid, "tree"]] {
            let error = try #require(await failure { _ = try await service.execute(args) } as? CommandFailure)
            #expect(error.description == "fixture details unavailable")
            #expect(error.code == .unclassified && error.inputSent == .none)
        }
    }

    @Test func readOnlyCommandsAreRecognisedAndMutationsAreNot() {
        for args in [["physical", "U", "tree"], ["physical", "U", "wait-id", "x"], ["physical", "U", "screen"], ["physical", "U", "details"],
                     ["simulator", "U", "apps"], ["physical", "U", "media-status"], ["--physical-backend", "coredevice", "physical", "U", "tree"],
                     ["doctor"], ["ocr", "x.png"], ["devices", "physical"], ["decode-ax-archive", "x"]] {
            #expect(CommandService.isReadOnly(args), "\(args)")
        }
        for args in [["physical", "U", "tap", "0.5", "0.5"], ["physical", "U", "launch", "a.b"], ["physical", "U", "wake"],
                     ["physical", "U", "press-id", "x"], ["physical", "U", "push", "a", "b", "c"], ["simulator", "U", "boot"],
                     ["physical", "U", "record", "a.mp4", "5"], ["physical", "U", "handoff", "m"]] {
            #expect(!CommandService.isReadOnly(args), "\(args)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func handoffPauseIsClassified() async throws {
        let device = "11111111-2222-3333-4444-555555555555"
        let service = CommandService(), gate = HandoffCommandTests.Gate()
        let pending = Task { try await service.execute(["simulator", device, "handoff", "fixture"], handoffConfirmation: { _ in await gate.wait() }) }
        try #require(await gate.entered.wait())
        let paused = try #require(await failure { _ = try await service.execute(["simulator", device, "type", "hello"]) } as? CommandFailure)
        #expect(paused.description == "Automation is paused for this device while human handoff is pending. Wait for the person's response.")
        #expect(paused.code == .handoffPending && paused.inputSent == .none && paused.action == .wait)
        let duplicate = try #require(await failure {
            _ = try await service.execute(["simulator", device, "handoff", "again"], handoffConfirmation: { _ in .acknowledged })
        } as? CommandFailure)
        #expect(duplicate.description == "A handoff is already pending for this device." && duplicate.code == .handoffPending)
        await gate.finish()
        _ = try await pending.value
    }

    @Test func displayOffGuardsKeepTheirTextAndAskForAWake() throws {
        let touchDisplay: [String: Any] = ["primary": true, "type": ["integrated": [:]], "displayId": 1,
            "bounds": [[0, 0], [1125, 2436]], "pointScale": 3, "nativeOrientation": "rot0",
            "currentOrientation": "rot0", "backlightState": "off"]
        let data = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["displays": [touchDisplay]]])
        do { _ = try DirectTouchDisplay(data); Issue.record("Display off was accepted") } catch let error as CommandFailure {
            #expect(error.description == "Primary display is off. Wake and unlock the selected device, then try again; no touch or capture started.")
            #expect(error.code == .displayOff && error.inputSent == .none && error.action == .wake)
        }
        do { _ = try AccessibilityDisplay(AccessibilityDisplayTests.data(backlight: "off")); Issue.record("Display off was accepted") } catch let error as CommandFailure {
            #expect(error.description == "Primary display is off or its awake state is unknown. Wake/unlock the selected device before foreground AX inspection; no point query sent.")
            #expect(error.code == .displayOff && error.retry == .afterAction)
        }
    }

    @Test func displayChangeBeforeTouchIsAPreconditionChange() throws {
        let input = try CoreDeviceInputTests().input(["tap", "0.5", "0.5"])
        var calls = 0
        do {
            _ = try DirectPhysicalTouch.execute(input, query: { plan in
                calls += 1
                if plan.arguments.contains("details") { return try DirectPhysicalInputTests().details() }
                return try DirectPhysicalTouchTests().display(rotation: calls == 2 ? "rot0" : "rot90")
            }, send: { _, _, _ in Issue.record("Changed display dispatched input") })
            Issue.record("Changed display was accepted")
        } catch let error as CommandFailure {
            #expect(error.description == "Display changed before touch dispatch; no input sent.")
            #expect(error.code == .preconditionChanged && error.inputSent == .none && error.retry == .safe)
        }
    }

    @Test(arguments: [("ambiguous", CommandFailure.Code.targetUnresolved, CommandFailure.InputSent.none),
                      ("offscreen", .targetUnresolved, .none), ("display", .preconditionChanged, .none),
                      ("refused", .inputOutcomeUnknown, .possible), ("lost", .inputOutcomeUnknown, .possible)])
    func accessibilityActionFailuresFollowTheSubmissionState(_ fixture: String, _ code: CommandFailure.Code, _ sent: CommandFailure.InputSent) throws {
        let wire = DirectAccessibilityActionTests.Wire(fixture)
        let press = try DirectAccessibilityAction(.init(device: "fixture", operation: "press-id", operands: ["42", "fixture.control"]))
        var displays = 0
        do {
            _ = try press.execute(session: AccessibilitySession(transport: wire), display: {
                displays += 1
                return try AccessibilityDisplay(AccessibilityDisplayTests.data(scale: fixture == "display" && displays == 2 ? 2 : 3))
            })
            Issue.record("Guard failed open")
        } catch let error as CommandFailure {
            #expect(error.description.contains(" AX press state="))
            #expect(error.code == code && error.inputSent == sent)
            #expect(error.retry == (sent == .none ? .safe : .afterInspection))
        }
    }

    @Test func pasteFailureAfterTheClipboardChangedIsAnUnknownOutcome() throws {
        let input = try CoreDeviceInputTests().input(["paste", "hello"])
        let copied = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"]])
        do {
            _ = try DirectPhysicalPaste.execute(input, query: { _ in try DirectPhysicalInputTests().details() },
                copy: { _, _ in copied }, send: { _ in throw CommandFailure.inputDispatch(status: 1, message: "fixture before input") })
            Issue.record("Failed paste succeeded")
        } catch let error as CommandFailure {
            #expect(error.description == "Clipboard was replaced, but paste dispatch failed or was cancelled; insertion and key release are unknown. Inspect the focused field before retrying; no automatic replay. fixture before input")
            #expect(error.code == .inputOutcomeUnknown && error.inputSent == .possible && error.retry == .afterInspection)
        }
        do {
            _ = try DirectPhysicalPaste.execute(input, query: { _ in try DirectPhysicalInputTests().details() },
                copy: { _, _ in throw CommandFailure(.toolFailed, "devicectl failed (1): fixture", inputSent: .unknown) },
                send: { _ in Issue.record("Paste keys sent after a failed clipboard write") })
            Issue.record("Failed clipboard write succeeded")
        } catch let error as CommandFailure {
            #expect(error.code == .toolFailed && error.inputSent == .possible && error.retry == .safe)
        }
    }

    @Test(.timeLimit(.minutes(1))) func toolExitsAndTimeoutsAreClassified() throws {
        do { _ = try ToolRunner().run([], executable: "/usr/bin/false"); Issue.record("false succeeded") } catch let error as CommandFailure {
            #expect(error.description == "false failed (1): ")
            #expect(error.code == .toolFailed && error.inputSent == .unknown && error.retry == .afterInspection)
        }
        do { _ = try ToolRunner().run(["5"], executable: "/bin/sleep", timeout: 0.1); Issue.record("sleep finished") } catch let error as CommandFailure {
            #expect(error.description == "sleep timed out; inspect device state before retrying an action.")
            #expect(error.code == .timeout && error.inputSent == .unknown)
        }
    }

    @Test func signingFailuresFromTheBuildLogAreClassified() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/failure-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try #require(try BuildRunCommand.parse(["physical", Self.udid, "build-run", "App.xcodeproj", "App"]))
        let settings = try JSONSerialization.data(withJSONObject: [["target": "App", "buildSettings": [
            "PRODUCT_TYPE": "com.apple.product-type.application", "TARGET_BUILD_DIR": "/tmp/fixture", "FULL_PRODUCT_NAME": "App.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app", "PLATFORM_NAME": "iphoneos"]]])
        for (log, code) in [("error: Signing for \"App\" requires a development team.", CommandFailure.Code.signingFailed),
                            ("xcodebuild: error: Unable to find a destination matching the provided destination specifier", .toolFailed)] {
            do {
                _ = try command.execute(directory: directory, run: { _ in settings }, build: { _, url in
                    try Data(log.utf8).write(to: url)
                    throw CommandFailure(.toolFailed, "Xcode build failed (65); raw build log: \(url.path)", inputSent: .none)
                })
                Issue.record("Failed build succeeded")
            } catch let error as CommandFailure {
                #expect(error.description.contains("Xcode build failed (65); raw build log:") && error.description.contains("Likely cause:"))
                #expect(error.code == code && error.inputSent == .none)
            }
        }
    }

    @Test func nativeRecordingWithoutVideoNamesTheFirewall() {
        let inner = CommandFailure(.timeout, "Native recording exceeded its twelve-second first-frame budget.", inputSent: .none)
        let firewall = CommandFailure.nativeRecording("detail", wrapping: inner, firewallDropsVideo: true)
        #expect(firewall.description == "detail" && firewall.code == .hostRequirement)
        #expect(firewall.retry == .afterAction && firewall.action == .allowFirewall)
        let plain = CommandFailure.nativeRecording("detail", wrapping: inner, firewallDropsVideo: false)
        #expect(plain.code == .timeout && plain.inputSent == .none && plain.action == nil)
    }
}
