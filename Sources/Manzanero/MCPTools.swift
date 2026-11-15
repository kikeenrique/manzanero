import Foundation
import MCP

struct MCPField: Sendable {
    enum Kind: String, Sendable { case string, number, integer, boolean, array }
    let name: String
    var kind: Kind = .string
    var description: String = ""
    var required = true
    var choices: [String] = []

    var schema: Value {
        var value: [String: Value] = ["type": .string(kind.rawValue), "description": .string(description)]
        if !choices.isEmpty { value["enum"] = .array(choices.map(Value.string)) }
        if kind == .array { value["items"] = .object(["type": "number"]) }
        return .object(value)
    }

    func validate(_ value: Value?) throws {
        guard let value else {
            if required { throw MCPError.invalidParams("Missing parameter: \(name)") }
            return
        }
        let valid: Bool
        switch (kind, value) {
        case (.string, .string(let text)): valid = !text.isEmpty && (choices.isEmpty || choices.contains(text))
        case (.number, .int), (.integer, .int), (.boolean, .bool): valid = true
        case (.number, .double(let number)): valid = number.isFinite
        case (.array, .array(let values)):
            valid = values.allSatisfy { if case .int = $0 { return true }; if case .double(let n) = $0 { return n.isFinite }; return false }
        default: valid = false
        }
        guard valid else { throw MCPError.invalidParams("Invalid parameter type or value: \(name)") }
    }
}

struct MCPToolDefinition: Sendable {
    let name: String
    let description: String
    let fields: [MCPField]
    var readOnly = false
    var imagePath: String? = nil
    var imageFromResult = false
    /// Exit codes that carry an answer rather than a malfunction (such as a
    /// wait's timeout); they do not set `isError`.
    var answerExitCodes: Set<Int32> = [0]
    let route: @Sendable ([String: Value]) -> [String]

    var tool: Tool {
        Tool(name: name, description: description, inputSchema: .object([
            "type": "object", "properties": .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.schema) })),
            "required": .array(fields.filter(\.required).map { .string($0.name) }), "additionalProperties": false
        ]), annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly))
    }

    func command(_ arguments: [String: Value]) throws -> [String] {
        guard Set(arguments.keys).isSubset(of: Set(fields.map(\.name))) else {
            throw MCPError.invalidParams("Unknown parameters for \(name)")
        }
        for field in fields { try field.validate(arguments[field.name]) }
        return route(arguments)
    }
}

private extension Dictionary where Key == String, Value == MCP.Value {
    func text(_ key: String, default fallback: String = "") -> String { self[key]?.stringValue ?? fallback }
    func number(_ key: String) -> String {
        if case .int(let value) = self[key] { return String(value) }
        if case .double(let value) = self[key] { return String(value) }
        return ""
    }
    func deviceCommand(_ operands: [String], platform: String? = nil) -> [String] {
        [platform ?? text("platform"), text("device")] + operands
    }
}

enum MCPTools {
    private static let platform = MCPField(name: "platform", choices: ["physical", "simulator"])
    private static let device = MCPField(name: "device", description: "Explicit target identifier; use the UDID from list_devices.")
    private static let x = MCPField(name: "x", kind: .number)
    private static let y = MCPField(name: "y", kind: .number)
    /// For tools that predate simulator support: omitted means physical.
    private static let optionalPlatform = MCPField(name: "platform", description: "physical (default) or simulator (a booted simulator, addressed by UUID).", required: false, choices: ["physical", "simulator"])

    static let definitions: [MCPToolDefinition] = [
        .init(name: "list_devices", description: "List CoreDevice or available simulator inventory. Physical inventory may also include simulators.", fields: [platform], readOnly: true) {
            ["devices", $0.text("platform") == "physical" ? "physical" : "simulators"]
        },
        .init(name: "doctor", description: "Check Xcode and discovery services, report host macOS/Xcode/CoreDevice versions, and check on the host only (no device contact) whether each capability's private Apple frameworks, symbols, classes and selectors are present, naming any missing. Private-interface gaps do not set isError; only unavailable Xcode/CoreDevice/CoreSimulator tools do. Does not verify input delivery or device behavior.", fields: [], readOnly: true) { _ in ["doctor"] },
        .init(name: "press_element", description: "Press one AX element by exact identifier or label through Apple's native AX interfaces in process. Platform defaults to physical, which selects the primary awake portrait display-centre app; a simulator selects its frontmost application (else the screen-centre process) through CoreSimulator. Optional pid must match. Two fresh unique snapshots, live enabled/visible state and frame, exact centre hit, and application/display rechecks precede one native press. No helper, coordinate fallback or replay. Native acceptance does not verify UI effect; inspect afterward. Settings identifier/label navigation has scoped iPhone 13 mini verification; the probe app and Settings on one iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), .init(name: "by", choices: ["identifier", "label"]), .init(name: "text")]) {
            $0.deviceCommand([$0.text("by") == "identifier" ? "press-id" : "press-label"] + ($0["pid"] == nil ? [] : [$0.number("pid")]) + [$0.text("text")], platform: $0.text("platform", default: "physical"))
        },
        .init(name: "device_readiness", description: "Read physical Developer Mode, developer-image services, connection and pairing, plus sequential display-power/passcode observations. UI status is separate from the CoreDevice prerequisite status/exit code. Passcode fields do not prove current UI unlock; UI Automation, HID and capture remain unverified. No wake/unlock is attempted. Returns preparation actions and unknown states when observations are unavailable.", fields: [device], readOnly: true) { $0.deviceCommand(["readiness"], platform: "physical") },
        .init(name: "scroll_to_element", description: "Request one in-process Apple AX scroll-to-visible by exact identifier or label. Target must already exist in the bounded snapshot. Platform defaults to physical; optional pid must match the awake primary portrait display-centre app on a device, or the frontmost application (else the screen-centre process) on a simulator. Two fresh snapshots and live target/state/display guards precede one action, followed by read-only visibility/frame/hit and selection checks. No helper, press, swipe fallback or replay. Inspect nativeResult and postconditionVerified separately; native false may mean already visible. A completed native result with failed observation returns postcondition-failed. Cleanup outcomes remain separate. Settings movement and already-visible behavior have scoped iPhone 13 mini CLI/MCP verification; one Settings scroll on an iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), .init(name: "by", choices: ["identifier", "label"]), .init(name: "text")]) {
            $0.deviceCommand([$0.text("by") == "identifier" ? "scroll-id" : "scroll-label"] + ($0["pid"] == nil ? [] : [$0.number("pid")]) + [$0.text("text")], platform: $0.text("platform", default: "physical"))
        },
        .init(name: "request_handoff", description: "Ask a person to complete a step on the device (for example Face ID or a permission). Requires an MCP host supporting form elicitation. Only an explicit completed checkbox acknowledges the request; it does not verify device success. Do not put secrets in the message. Device mutation calls are paused in this server while the response is pending.", fields: [platform, device, .init(name: "message")]) { $0.deviceCommand(["handoff", $0.text("message")]) },
        .init(name: "inspect_device", description: "List apps on either platform, or physical details/processes/media status. Physical media-status reads native Apple media support flags, running state and session count only; it never starts/stops a stream or exports session identities/keys, and does not prove recording support.", fields: [platform, device, .init(name: "query", choices: ["apps", "details", "processes", "media-status"])], readOnly: true) { $0.deviceCommand([$0.text("query")]) },
        .init(name: "get_ui_tree", description: "Read a native accessibility tree in process. Platform defaults to physical: Apple's tunnel, Network/RemoteXPC and raw AX DTX; without pid, selects/rechecks the primary portrait display-centre process and Apple display geometry, and the display must be awake. Simulator (a booted simulator by UUID): the same AX requests through CoreSimulator; without pid, selects/rechecks the frontmost application, or the process under the screen centre when the simulator reports none, so system overlays in other processes are not included, and the Home Screen's large hierarchy can come back empty. Optional positive pid may inspect a background app on either platform. Settings has scoped iPhone 13 mini verification; the probe app, Settings and the lock screen were read on one iPhone 17e simulator. Returns logical-point frames, non-atomic snapshot-local IDs and separate cleanup outcomes. No selector action or fallback.", fields: [device, .init(name: "platform", required: false, choices: ["physical", "simulator"]), .init(name: "pid", kind: .integer, description: "Optional current application PID; omitted selects the display-centre process (physical) or the frontmost application, else the screen-centre process (simulator).", required: false)], readOnly: true) {
            $0.deviceCommand(["tree"] + ($0["pid"] == nil ? [] : [$0.number("pid")]), platform: $0.text("platform", default: "physical"))
        },
        .init(name: "wait_for_element", description: "Wait, read-only, until one exact identifier/label selector meets a condition, using one in-process Apple AX session for the whole wait. Platform defaults to physical; on a simulator every poll without pid re-selects the frontmost application (else the screen-centre process) instead of the display-centre process. until: visible (default; exactly one matching element, visible in the snapshot), gone (no match, or every match explicitly not visible), enabled/disabled (visible plus live enabled state), or value (visible plus exact string value; requires value). timeout_seconds 0...60 (default 10; 0 checks once), interval_seconds 0.25...5 (default 0.5). Without pid every poll re-selects the awake portrait primary display-centre process, so app launches and sheets are followed; with pid that app is observed even in the background, and its exit ends the wait as an error. Several distinct matches never satisfy a positive condition and are reported as ambiguous. A timeout returns status timed-out with the last observation and isError false; transport/session failure returns isError true with cleanup outcomes. No input, lease, fallback or reconnection. Each poll is a non-atomic snapshot; not yet verified on physical hardware, run on one iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, description: "Optional positive application PID; omitted re-selects the display-centre process (physical) or the frontmost application, else the screen-centre process (simulator) each poll.", required: false), .init(name: "by", choices: ["identifier", "label"]), .init(name: "text", description: "Exact, case-sensitive selector, 1...4096 UTF-8 bytes."),
            .init(name: "until", required: false, choices: AccessibilityWait.conditionNames),
            .init(name: "value", description: "Exact expected value text for until=value.", required: false),
            .init(name: "timeout_seconds", kind: .number, description: "0...60, default 10.", required: false),
            .init(name: "interval_seconds", kind: .number, description: "0.25...5, default 0.5.", required: false)],
            readOnly: true, answerExitCodes: [0, AccessibilityWait.timeoutExitCode]) {
            var args = $0.deviceCommand([$0.text("by") == "identifier" ? "wait-id" : "wait-label"] + ($0["pid"] == nil ? [] : [$0.number("pid")]) + [$0.text("text")], platform: $0.text("platform", default: "physical"))
            if $0["until"] != nil { args += ["--until", $0.text("until")] }
            if $0["value"] != nil { args += ["--value", $0.text("value")] }
            if $0["timeout_seconds"] != nil { args += ["--timeout", $0.number("timeout_seconds")] }
            if $0["interval_seconds"] != nil { args += ["--interval", $0.number("interval_seconds")] }
            return args
        },
        .init(name: "get_screen", description: "Capture a PNG and inspect it. Auto prefers a useful AX tree (physical: app at primary display centre; simulator: frontmost application, else the screen-centre one), then Vision OCR, then explicitly reports image-only. Method can force tree or ocr. Returns coordinate space, dimensions, diagnostics, and the image (downscaled, with a note, when the PNG exceeds 8 MiB). AX uses logical points, OCR normalized bounds. Capture/analysis are sequential and non-atomic.", fields: [platform, device, .init(name: "method", required: false, choices: ["auto", "tree", "ocr"])], imagePath: "imagePath", imageFromResult: true) { $0.deviceCommand(["screen", $0.text("method", default: "auto")]) },
        .init(name: "decode_accessibility_archive", description: "Inspect a saved local keyed archive in process through Foundation, without connecting to a device or launching a helper. Bounded data-only structural decoding preserves unknown classes/fields, decodes nested archives, and represents opaque data by byte count. Does not instantiate archived classes, produce a parsed physical hierarchy or establish numeric attribute meanings.", fields: [.init(name: "path")], readOnly: true) { ["decode-ax-archive", $0.text("path")] },
        .init(name: "screenshot", description: "Capture a PNG to a local path and return it as MCP image content, downscaled with a note when the PNG exceeds 8 MiB. May replace an existing local file. Simulator and awake/unlocked iPhone 13 mini USB capture verified; earlier captures before confirmed wake/unlock were black.", fields: [platform, device, .init(name: "path", description: "Local output path ending in .png; prefer ignored tmp/.")], imagePath: "path") { $0.deviceCommand(["screenshot", $0.text("path")]) },
        .init(name: "record_screen", description: "Record a finite screen video to a new host .mp4 path. Parent must exist; existing paths refused. Duration 1...300 seconds; h264 or hevc. Physical defaults to devicectl, which may lack capability; optional recording_backend coredevice uses in-process Apple negotiation, HEVC RTP decoding with VideoToolbox and AVFoundation encoding on macOS 26+. Native publication requires owned stop/absence and tunnel-release acknowledgements. Native RTCP receiver reports are sent to the owned peer. Experimental: reliable startup, keyframe/crash recovery and captures beyond verified durations remain incomplete or unverified. No automatic fallback, audio, or inline video. Metadata includes decoded duration/dimensions.", fields: [platform, device, .init(name: "path"), .init(name: "seconds", kind: .number), .init(name: "codec", required: false, choices: ["h264", "hevc"]), .init(name: "recording_backend", required: false, choices: ["devicectl", "coredevice"])]) {
            ($0["recording_backend"] == nil ? [] : ["--recording-backend", $0.text("recording_backend")]) + $0.deviceCommand(["record", $0.text("path"), $0.number("seconds"), $0.text("codec", default: "h264")])
        },
        .init(name: "tap", description: "Tap normalized current-interface coordinates 0...1, origin top left. Physical: in-process Apple CoreDevice; rechecks the awake primary display and maps orientation before input. Simulator (booted, by UUID): in-process host XPC to the simulator's dtuhidd HID daemon, portrait interface assumed. Dispatch does not verify UI effect/release.", fields: [platform, device, x, y]) { $0.deviceCommand(["tap", $0.number("x"), $0.number("y")]) },
        .init(name: "drag", description: "Drag one contact. Current-interface normalized coordinates; duration 0.03...10 seconds. Physical: in-process Apple CoreDevice with display geometry/orientation rechecks. Simulator (booted, by UUID): host XPC to its dtuhidd, portrait assumed. Sends a complete bounded schedule followed by release/barrier. Dispatch does not prove movement or release.", fields: [platform, device, .init(name: "x1", kind: .number), .init(name: "y1", kind: .number), .init(name: "x2", kind: .number), .init(name: "y2", kind: .number), .init(name: "seconds", kind: .number)]) {
            $0.deviceCommand(["drag"] + ["x1", "y1", "x2", "y2", "seconds"].map($0.number))
        },
        .init(name: "multi_tap", description: "Physical simultaneous contact and release after 80 ms at two to five normalized coordinate pairs through in-process Apple Universal HID. Dispatch does not verify UI effect/release; no helper or replay.", fields: [device, .init(name: "coordinates", kind: .array, description: "Flat numeric array [x1,y1,x2,y2,...], 4...10 values.")]) {
            let numbers = ($0["coordinates"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.deviceCommand(["multi-tap"] + numbers, platform: "physical")
        },
        .init(name: "multi_drag", description: "Move two to five physical contacts along straight paths through in-process Apple CoreDevice. Current-interface normalized coordinates; duration 0.03...10 seconds. Contacts start together and release 1 ms after movement. Two-path Indigo input refuses overlapping/crossing paths; three-to-five paths use Universal HID. Dispatch does not verify UI effect/release; no helper or replay.", fields: [device, .init(name: "paths", kind: .array, description: "Flat array [startX,startY,endX,endY,...], 8...20 numbers, four per contact."), .init(name: "seconds", kind: .number)]) {
            let paths = ($0["paths"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.deviceCommand(["multi-drag", $0.number("seconds")] + paths, platform: "physical")
        },
        .init(name: "pinch", description: "Horizontal two-contact pinch/spread through in-process Apple CoreDevice. Current-interface normalized center; positive start/end spans are fractions of screen width and all endpoints must fit. Smaller end span pinches inward, larger spreads outward. Duration 0.03...10 seconds. Fresh display checks and complete paired lift apply; dispatch does not prove zoom/release. No helper or replay.", fields: [device, .init(name: "center_x", kind: .number), .init(name: "center_y", kind: .number), .init(name: "start_span", kind: .number), .init(name: "end_span", kind: .number), .init(name: "seconds", kind: .number)]) {
            $0.deviceCommand(["pinch"] + ["center_x", "center_y", "start_span", "end_span", "seconds"].map($0.number), platform: "physical")
        },
        .init(name: "type_text", description: "Type at current focus: 1...512 printable US-layout ASCII characters, tab and LF newline as in-process Apple Indigo keyboard events, without a helper or clipboard change. Platform defaults to physical; a booted simulator receives the same events through its dtuhidd keyboard service. Hardware-keyboard layout, Caps Lock, focus and app behavior can alter output; verify the field. No automatic replay. For Unicode on a physical device use paste_text, which replaces the clipboard; simulator Unicode entry is not implemented.", fields: [device, .init(name: "platform", required: false, choices: ["physical", "simulator"]), .init(name: "text")]) { $0.deviceCommand(["type", $0.text("text")], platform: $0.text("platform", default: "physical")) },
        .init(name: "press_button", description: "Press a hardware button in process. Physical (CoreDevice/RemoteXPC): home, lock, volume-up, volume-down. Simulator (booted, by UUID; dtuhidd): home and lock only, volume refused. No helper executable. UI effect/release is not verified by dispatch; lock toggles the display.", fields: [platform, device, .init(name: "button")]) { $0.deviceCommand(["button", $0.text("button")]) },
        .init(name: "wake_device", description: "Wake a physical device whose display is off. Reads Apple's display and passcode state twice; only if the primary display is off both times, presses the side button once in process and reads the state again. If the display is then on and no passcode is required, presses Home once to leave the lock screen unless dismiss_lock_screen is false. Never presses when the display is on or its state is unknown, never repeats the press, never enters a passcode. Returns status already-awake, awake, awake-locked, not-awake or unknown-display-state with the observed display power; an awake display does not prove the UI is unlocked, so inspect afterward. Observed once on an iPhone 13 mini without a passcode.", fields: [device, .init(name: "dismiss_lock_screen", kind: .boolean, required: false)], answerExitCodes: [0, 1]) {
            $0.deviceCommand([DirectPhysicalWake.operation] + ($0["dismiss_lock_screen"]?.boolValue == false ? [DirectPhysicalWake.noDismissFlag] : []), platform: "physical")
        },
        .init(name: "press_key", description: "Send one named key as in-process Apple Indigo HID: return, escape, backspace, tab, space, up, down, left, right. Platform defaults to physical (CoreDevice); a booted simulator receives it through its dtuhidd keyboard service. Uses the currently focused field; does not focus, type arbitrary text or paste. One down/up and transport barriers; UI effect/release remain unverified by dispatch. No helper executable or automatic replay.", fields: [device, optionalPlatform, .init(name: "key", choices: ["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"])]) { $0.deviceCommand(["key", $0.text("key")], platform: $0.text("platform", default: "physical")) },
        .init(name: "paste_text", description: "Physical Unicode paste using Apple devicectl clipboard copy and in-process CoreDevice Command+V. Replaces the device clipboard, then sends one paste sequence at the focused caret/selection. Does not focus a field, select all, submit, restore the clipboard, or retry. 1...65536 UTF-8 bytes without NUL. A permission prompt may interpose; inspect the field to verify insertion. No third-party helper executable.", fields: [device, .init(name: "text")]) {
            ["--physical-backend", "coredevice"] + $0.deviceCommand(["paste", $0.text("text")], platform: "physical")
        },
        .init(name: "long_press", description: "Hold one touch at current-interface normalized x/y for 0.1...10 seconds, then release. Platform defaults to physical (in-process Apple CoreDevice, with primary display geometry/orientation rechecks); a booted simulator receives it through its dtuhidd digitizer service, portrait assumed. App gesture thresholds vary; receipt does not verify effect/release. No helper executable, replay or AX fallback. Process/transport interruption can prevent release.", fields: [device, optionalPlatform, .init(name: "x", kind: .number), .init(name: "y", kind: .number), .init(name: "seconds", kind: .number)]) {
            let operands = ["long-press", $0.number("x"), $0.number("y"), $0.number("seconds")]
            return $0.text("platform", default: "physical") == "simulator" ? $0.deviceCommand(operands, platform: "simulator")
                : ["--physical-backend", "coredevice"] + $0.deviceCommand(operands, platform: "physical")
        },
        .init(name: "perform_gesture", description: "Send one bounded physical touch sequence through in-process Apple Universal HID; no helper executable. sequence is JSON {frames:[{ms:integer,touches:[{id:integer,x:number,y:number}]}]}; 2...512 complete-state frames, first ms=0 with a touch, strictly increasing times through 10000 ms, last touches empty. IDs form 0...N-1, N<=5. Coordinates normalized in the current interface, with fresh display checks. Omitted contacts release at their last position; IDs may touch again. Supports sampled paths, holds, and repeated taps with no automatic interpolation or replay. Dispatch does not verify effect, timing, or release.", fields: [device, .init(name: "sequence", description: "JSON sequence, maximum 65536 UTF-8 bytes; each frame lists all active touches.")]) {
            ["--physical-backend", "coredevice"] + $0.deviceCommand(["gesture", $0.text("sequence")], platform: "physical")
        },
        .init(name: "app_action", description: "Install, uninstall, launch, terminate an app, or open a URL. Value is a host app path for install, a URL for open-url, a positive PID for physical terminate, otherwise a bundle identifier. Uninstall deletes app data.", fields: [platform, device, .init(name: "operation", choices: ["install", "uninstall", "launch", "terminate", "open-url"]), .init(name: "value")]) { $0.deviceCommand([$0.text("operation"), $0.text("value")]) },
        .init(name: "app_data", description: "Physical app-container listing or raw pull/push. Remote paths are relative; '.' means root. Listing is nonrecursive. Copies may overwrite selected destinations; app access is permission-dependent and unverified live. Not .xcappdata export/replacement.", fields: [device, .init(name: "operation", choices: ["files", "pull", "push"]), .init(name: "bundle_id"), .init(name: "remote_path"), .init(name: "local_path", required: false)]) {
            let op = $0.text("operation"), base = [op, $0.text("bundle_id")]
            let paths = op == "files" ? [$0.text("remote_path")] : (op == "pull" ? [$0.text("remote_path"), $0.text("local_path")] : [$0.text("local_path"), $0.text("remote_path")])
            return $0.deviceCommand(base + paths, platform: "physical")
        },
        .init(name: "list_reports", description: "List saved physical report metadata without recursion. Optional relative directory, default '.'. Live listing verified; does not read contents.", fields: [device, .init(name: "directory", required: false)], readOnly: true) { $0.deviceCommand(["reports", $0.text("directory", default: ".")], platform: "physical") },
        .init(name: "download_report", description: "Download a selected saved physical report to a host path. May overwrite that destination. Download unverified live; no parsing or symbolication.", fields: [device, .init(name: "remote_path"), .init(name: "local_path")]) { $0.deviceCommand(["report", $0.text("remote_path"), $0.text("local_path")], platform: "physical") },
        .init(name: "build_run", description: "Build an iOS Xcode project/workspace, install and restart its app. Executes the project's build scripts. Explicit scheme required; configuration defaults Debug. Physical builds use signing assets already on the Mac unless allow_provisioning_updates is true, which lets Xcode use the developer account signed in to Xcode to create or change certificates, app IDs and profiles on Apple's developer services; allow_device_registration additionally registers the device with the team. Both are physical-only, off by default; ask the user before enabling. Physical signing/deployment unverified. Requires xcsift. Does not verify UI health.", fields: [platform, device, .init(name: "project"), .init(name: "scheme"), .init(name: "configuration", required: false), .init(name: "app_target", required: false),
            .init(name: "allow_provisioning_updates", kind: .boolean, description: "Physical only. Pass -allowProvisioningUpdates: Xcode contacts Apple's developer services with the user's account and may create or update certificates, app IDs and provisioning profiles.", required: false),
            .init(name: "allow_device_registration", kind: .boolean, description: "Physical only; requires allow_provisioning_updates. Pass -allowProvisioningDeviceRegistration: Xcode may register this device in the user's developer account.", required: false)]) {
            var args = $0.deviceCommand(["build-run", $0.text("project"), $0.text("scheme")])
            if let config = $0["configuration"]?.stringValue { args += ["--configuration", config] }
            if let target = $0["app_target"]?.stringValue { args += ["--app-target", target] }
            if $0["allow_provisioning_updates"]?.boolValue == true { args.append(BuildRunCommand.provisioningUpdatesFlag) }
            if $0["allow_device_registration"]?.boolValue == true { args.append(BuildRunCommand.deviceRegistrationFlag) }
            return args
        },
        .init(name: "simulator_state", description: "Boot or shut down a selected simulator. Shutdown interrupts running apps; no erase or delete operation is exposed.", fields: [device, .init(name: "operation", choices: ["boot", "shutdown"])]) { $0.deviceCommand([$0.text("operation")], platform: "simulator") },
        .init(name: "ocr_image", description: "Recognize text in a local image using Vision. Normalized top-left bounds. Recognition verified on one simulator fixture; broad accuracy remains unverified.", fields: [.init(name: "path")], readOnly: true) { ["ocr", $0.text("path")] }
    ]

    static func call(name: String, arguments: [String: Value], execute: @Sendable ([String]) async throws -> CommandOutput) async throws -> CallTool.Result {
        guard let definition = definitions.first(where: { $0.name == name }) else { throw MCPError.invalidParams("Unknown tool: \(name)") }
        let command = try definition.command(arguments)
        do {
            let output = try await execute(command)
            let value = try? JSONDecoder().decode(Value.self, from: output.data)
            var content: [Tool.Content] = [.text(text: String(decoding: output.data, as: UTF8.self), annotations: nil, _meta: nil)]
            if output.exitCode == 0, let key = definition.imagePath,
               let path = (definition.imageFromResult ? value?.objectValue?[key] : arguments[key])?.stringValue {
                let (attachment, omission) = try InlineImage.attachment(for: URL(fileURLWithPath: path))
                if let attachment {
                    content.append(.image(data: attachment.data.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil))
                    if let note = attachment.note { content.append(.text(text: note, annotations: nil, _meta: nil)) }
                }
                if let omission { content.append(.text(text: omission, annotations: nil, _meta: nil)) }
            }
            return .init(content: content, structuredContent: value.map { .object(["result": $0]) },
                         isError: !definition.answerExitCodes.contains(output.exitCode))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The text stays as before; structuredContent adds the same
            // classification the CLI prints with --error-format json.
            return .init(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)],
                         structuredContent: Optional(errorContent(error)), isError: true)
        }
    }

    /// `{"error": {code, message, inputSent, retry, action}}`; see docs/errors.md.
    static func errorContent(_ error: any Error) -> Value {
        let fields = CommandFailure.classify(error).fields.mapValues { $0.map(Value.string) ?? .null }
        return .object(["error": .object(fields)])
    }
}
