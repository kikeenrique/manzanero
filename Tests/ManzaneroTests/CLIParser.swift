import Foundation
import Testing
@testable import Manzanero

struct CLIParserTests {
    static let device = "00008110-000A11112222801E"
    static let simulator = "11111111-2222-3333-4444-555555555555"

    private func invocation(_ arguments: [String], environment: [String: String] = [:]) throws -> CLIInvocation {
        guard case .run(let invocation) = try CLI.parse(arguments, environment: environment) else {
            throw CommandFailure(.internal, "not an operation", inputSent: .none)
        }
        return invocation
    }

    private func usageFailure(_ arguments: [String], environment: [String: String] = [:]) throws -> CommandFailure {
        try #require(throws: CommandFailure.self) { try CLI.parse(arguments, environment: environment) }
    }

    /// Every command's documented forms, and what the command service runs.
    static let forms: [([String], [String])] = [
        (["tap", "0.5", "0.45", "--device", device], ["physical", device, "tap", "0.5", "0.45"]),
        (["tap", "--simulator", simulator, "0.5", "0.45"], ["simulator", simulator, "tap", "0.5", "0.45"]),
        (["long-press", "0.5", "0.5", "1.2", "--device", device], ["physical", device, "long-press", "0.5", "0.5", "1.2"]),
        (["swipe", "0.5", "0.8", "0.5", "0.2", "0.3", "--simulator", simulator], ["simulator", simulator, "swipe", "0.5", "0.8", "0.5", "0.2", "0.3"]),
        (["drag", "0.5", "0.8", "0.5", "0.2", "0.3", "--device", device], ["physical", device, "drag", "0.5", "0.8", "0.5", "0.2", "0.3"]),
        (["pinch", "0.5", "0.5", "0.2", "0.6", "0.5", "--device", device], ["physical", device, "pinch", "0.5", "0.5", "0.2", "0.6", "0.5"]),
        (["multi-tap", "0.3", "0.4", "0.6", "0.4", "--simulator", simulator], ["simulator", simulator, "multi-tap", "0.3", "0.4", "0.6", "0.4"]),
        (["multi-drag", "0.5", "0.3", "0.6", "0.3", "0.4", "0.7", "0.6", "0.7", "0.4", "--device", device],
         ["physical", device, "multi-drag", "0.5", "0.3", "0.6", "0.3", "0.4", "0.7", "0.6", "0.7", "0.4"]),
        (["gesture", "{}", "--device", device], ["physical", device, "gesture", "{}"]),
        (["button", "home", "--simulator", simulator], ["simulator", simulator, "button", "home"]),
        (["key", "return", "--device", device], ["physical", device, "key", "return"]),
        (["type", "Hello", "--device", device], ["physical", device, "type", "Hello"]),
        (["paste", "mañana", "--device", device], ["physical", device, "paste", "mañana"]),
        (["wake", "--device", device], ["physical", device, "wake"]),
        (["wake", "--no-dismiss", "--device", device], ["physical", device, "wake", "--no-dismiss"]),
        (["tree", "--device", device], ["physical", device, "tree"]),
        (["tree", "--pid", "42", "--simulator", simulator], ["simulator", simulator, "tree", "42"]),
        (["press", "--id", "probe.button", "--device", device], ["physical", device, "press-id", "probe.button"]),
        (["press", "--label", "General", "--pid", "7", "--simulator", simulator], ["simulator", simulator, "press-label", "7", "General"]),
        (["scroll", "--label", "Row", "--device", device], ["physical", device, "scroll-label", "Row"]),
        (["scroll", "--id", "row", "--pid", "7", "--device", device], ["physical", device, "scroll-id", "7", "row"]),
        (["wait", "--id", "probe.summary", "--until", "gone", "--timeout", "5", "--simulator", simulator],
         ["simulator", simulator, "wait-id", "probe.summary", "--until", "gone", "--timeout", "5"]),
        (["wait", "--label", "Done", "--pid", "9", "--until", "value", "--value", "Ready", "--interval", "1", "--timeout", "2", "--device", device],
         ["physical", device, "wait-label", "9", "Done", "--until", "value", "--value", "Ready", "--timeout", "2", "--interval", "1"]),
        (["set-value", "--id", "field", "mañana 🚀", "--simulator", simulator], ["simulator", simulator, "set-value-id", "field", "mañana 🚀"]),
        (["screenshot", "tmp/a.png", "--device", device], ["physical", device, "screenshot", "tmp/a.png"]),
        (["screen", "--simulator", simulator], ["simulator", simulator, "screen"]),
        (["screen", "ocr", "--device", device], ["physical", device, "screen", "ocr"]),
        (["record", "tmp/a.mp4", "5", "--device", device], ["physical", device, "record", "tmp/a.mp4", "5"]),
        (["record", "tmp/a.mp4", "5", "hevc", "--backend", "coredevice", "--device", device],
         ["--recording-backend", "coredevice", "physical", device, "record", "tmp/a.mp4", "5", "hevc"]),
        (["apps", "--simulator", simulator], ["simulator", simulator, "apps"]),
        (["launch", "com.example.app", "--device", device], ["physical", device, "launch", "com.example.app"]),
        (["terminate", "123", "--device", device], ["physical", device, "terminate", "123"]),
        (["install", "tmp/App.app", "--simulator", simulator], ["simulator", simulator, "install", "tmp/App.app"]),
        (["uninstall", "com.example.app", "--simulator", simulator], ["simulator", simulator, "uninstall", "com.example.app"]),
        (["open-url", "https://example.com", "--device", device], ["physical", device, "open-url", "https://example.com"]),
        (["files", "list", "com.example.app", ".", "--device", device], ["physical", device, "files", "com.example.app", "."]),
        (["files", "pull", "com.example.app", "Documents/a", "tmp/a", "--device", device], ["physical", device, "pull", "com.example.app", "Documents/a", "tmp/a"]),
        (["files", "push", "com.example.app", "tmp/a", "Documents/a", "--device", device], ["physical", device, "push", "com.example.app", "tmp/a", "Documents/a"]),
        (["reports", "list", "--device", device], ["physical", device, "reports"]),
        (["reports", "list", "Retired", "--device", device], ["physical", device, "reports", "Retired"]),
        (["reports", "get", "a.ips", "tmp/a.ips", "--device", device], ["physical", device, "report", "a.ips", "tmp/a.ips"]),
        (["build-run", "App.xcodeproj", "App", "--simulator", simulator], ["simulator", simulator, "build-run", "App.xcodeproj", "App"]),
        (["build-run", "App.xcworkspace", "App", "--configuration", "Release", "--app-target", "App", "--allow-provisioning-updates",
          "--allow-device-registration", "--device", device],
         ["physical", device, "build-run", "App.xcworkspace", "App", "--configuration", "Release", "--app-target", "App",
          "--allow-provisioning-updates", "--allow-device-registration"]),
        (["logs", "--seconds", "10", "--bundle", "com.example.app", "--level", "debug", "--simulator", simulator],
         ["simulator", simulator, "logs", "--seconds", "10", "--bundle", "com.example.app", "--level", "debug"]),
        (["logs", "--start", "2026-01-01T00:00:00Z", "--end", "2026-01-01T00:01:00Z", "--process", "App", "--subsystem", "s", "--category", "c",
          "--max-entries", "5", "--max-bytes", "2048", "--output", "tmp/a.ndjson", "--simulator", simulator],
         ["simulator", simulator, "logs", "--start", "2026-01-01T00:00:00Z", "--end", "2026-01-01T00:01:00Z", "--process", "App", "--subsystem", "s",
          "--category", "c", "--max-entries", "5", "--max-bytes", "2048", "--output", "tmp/a.ndjson"]),
        (["logs", "--last", "60", "--pid", "42", "--simulator", simulator], ["simulator", simulator, "logs", "--last", "60", "--pid", "42"]),
        (["console", "com.example.app", "--seconds", "5", "--device", device], ["physical", device, "console", "com.example.app", "--seconds", "5"]),
        (["console", "com.example.app", "--seconds", "5", "--max-bytes", "2048", "--os-log", "--terminate", "--simulator", simulator, "--", "-flag", "--x"],
         ["simulator", simulator, "console", "com.example.app", "--seconds", "5", "--max-bytes", "2048", "--os-log", "--terminate", "--", "-flag", "--x"]),
        (["last-crash", "--bundle", "com.example.app", "--device", device], ["physical", device, "last-crash", "--bundle", "com.example.app"]),
        (["last-crash", "--process", "App", "--since", "2026-01-01T00:00:00Z", "--download", "tmp", "--simulator", simulator],
         ["simulator", simulator, "last-crash", "--process", "App", "--since", "2026-01-01T00:00:00Z", "--download", "tmp"]),
        (["devices"], ["devices", "physical"]),
        (["devices", "--simulators"], ["devices", "simulators"]),
        (["details", "--device", device], ["physical", device, "details"]),
        (["processes", "--device", device], ["physical", device, "processes"]),
        (["readiness", "--device", device], ["physical", device, "readiness"]),
        (["media-status", "--device", device], ["physical", device, "media-status"]),
        (["boot", "--simulator", simulator], ["simulator", simulator, "boot"]),
        (["shutdown", "--simulator", simulator], ["simulator", simulator, "shutdown"]),
        (["handoff", "Approve the prompt", "--simulator", simulator], ["simulator", simulator, "handoff", "Approve the prompt"]),
        (["handoff", "Approve the prompt", "60", "--device", device], ["physical", device, "handoff", "Approve the prompt", "60"]),
        (["doctor"], ["doctor"]),
        (["ocr", "tmp/a.png"], ["ocr", "tmp/a.png"]),
        (["decode-ax-archive", "tmp/a.plist"], ["decode-ax-archive", "tmp/a.plist"]),
    ]

    @Test(arguments: forms)
    func everyCommandParsesItsDocumentedForm(_ arguments: [String], _ expected: [String]) throws {
        let parsed = try invocation(arguments)
        #expect(parsed.arguments == expected)
        #expect(!parsed.dryRun && parsed.errorFormat == nil)
    }

    @Test func commandsCoverEveryOperationOnce() {
        let names = Self.forms.map { $0.0[0] == "files" || $0.0[0] == "reports" ? "\($0.0[0]) \($0.0[1])" : $0.0[0] }
        #expect(Set(names).count == 47)
    }

    @Test func dryRunAndErrorFormatAreAcceptedInAnyPosition() throws {
        let expected = ["physical", Self.device, "tap", "0.5", "0.5"]
        for arguments in [["--dry-run", "tap", "0.5", "0.5", "--device", Self.device],
                          ["tap", "--dry-run", "0.5", "0.5", "--device", Self.device],
                          ["tap", "0.5", "0.5", "--device", Self.device, "--dry-run"],
                          ["--error-format", "json", "--dry-run", "tap", "0.5", "0.5", "--device", Self.device]] {
            let parsed = try invocation(arguments)
            #expect(parsed.arguments == expected && parsed.dryRun, "\(arguments)")
        }
        #expect(try invocation(["tap", "0.5", "0.5", "--device", Self.device, "--error-format", "json"]).errorFormat == .json)
        #expect(try invocation(["files", "--dry-run", "list", "a.b", ".", "--device", Self.device]).dryRun)
    }

    @Test func anExplicitTargetWinsOverTheEnvironment() throws {
        let both = [Target.deviceVariable: Self.device, Target.simulatorVariable: Self.simulator]
        #expect(try invocation(["tap", "0.5", "0.5", "--simulator", Self.simulator], environment: both).arguments[0...1] == ["simulator", Self.simulator])
        #expect(try invocation(["tree", "--device", "other"], environment: [Target.deviceVariable: Self.device]).arguments[1] == "other")
        #expect(try invocation(["tree"], environment: [Target.deviceVariable: Self.device]).arguments[0...1] == ["physical", Self.device])
        #expect(try invocation(["tree"], environment: [Target.simulatorVariable: Self.simulator]).arguments[0...1] == ["simulator", Self.simulator])
        // An empty variable counts as unset.
        #expect(try invocation(["tree"], environment: [Target.deviceVariable: "", Target.simulatorVariable: Self.simulator]).arguments[0] == "simulator")
        let ambiguous = try usageFailure(["tree"], environment: both)
        #expect(ambiguous.description == "Both MANZANERO_DEVICE and MANZANERO_SIMULATOR are set; pass --device or --simulator to choose one.")
        let missing = try usageFailure(["tree"])
        #expect(missing.description.hasPrefix("Name a target: --device <UDID> or --simulator <UUID>"))
        let twice = try usageFailure(["tree", "--device", Self.device, "--simulator", Self.simulator])
        #expect(twice.description == "Give exactly one of --device or --simulator.")
        // Commands without a target ignore the variables.
        #expect(try invocation(["doctor"], environment: both).arguments == ["doctor"])
    }

    @Test(arguments: ["press", "scroll", "wait"])
    func selectorsNeedExactlyOneOfIdOrLabel(_ command: String) throws {
        for arguments in [[command, "--device", Self.device], [command, "--id", "a", "--label", "b", "--device", Self.device]] {
            let failure = try usageFailure(arguments)
            #expect(failure.description == "Give exactly one of --id or --label.")
            #expect(failure.code == .usage && failure.inputSent == .none && failure.retry == .no)
        }
    }

    @Test func selectorValuesMayBeginWithDashes() throws {
        #expect(try invocation(["press", "--label", "-x", "--device", Self.device]).arguments == ["physical", Self.device, "press-label", "-x"])
        // The root's own options are read before the command's, so a value
        // that spells one of them is attached with '=' (as MCP always does).
        let attached = try invocation(["press", "--label=--dry-run", "--device", Self.device])
        #expect(attached.arguments == ["physical", Self.device, "press-label", "--dry-run"] && !attached.dryRun)
        #expect(try invocation(["wait", "--id", "-x", "--value", "-1", "--device", Self.device]).arguments
            == ["physical", Self.device, "wait-id", "-x", "--value", "-1"])
    }

    @Test func operandsAfterTheTerminatorPassThroughUnchanged() throws {
        #expect(try invocation(["tap", "--device", Self.device, "--", "-0.1", "0.5"]).arguments == ["physical", Self.device, "tap", "-0.1", "0.5"])
        #expect(try invocation(["type", "--simulator", Self.simulator, "--", "--help"]).arguments == ["simulator", Self.simulator, "type", "--help"])
        let console = try invocation(["console", "a.b", "--seconds", "1", "--device", Self.device, "--", "--dry-run", "-x", "plain"])
        #expect(console.arguments == ["physical", Self.device, "console", "a.b", "--seconds", "1", "--", "--dry-run", "-x", "plain"])
        #expect(!console.dryRun)
    }

    @Test(arguments: [
        ["frobnicate"],
        ["tap", "0.5", "--device", device],
        ["tap", "0.5", "0.5", "0.5", "--device", device],
        ["tap", "0.5", "0.5", "--device", device, "--frob"],
        ["tap", "-0.5", "0.5", "--device", device],
        ["record", "a.mp4", "--device", device],
        ["console", "a.b", "--device", device],
        ["devices", "physical"],
        ["--error-format", "xml", "doctor"],
        ["physical", device, "tap", "0.5", "0.5"],
    ])
    func malformedCallsAreUsageErrorsThatExit64(_ arguments: [String]) throws {
        let failure = try usageFailure(arguments)
        #expect(failure.code == .usage && failure.inputSent == .none && failure.retry == .no && failure.action == nil)
        #expect(CommandFailure.exitCode(for: failure) == 64)
        let object = try #require(try JSONSerialization.jsonObject(with: ErrorFormat.json.render(failure)) as? [String: [String: Any]])
        #expect(object["error"]?["code"] as? String == "usage" && object["error"]?["inputSent"] as? String == "none")
        #expect(object["error"]?["message"] as? String == failure.description)
        // The text format adds the command's usage to the library's message.
        let text = String(decoding: ErrorFormat.text.render(failure), as: UTF8.self)
        #expect(text.hasPrefix("Error: ") || failure.text == nil)
    }

    @Test func domainFailuresKeepTheirExitCodes() {
        #expect(CommandFailure.exitCode(for: CommandFailure.usage("Physical input coordinates must be normalized numbers from 0 to 1.")) == 64)
        #expect(CommandFailure.exitCode(for: CommandFailure.unsupported("Unsupported simulator operation: details.")) == 1)
        #expect(CommandFailure.exitCode(for: CommandFailure(.deviceBusy, "busy", inputSent: .none)) == 1)
        #expect(CommandFailure.exitCode(for: CancellationError()) == 1)
    }

    @Test func helpVersionAndCompletionScriptsAreOutputs() throws {
        for arguments in [[], ["--help"], ["-h"], ["help"], ["tap", "--help"], ["help", "wait"], ["files"], ["files", "pull", "--help"],
                          ["--version"], ["--generate-completion-script", "zsh"]] {
            guard case .output(let text) = try CLI.parse(arguments, environment: [:]) else { Issue.record("\(arguments) is not output"); continue }
            #expect(!text.isEmpty, "\(arguments)")
        }
        guard case .output(let version) = try CLI.parse(["--version"], environment: [:]) else { return }
        #expect(version == "manzanero \(manzaneroVersion)")
        guard case .output(let root) = try CLI.parse(["--help"], environment: [:]) else { return }
        #expect(root.contains("Apple device tools for terminals and agents"))
        guard case .output(let wait) = try CLI.parse(["wait", "--help"], environment: [:]) else { return }
        #expect(wait.contains("--id <identifier>") && wait.contains("124"))
    }

    @Test func mcpServesAndRefusesADryRun() throws {
        guard case .serve = try CLI.parse(["mcp"], environment: [:]) else { Issue.record("mcp is not served"); return }
        #expect(try usageFailure(["mcp", "--dry-run"]).description == "--dry-run requires a physical or simulator command.")
        #expect(throws: CommandFailure.self) { try CLI.invocation(["mcp"]) }
    }

    /// MCP's command lines never take the target from the environment.
    @Test func toolInvocationsIgnoreTheEnvironmentTarget() throws {
        #expect(throws: CommandFailure.self) { try CLI.invocation(["tree"]) }
        #expect(try CLI.invocation(["tree", "--device=\(Self.device)"]).arguments == ["physical", Self.device, "tree"])
    }
}
