import Foundation
import MCP

struct MCPField: Sendable {
    /// `commandArray` is an array of arrays of strings: a batch's steps.
    enum Kind: String, Sendable { case string, number, integer, boolean, array, stringArray, commandArray }
    let name: String
    var kind: Kind = .string
    var description: String = ""
    var required = true
    var choices: [String] = []

    var schema: Value {
        var value: [String: Value] = ["type": .string(kind == .stringArray || kind == .commandArray ? "array" : kind.rawValue), "description": .string(description)]
        if kind == .commandArray {
            value["items"] = .object(["type": "array", "items": .object(["type": "string"]), "minItems": 1])
            value["minItems"] = 1
            value["maxItems"] = .int(BatchCommand.maximumSteps)
        }
        if !choices.isEmpty { value["enum"] = .array(choices.map(Value.string)) }
        if kind == .array { value["items"] = .object(["type": "number"]) }
        if kind == .stringArray { value["items"] = .object(["type": "string"]) }
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
        case (.stringArray, .array(let values)):
            valid = values.count <= 64 && values.allSatisfy { if case .string(let text) = $0 { return !text.contains("\0") }; return false }
        case (.commandArray, .array(let steps)):
            valid = (1...BatchCommand.maximumSteps).contains(steps.count) && steps.allSatisfy { step in
                guard case .array(let words) = step, !words.isEmpty, words.count <= 64 else { return false }
                return words.allSatisfy { if case .string(let text) = $0 { return !text.contains("\0") }; return false }
            }
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
    /// A CLI command line for the tool's target: `<command> --device=<id>`
    /// (or `--simulator=<id>`), options, then `--` and the operands. Option
    /// values are attached with `=` and operands follow `--`, so a value that
    /// begins with '-' reaches the operation's own validation unchanged.
    func command(_ name: [String], platform: String? = nil, options: [String] = [], operands: [String] = []) -> [String] {
        name + [((platform ?? text("platform")) == "simulator" ? "--simulator=" : "--device=") + text("device")] + options
            + (operands.isEmpty ? [] : ["--"] + operands)
    }

    /// `--name=value` for each field that is present.
    func options(_ pairs: [(field: String, option: String)], numeric: Bool = false) -> [String] {
        pairs.compactMap { self[$0.field] == nil ? nil : "\($0.option)=\(numeric ? number($0.field) : text($0.field))" }
    }

    /// `--id=<text>`, `--label=<text>` or `--with-value=<text>`, then `--pid=<n>` and `--index=<n>` when given.
    var selector: [String] {
        ["\(text("by") == "identifier" ? "--id" : text("by") == "value" ? "--with-value" : "--label")=\(text("text"))"] + options([("pid", "--pid"), ("index", "--index")], numeric: true)
    }

    var physicalByDefault: String { text("platform", default: "physical") }
}

enum MCPTools {
    private static let platform = MCPField(name: "platform", choices: ["physical", "simulator"])
    private static let device = MCPField(name: "device", description: "Explicit target identifier; use the UDID from list_devices.")
    private static let x = MCPField(name: "x", kind: .number)
    private static let y = MCPField(name: "y", kind: .number)
    /// For tools that predate simulator support: omitted means physical.
    private static let selectorBy = MCPField(name: "by", description: "The field text is compared with: identifier, label, or value (the element's exact current value) for an element that has neither, such as a search field that only shows its placeholder.", choices: ["identifier", "label", "value"])
    private static let selectorIndex = MCPField(name: "index", kind: .integer, description: "Optional position, counted from 1, among several elements that match the selector, in the tree's node order (the order an ambiguous-selector failure lists them). Without it the selector must settle on one element. Positional, so read the tree first.", required: false)
    private static let optionalPlatform = MCPField(name: "platform", description: "physical (default) or simulator (a booted simulator, addressed by UUID).", required: false, choices: ["physical", "simulator"])

    static let definitions: [MCPToolDefinition] = [
        .init(name: "list_devices", description: "List CoreDevice or available simulator inventory. Physical inventory may also include simulators.", fields: [platform], readOnly: true) {
            $0.text("platform") == "physical" ? ["devices"] : ["devices", "--simulators"]
        },
        .init(name: "doctor", description: "Check Xcode and discovery services, report host macOS/Xcode/CoreDevice versions, and check on the host only (no device contact) whether each capability's private Apple frameworks, symbols, classes and selectors are present, naming any missing. Private-interface gaps do not set isError; only unavailable Xcode/CoreDevice/CoreSimulator tools do. Does not verify input delivery or device behavior.", fields: [], readOnly: true) { _ in ["doctor"] },
        .init(name: "press_element", description: "Press one AX element by exact identifier or label through Apple's native AX interfaces in process. Platform defaults to physical, which selects the primary awake portrait display-centre app; a simulator selects its frontmost application (else the screen-centre process) through CoreSimulator. Optional pid must match. Two fresh unique snapshots, live enabled/visible state and frame, exact centre hit, and application/display rechecks precede one native press. No helper, coordinate fallback or replay. Native acceptance does not verify UI effect; inspect afterward. Settings identifier/label navigation has scoped iPhone 13 mini verification; the probe app and Settings on one iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), selectorBy, .init(name: "text"), selectorIndex]) {
            $0.command(["press"], platform: $0.physicalByDefault, options: $0.selector)
        },
        .init(name: "set_element_value", description: "Replace one AX element's whole value with Unicode text through Apple's native AX set-value request (type 8, attribute 53), without keyboard events or the clipboard. Platform defaults to physical (the same request over the device's AX service); a booted simulator is addressed by UUID through CoreSimulator. Selection and guards are those of press_element (foreground application, two fresh unique snapshots, live enabled/visible state and frame, exact centre hit, rechecks); the element must also report its value settable, or nothing is sent. Select the text field itself. Optional pid must match. The field becomes first responder. Returns status acknowledged and valueMatches from one read-back; the app may transform the value. Not typing at a caret: for that use type_text (ASCII). No fallback or replay. Verified on the probe app's text field on one iPhone 13 mini and one iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), selectorBy, .init(name: "text", description: "Exact selector, 1...4096 UTF-8 bytes."), selectorIndex, .init(name: "value", description: "New value, 1...65536 UTF-8 bytes without NUL; replaces the whole value.")]) {
            $0.command(["set-value"], platform: $0.physicalByDefault, options: $0.selector, operands: [$0.text("value")])
        },
        .init(name: "device_readiness", description: "Read physical Developer Mode, developer-image services, connection and pairing, plus sequential display-power/passcode observations. UI status is separate from the CoreDevice prerequisite status/exit code. Passcode fields do not prove current UI unlock; UI Automation, HID and capture remain unverified. No wake/unlock is attempted. Returns preparation actions and unknown states when observations are unavailable.", fields: [device], readOnly: true) { $0.command(["readiness"], platform: "physical") },
        .init(name: "clear_quarantine", description: "Remove this Mac's quarantine mark for one device or simulator. A device is quarantined when a touch, button or key input ended with an unknown outcome, or its owning process exited mid-input, so a contact, key or button may still be held; input tools are then refused with code device-quarantined while observations and captures still work. Inspect the device first (get_ui_tree, screenshot), then call this. It sends nothing to the device and releases nothing on it. status is cleared (with the recorded reason) or not-quarantined.", fields: [platform, device]) {
            $0.command([DeviceQuarantine.operation])
        },
        .init(name: "scroll_to_element", description: "Request one in-process Apple AX scroll-to-visible by exact identifier or label. Target must already exist in the bounded snapshot. Platform defaults to physical; optional pid must match the awake primary portrait display-centre app on a device, or the frontmost application (else the screen-centre process) on a simulator. Two fresh snapshots and live target/state/display guards precede one action, followed by read-only visibility/frame/hit and selection checks. No helper, press, swipe fallback or replay. Inspect nativeResult and postconditionVerified separately; native false may mean already visible. A completed native result with failed observation returns postcondition-failed. Cleanup outcomes remain separate. Settings movement and already-visible behavior have scoped iPhone 13 mini CLI/MCP verification; one Settings scroll on an iPhone 17e simulator. search (1...200) looks forward for a target that is not in the snapshot yet, as in a list that loads its rows while it moves: one scroll step at a time, a fresh snapshot after each, until the target appears, the list stops moving or the steps run out; the list is not moved back, and the result's search.steps says how far it went. Run on an Apple TV simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), selectorBy, .init(name: "text"), selectorIndex, .init(name: "search", kind: .integer, description: "Optional number of forward search steps, 1...200, for a target not yet in the snapshot.", required: false)]) {
            $0.command(["scroll"], platform: $0.physicalByDefault, options: $0.selector + $0.options([("search", "--search")], numeric: true))
        },
        .init(name: "request_handoff", description: "Ask a person to complete a step on the device (for example an unlock, a pairing or a permission). Prefer until: the device is then watched, read-only, and the call ends by itself when it shows the condition or at timeout_seconds, with no form and nothing for the person to answer. Without until it requires an MCP host supporting form elicitation.The form has no fields and asks one question, whether the step is finished, answered with the host's own Accept (yes, finished, whatever was chosen on the device) and Decline (not done). Accept acknowledges the request and does not verify device success; decline and cancel do not acknowledge. Write the message as the step alone, an instruction such as 'Answer the notification prompt', without yes/no wording of its own. The result adds formAnswer, what the host's form returned. Do not put secrets in the message. Device mutation calls are paused in this server while the response is pending.", fields: [platform, device, .init(name: "message"),
            .init(name: "until", description: "Optional. Watch the device and end by itself when it shows this, so nobody has to answer a form: unlocked (display on, no passcode required) or paired (connected and paired), physical devices only; or visible, gone, enabled, disabled, value, focused for the element that by and text name, for example until gone, by label, text Allow for a permission prompt. A step already done returns at once. Returns status observed (verified true for that condition) or timedOut.", required: false, choices: HandoffCondition.names),
            .init(name: "by", description: "With an element condition: identifier, label, or value for an element that has neither (its exact current value).", required: false, choices: ["identifier", "label", "value"]),
            .init(name: "text", description: "With an element condition: the exact selector, 1...4096 UTF-8 bytes.", required: false),
            selectorIndex,
            .init(name: "value", description: "Exact expected value, for until value.", required: false),
            .init(name: "timeout_seconds", kind: .integer, description: "With until: seconds to watch, 1...3600, default 300.", required: false)]) {
            $0.command(["handoff"], options: $0.options([("until", "--until"), ("value", "--value")]) + ($0["text"] == nil ? [] : $0.selector),
                       operands: [$0.text("message")] + ($0["timeout_seconds"] == nil ? [] : [$0.number("timeout_seconds")]))
        },
        .init(name: "inspect_device", description: "List apps on either platform, or physical details/processes/media status. Physical media-status reads native Apple media support flags, running state and session count only; it never starts/stops a stream or exports session identities/keys, and does not prove recording support.", fields: [platform, device, .init(name: "query", choices: ["apps", "details", "processes", "media-status"])], readOnly: true) { $0.command([$0.text("query")]) },
        .init(name: "get_ui_tree", description: "Read a native accessibility tree in process. Platform defaults to physical: Apple's tunnel, Network/RemoteXPC and raw AX DTX; without pid, selects/rechecks the primary portrait display-centre process and Apple display geometry, and the display must be awake. Simulator (a booted simulator by UUID): the same AX requests through CoreSimulator; without pid, selects/rechecks the frontmost application, or the process under the screen centre when the simulator reports none, on the display the interface is on (an unfolded iPhone Duo's inner display), so system overlays in other processes are not included; on an Apple TV simulator the focused node carries focused true and the result a focus object; a hierarchy too large for one snapshot, such as the Home Screen's, is read again at depth 10 within about 12 seconds and reported in shallowSnapshot. Optional positive pid may inspect a background app on either platform. Settings has scoped iPhone 13 mini verification; the probe app, Settings and the lock screen were read on one iPhone 17e simulator. Returns logical-point frames, non-atomic snapshot-local IDs and separate cleanup outcomes. No selector action or fallback.", fields: [device, .init(name: "platform", required: false, choices: ["physical", "simulator"]), .init(name: "pid", kind: .integer, description: "Optional current application PID; omitted selects the display-centre process (physical) or the frontmost application, else the screen-centre process (simulator).", required: false)], readOnly: true) {
            $0.command(["tree"], platform: $0.physicalByDefault, options: $0.options([("pid", "--pid")], numeric: true))
        },
        .init(name: "wait_for_element", description: "Wait, read-only, until one exact identifier/label selector meets a condition, using one in-process Apple AX session for the whole wait. Platform defaults to physical; on a simulator every poll without pid re-selects the frontmost application (else the screen-centre process) instead of the display-centre process. until: visible (default; exactly one matching element, visible in the snapshot), gone (no match, or every match explicitly not visible), enabled/disabled (visible plus live enabled state), value (visible plus exact string value; requires value), or focused (visible plus the live focused attribute; Apple TV focus, checked on one tvOS simulator). timeout_seconds 0...60 (default 10; 0 checks once), interval_seconds 0.25...5 (default 0.5). Without pid every poll re-selects the awake portrait primary display-centre process, so app launches and sheets are followed; with pid that app is observed even in the background, and its exit ends the wait as an error. Several distinct matches never satisfy a positive condition and are reported as ambiguous. A timeout returns status timed-out with the last observation and isError false; transport/session failure returns isError true with cleanup outcomes. No input, lease, fallback or reconnection. Each poll is a non-atomic snapshot; not yet verified on physical hardware, run on one iPhone 17e simulator.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, description: "Optional positive application PID; omitted re-selects the display-centre process (physical) or the frontmost application, else the screen-centre process (simulator) each poll.", required: false), selectorBy, .init(name: "text", description: "Exact, case-sensitive selector, 1...4096 UTF-8 bytes."), selectorIndex,
            .init(name: "until", required: false, choices: AccessibilityWait.conditionNames),
            .init(name: "value", description: "Exact expected value text for until=value.", required: false),
            .init(name: "timeout_seconds", kind: .number, description: "0...60, default 10.", required: false),
            .init(name: "interval_seconds", kind: .number, description: "0.25...5, default 0.5.", required: false)],
            readOnly: true, answerExitCodes: [0, AccessibilityWait.timeoutExitCode]) {
            $0.command(["wait"], platform: $0.physicalByDefault, options: $0.selector + $0.options([("until", "--until"), ("value", "--value")])
                + $0.options([("timeout_seconds", "--timeout"), ("interval_seconds", "--interval")], numeric: true))
        },
        .init(name: "get_screen", description: "Capture a PNG and inspect it. Auto prefers a useful AX tree (physical: app at primary display centre; simulator: frontmost application, else the screen-centre one), then Vision OCR, then explicitly reports image-only. Method can force tree or ocr. Returns coordinate space, dimensions, diagnostics, and the image. The inline image is a reduced copy by default (longest edge 1568 px, at most 1 MiB; the image_* options change that) and structuredContent.inlineImage gives its size and scale. AX uses logical points, OCR normalized bounds. Capture/analysis are sequential and non-atomic.", fields: [platform, device, .init(name: "method", required: false, choices: ["auto", "tree", "ocr"]), displayField] + imageFields, imagePath: "imagePath", imageFromResult: true) { $0.command(["screen"], options: $0.options([("display", "--display")]), operands: [$0.text("method", default: "auto")]) },
        .init(name: "decode_accessibility_archive", description: "Inspect a saved local keyed archive in process through Foundation, without connecting to a device or launching a helper. Bounded data-only structural decoding preserves unknown classes/fields, decodes nested archives, and represents opaque data by byte count. Does not instantiate archived classes, produce a parsed physical hierarchy or establish numeric attribute meanings.", fields: [.init(name: "path")], readOnly: true) { ["decode-ax-archive", "--", $0.text("path")] },
        .init(name: "screenshot", description: "Capture a PNG to a local path and return it as MCP image content. The inline image is a reduced copy by default (longest edge 1568 px, at most 1 MiB; the image_* options change that) and structuredContent.inlineImage gives its size and scale; the saved file is always the full-resolution PNG. May replace an existing local file. Simulator and awake/unlocked iPhone 13 mini USB capture verified; earlier captures before confirmed wake/unlock were black.", fields: [platform, device, .init(name: "path", description: "Local output path ending in .png; prefer ignored tmp/."), displayField] + imageFields, imagePath: "path") { $0.command(["screenshot"], options: $0.options([("display", "--display")]), operands: [$0.text("path")]) },
        .init(name: "record_screen", description: "Record a finite screen video to a new host .mp4 path. Parent must exist; existing paths refused. Duration 1...300 seconds; h264 or hevc. Physical defaults to devicectl, which may lack capability; optional recording_backend coredevice uses in-process Apple negotiation, HEVC RTP decoding with VideoToolbox and AVFoundation encoding. Native publication requires owned stop/absence and tunnel-release acknowledgements. Native RTCP receiver reports are sent to the owned peer. Experimental: reliable startup, keyframe/crash recovery and captures beyond verified durations remain incomplete or unverified. No automatic fallback, audio, or inline video. Metadata includes decoded duration/dimensions.", fields: [platform, device, .init(name: "path"), .init(name: "seconds", kind: .number), .init(name: "codec", required: false, choices: ["h264", "hevc"]), .init(name: "recording_backend", required: false, choices: ["devicectl", "coredevice"]), displayField]) {
            $0.command(["record"], options: $0.options([("recording_backend", "--backend"), ("display", "--display")]),
                       operands: [$0.text("path"), $0.number("seconds"), $0.text("codec", default: "h264")])
        },
        .init(name: "capture_frames", description: "Physical devices only: save the live screen as numbered JPEG files (frame-0001.jpg, …) plus frames.json in a host directory, from one in-process native video stream: Apple tunnel assertion and device lease, one owned AVConference screen-sharing stream, HEVC decoded with VideoToolbox, each saved frame cropped to the display's pixel size and encoded at JPEG quality 0.85. For repeated screenshots: the stream starts once (first frame about 1.3 s after the call on an iPhone 13 mini), then frames follow about every 65 ms; a single image is quicker with screenshot. Stops at count (1...1000, default 10, or 1000 with seconds alone), seconds after the first frame (0.5...300), or 1 GiB written. interval_ms (0...60000) saves one frame per interval from the first; frames are never closer than 33 ms. The directory is created if missing (parent must exist); a non-empty one is refused unless overwrite is true, which replaces same-named frames and the index. Returns per-frame file, offset, pixel size and bytes, first-frame delay, cleanup acknowledgements and lastFrame; the last frame is returned inline (reduced by the image_* options; image_include false leaves it out). Cancellation stops the stream and keeps the frames written so far, with frames.json marked interrupted. Simulators are refused: use screenshot. Sends no input. The screen-sharing indicator appears in the status bar while the stream runs.", fields: [device, .init(name: "directory", description: "Host directory for the frames; prefer tmp/."),
            .init(name: "count", kind: .integer, required: false), .init(name: "seconds", kind: .number, required: false),
            .init(name: "interval_ms", kind: .integer, required: false), .init(name: "overwrite", kind: .boolean, required: false)] + imageFields,
            imagePath: "lastFrame", imageFromResult: true) {
            $0.command(["frames"], platform: "physical", options: $0.options([("count", "--count"), ("seconds", "--seconds"), ("interval_ms", "--interval")], numeric: true)
                + ($0["overwrite"]?.boolValue == true ? ["--overwrite"] : []), operands: [$0.text("directory")])
        },
        .init(name: "tap", description: "Tap normalized current-interface coordinates 0...1, origin top left. Physical: in-process Apple CoreDevice; rechecks the awake primary display and maps orientation before input. Simulator (booted, by UUID): in-process host XPC to the simulator's dtuhidd HID daemon, with the simulator's display orientation read and mapped the same way; on an unfolded iPhone Duo the touch goes to the inner display (LCD-1) through its Universal HID touchscreen. Dispatch does not verify UI effect/release.", fields: [platform, device, x, y]) { $0.command(["tap"], operands: [$0.number("x"), $0.number("y")]) },
        .init(name: "drag", description: "Drag one contact. Current-interface normalized coordinates; duration 0.03...10 seconds. Physical: in-process Apple CoreDevice with display geometry/orientation rechecks. Simulator (booted, by UUID): host XPC to its dtuhidd, orientation mapped as on a device. Sends a complete bounded schedule followed by release/barrier. Dispatch does not prove movement or release.", fields: [platform, device, .init(name: "x1", kind: .number), .init(name: "y1", kind: .number), .init(name: "x2", kind: .number), .init(name: "y2", kind: .number), .init(name: "seconds", kind: .number)]) {
            $0.command(["drag"], operands: ["x1", "y1", "x2", "y2", "seconds"].map($0.number))
        },
        .init(name: "multi_tap", description: "Simultaneous contact and release after 80 ms at two to five normalized coordinate pairs through in-process Apple Universal HID. Platform defaults to physical; a booted simulator (by UUID) receives the same reports through its dtuhidd Universal HID service. Dispatch does not verify UI effect/release; no helper or replay.", fields: [device, optionalPlatform, .init(name: "coordinates", kind: .array, description: "Flat numeric array [x1,y1,x2,y2,...], 4...10 values.")]) {
            let numbers = ($0["coordinates"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.command(["multi-tap"], platform: $0.physicalByDefault, operands: numbers)
        },
        .init(name: "multi_drag", description: "Move two to five physical contacts along straight paths through in-process Apple CoreDevice. Current-interface normalized coordinates; duration 0.03...10 seconds. Contacts start together and release 1 ms after movement. Two-path Indigo input refuses overlapping/crossing paths; three-to-five paths use Universal HID. Platform defaults to physical; a booted simulator (by UUID) receives the same events through its dtuhidd digitizer and Universal HID services. Dispatch does not verify UI effect/release; no helper or replay.", fields: [device, optionalPlatform, .init(name: "paths", kind: .array, description: "Flat array [startX,startY,endX,endY,...], 8...20 numbers, four per contact."), .init(name: "seconds", kind: .number)]) {
            let paths = ($0["paths"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.command(["multi-drag"], platform: $0.physicalByDefault, operands: [$0.number("seconds")] + paths)
        },
        .init(name: "pinch", description: "Horizontal two-contact pinch/spread through in-process Apple CoreDevice. Current-interface normalized center; positive start/end spans are fractions of screen width and all endpoints must fit. Smaller end span pinches inward, larger spreads outward. Duration 0.03...10 seconds. Fresh display checks and complete paired lift apply; dispatch does not prove zoom/release. Platform defaults to physical; a booted simulator (by UUID) receives both contacts through its dtuhidd digitizer service. No helper or replay.", fields: [device, optionalPlatform, .init(name: "center_x", kind: .number), .init(name: "center_y", kind: .number), .init(name: "start_span", kind: .number), .init(name: "end_span", kind: .number), .init(name: "seconds", kind: .number)]) {
            $0.command(["pinch"], platform: $0.physicalByDefault, operands: ["center_x", "center_y", "start_span", "end_span", "seconds"].map($0.number))
        },
        .init(name: "type_text", description: "Type at current focus as in-process Apple Indigo keyboard events, without a helper or clipboard change. The device maps key codes to characters with its own hardware-keyboard layout, so give layout (default us; names from list_keyboard_layouts, such as spanish-iso, german, french). Accepts 1...512 characters that layout produces with Shift, Option or one dead key, plus tab and LF newline; the first character it cannot produce refuses the whole text before anything is sent. Platform defaults to physical, whose layout cannot be read (receipt deviceLayout not-read); a booted simulator's layout setting is read first, a different explicit layout is refused and hw=Automatic is reported as not checked. Caps Lock, focus and app behavior can still alter output; verify the field. No automatic replay. For other text use set_element_value, which replaces a named element's whole value, or on a physical device paste_text, which replaces the clipboard.", fields: [device, .init(name: "platform", required: false, choices: ["physical", "simulator"]), .init(name: "text"), .init(name: "layout", description: "Keyboard layout the device uses (default us); see list_keyboard_layouts.", required: false)]) {
            $0.command(["type"], platform: $0.physicalByDefault, options: $0.options([("layout", "--layout")]), operands: [$0.text("text")])
        },
        .init(name: "detect_keyboard_layout", description: "Find out which hardware-keyboard layout a device applies to typed keys, to pass as type_text's layout. Types a short probe into one settable text field selected by exact identifier or label (the press_element guards, as for set_element_value) and compares what arrives with what every keyboard layout on this Mac would type. The probe is computed from those layouts (letter, digit and punctuation keys with and without Shift; never Option, Return, Tab, space or arrows; no dead key left pending). Steps: read the field through the tree, set_element_value it to \"x\", type the probe, read it back, delete what is there with backspaces and, if it does not read as before, set the first value back; the result reports restore.status and restore.confirmed. status is detected (one layout; layoutOption gives the type option), ambiguous (several layouts the probe cannot tell apart, all listed) or no-match (with the text that arrived and hints); it never picks one silently. Autocorrection, auto-capitalisation, smart punctuation and input methods change what arrives: use a plain field with them off (the probe app's probe.text.field is the reference). On a simulator the result also reports the simulator's own setting and whether it agrees. Platform defaults to physical. Sends input; changes no setting.", fields: [device, optionalPlatform, .init(name: "pid", kind: .integer, required: false), .init(name: "by", choices: ["identifier", "label"]), .init(name: "text", description: "Exact selector of the text field, 1...4096 UTF-8 bytes."), selectorIndex]) {
            $0.command(["detect-layout"], platform: $0.physicalByDefault, options: $0.selector)
        },
        .init(name: "list_keyboard_layouts", description: "List the keyboard layout names type_text accepts: the layouts this Mac ships, with name, macOS identifier and localized name. Names match ignoring case, spaces and punctuation. Contacts no device.", fields: [], readOnly: true) { _ in ["keyboard-layouts"] },
        .init(name: "press_button", description: "Press a hardware button in process. Physical (CoreDevice/RemoteXPC): home, lock, volume-up, volume-down. Simulator (booted, by UUID; dtuhidd): the same four, plus, on an Apple Watch simulator, side (the side button, consumer usage 0x95; opened Control Center on watchOS 27.2) and action (the Apple Watch Ultra's Action button, page 0xFF01 usage 0x200; no effect on a watch without one). No helper executable. UI effect/release is not verified by dispatch; lock toggles the display.", fields: [platform, device, .init(name: "button")]) { $0.command(["button"], operands: [$0.text("button")]) },
        .init(name: "wake_device", description: "Wake a physical device whose display is off. Reads Apple's display and passcode state twice; only if the primary display is off both times, presses the side button once in process and reads the state again. If the display is then on and no passcode is required, presses Home once to leave the lock screen unless dismiss_lock_screen is false. Never presses when the display is on or its state is unknown, never repeats the press, never enters a passcode. Returns status already-awake, awake, awake-locked, not-awake or unknown-display-state with the observed display power; an awake display does not prove the UI is unlocked, so inspect afterward. Observed once on an iPhone 13 mini without a passcode.", fields: [device, .init(name: "dismiss_lock_screen", kind: .boolean, required: false)], answerExitCodes: [0, 1]) {
            $0.command([DirectPhysicalWake.operation], platform: "physical", options: $0["dismiss_lock_screen"]?.boolValue == false ? [DirectPhysicalWake.noDismissFlag] : [])
        },
        .init(name: "press_key", description: "Send one named key as in-process Apple Indigo HID: return, escape, backspace, tab, space, up, down, left, right. Platform defaults to physical (CoreDevice); a booted simulator receives it through its dtuhidd keyboard service. Uses the currently focused field; does not focus, type arbitrary text or paste. One down/up and transport barriers; UI effect/release remain unverified by dispatch. No helper executable or automatic replay.", fields: [device, optionalPlatform, .init(name: "key", choices: ["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"])]) { $0.command(["key"], platform: $0.physicalByDefault, operands: [$0.text("key")]) },
        .init(name: "paste_text", description: "Physical Unicode paste using Apple devicectl clipboard copy and in-process CoreDevice Command+V. Replaces the device clipboard, then sends one paste sequence at the focused caret/selection. Does not focus a field, select all, submit, restore the clipboard, or retry. 1...65536 UTF-8 bytes without NUL. A permission prompt may interpose; inspect the field to verify insertion. No third-party helper executable.", fields: [device, .init(name: "text")]) {
            $0.command(["paste"], platform: "physical", operands: [$0.text("text")])
        },
        .init(name: "long_press", description: "Hold one touch at current-interface normalized x/y for 0.1...10 seconds, then release. Platform defaults to physical (in-process Apple CoreDevice, with primary display geometry/orientation rechecks); a booted simulator receives it through its dtuhidd digitizer service, orientation mapped as on a device. App gesture thresholds vary; receipt does not verify effect/release. No helper executable, replay or AX fallback. Process/transport interruption can prevent release.", fields: [device, optionalPlatform, .init(name: "x", kind: .number), .init(name: "y", kind: .number), .init(name: "seconds", kind: .number)]) {
            $0.command(["long-press"], platform: $0.physicalByDefault, operands: [$0.number("x"), $0.number("y"), $0.number("seconds")])
        },
        .init(name: "perform_gesture", description: "Send one bounded touch sequence through in-process Apple Universal HID; no helper executable. Platform defaults to physical; a booted simulator (by UUID) receives the same reports through its dtuhidd Universal HID service. sequence is JSON {frames:[{ms:integer,touches:[{id:integer,x:number,y:number}]}]}; 2...512 complete-state frames, first ms=0 with a touch, strictly increasing times through 10000 ms, last touches empty. IDs form 0...N-1, N<=5. Coordinates normalized in the current interface, with fresh display checks. Omitted contacts release at their last position; IDs may touch again. Supports sampled paths, holds, and repeated taps with no automatic interpolation or replay. Dispatch does not verify effect, timing, or release.", fields: [device, optionalPlatform, .init(name: "sequence", description: "JSON sequence, maximum 65536 UTF-8 bytes; each frame lists all active touches.")]) {
            $0.command(["gesture"], platform: $0.physicalByDefault, operands: [$0.text("sequence")])
        },
        .init(name: "app_action", description: "Install, uninstall, launch, terminate an app, or open a URL. Value is a host app path for install, a URL for open-url, a positive PID for physical terminate, otherwise a bundle identifier. Uninstall deletes app data.", fields: [platform, device, .init(name: "operation", choices: ["install", "uninstall", "launch", "terminate", "open-url"]), .init(name: "value")]) { $0.command([$0.text("operation")], operands: [$0.text("value")]) },
        .init(name: "app_data", description: "Physical app-container listing or raw pull/push. Remote paths are relative; '.' means root. Listing is nonrecursive. Copies may overwrite selected destinations; app access is permission-dependent and unverified live. Not .xcappdata export/replacement.", fields: [device, .init(name: "operation", choices: ["files", "pull", "push"]), .init(name: "bundle_id"), .init(name: "remote_path"), .init(name: "local_path", required: false)]) {
            let op = $0.text("operation")
            let paths = op == "files" ? [$0.text("remote_path")] : (op == "pull" ? [$0.text("remote_path"), $0.text("local_path")] : [$0.text("local_path"), $0.text("remote_path")])
            return $0.command(["files", op == "files" ? "list" : op], platform: "physical", operands: [$0.text("bundle_id")] + paths)
        },
        .init(name: "list_reports", description: "List saved physical report metadata without recursion. Optional relative directory, default '.'. Live listing verified; does not read contents.", fields: [device, .init(name: "directory", required: false)], readOnly: true) { $0.command(["reports", "list"], platform: "physical", operands: [$0.text("directory", default: ".")]) },
        .init(name: "download_report", description: "Download a selected saved physical report to a host path. May overwrite that destination. Download unverified live; no parsing or symbolication.", fields: [device, .init(name: "remote_path"), .init(name: "local_path")]) { $0.command(["reports", "get"], platform: "physical", operands: [$0.text("remote_path"), $0.text("local_path")]) },
        .init(name: "build_run", description: "Build an iOS Xcode project/workspace, install and restart its app. Executes the project's build scripts. Explicit scheme required; configuration defaults Debug. Physical builds use signing assets already on the Mac unless allow_provisioning_updates is true, which lets Xcode use the developer account signed in to Xcode to create or change certificates, app IDs and profiles on Apple's developer services; allow_device_registration additionally registers the device with the team. Both are physical-only, off by default; ask the user before enabling. Physical signing/deployment unverified. Requires xcsift. Does not verify UI health.", fields: [platform, device, .init(name: "project"), .init(name: "scheme"), .init(name: "configuration", required: false), .init(name: "app_target", required: false),
            .init(name: "allow_provisioning_updates", kind: .boolean, description: "Physical only. Pass -allowProvisioningUpdates: Xcode contacts Apple's developer services with the user's account and may create or update certificates, app IDs and provisioning profiles.", required: false),
            .init(name: "allow_device_registration", kind: .boolean, description: "Physical only; requires allow_provisioning_updates. Pass -allowProvisioningDeviceRegistration: Xcode may register this device in the user's developer account.", required: false)]) {
            $0.command(["build-run"], options: $0.options([("configuration", "--configuration"), ("app_target", "--app-target")])
                + ($0["allow_provisioning_updates"]?.boolValue == true ? [BuildRunCommand.provisioningUpdatesFlag] : [])
                + ($0["allow_device_registration"]?.boolValue == true ? [BuildRunCommand.deviceRegistrationFlag] : []),
                operands: [$0.text("project"), $0.text("scheme")])
        },
        .init(name: "simulator_state", description: "Boot or shut down a selected simulator. Shutdown interrupts running apps; no erase or delete operation is exposed.", fields: [device, .init(name: "operation", choices: ["boot", "shutdown"])]) { $0.command([$0.text("operation")], platform: "simulator") },
        .init(name: "ocr_image", description: "Recognize text in a local image using Vision. Normalized top-left bounds. Recognition verified on one simulator fixture; broad accuracy remains unverified.", fields: [.init(name: "path")], readOnly: true) { ["ocr", "--", $0.text("path")] }
    ] + appDiagnostics + otherFamilies

    /// A simulator's display for captures (screenshot, get_screen, record_screen).
    static let displayField = MCPField(name: "display", description: "Simulator only: the display to capture, by name (LCD-1), device name (primary-1) or screen ID (3) from list_displays. Default: the display the interface is on (the primary one, or LCD-1 while an iPhone Duo is unfolded). get_screen describes any other display by OCR only.", required: false)

    /// Displays, the Apple TV remote and the Digital Crown (docs/other-families.md).
    static let otherFamilies: [MCPToolDefinition] = [
        .init(name: "list_displays", description: "Simulator only: list a booted simulator's displays from its display information (dtdeviceinfod): screen ID, name, device name, type, pixel and point size, backlight state, active flag, current orientation, whether it is primary and whether it can be captured. An iPhone Duo lists two integrated displays (LCD, primary; LCD-1). interfaceDisplay is the one trees, waits, actions, touch and default captures follow: the primary display, or the one awake integrated display when that is another one (LCD-1 while the Duo is unfolded). Captures take display to choose another. On a foldable simulator, hinge gives one angle sample and a posture (closed, partially-open, flat) that manzanero derives from it. Read-only.", fields: [device], readOnly: true) {
            $0.command(["displays"], platform: "simulator")
        },
        .init(name: "run_batch", description: "Run several commands for one device in one call, in the order given, instead of one tool call per step. steps is an array of commands; each command is an array of the words of one manzanero CLI command without its target, for example [[\"press\",\"--id\",\"login\"],[\"type\",\"hello\"],[\"wait\",\"--label\",\"Welcome\",\"--timeout\",\"5\"]]. At most 30 steps. Every step is checked before any runs, so a mistake in a later step sends nothing. Each step then runs exactly as it would alone, with the same guards, lease and quarantine; the batch stops at the first step that fails or exits non-zero (a wait that times out), and returns one result per step that ran, failedStep, and the steps not run. Earlier steps are not undone and nothing is repeated: inspect the device before continuing. handoff and another batch cannot be steps. The CLI words are those of `manzanero --help`, not MCP tool names.", fields: [platform, device, .init(name: "steps", kind: .commandArray, description: "The commands, each an array of CLI words without --device or --simulator.")], answerExitCodes: [0, 1]) { arguments in
            let steps = (arguments["steps"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
            let json = (try? JSONSerialization.data(withJSONObject: steps)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            return arguments.command(["batch"], operands: [json])
        },
        .init(name: "press_remote",description: "Apple TV: press one Siri Remote button in process. platform defaults to simulator (booted, by UUID; the simulator's dtuhidd); physical sends the same usages over CoreDevice to an Apple TV, after reading from its details that it is one. Any call to a sleeping physical Apple TV may switch it on, and its television with it. up/down/left/right move focus and select clicks the focused item (keyboard usages, which tvOS treats as the remote's arrows and click); menu goes back one level (consumer 0x46), home opens the Home Screen (consumer 0x40) and play-pause toggles playback (consumer 0xCD). Apple TV has no touch screen: tap and other touch tools are refused there. Another family is refused before any input. Dispatch does not verify the UI effect; inspect the tree or a screenshot.", fields: [device, .init(name: "platform", description: "simulator (default) or physical.", required: false, choices: ["physical", "simulator"]), .init(name: "button", choices: AppleTVRemote.names), .init(name: "hold_seconds", kind: .number, description: "Optional long press, 0.08...3 seconds, for home, menu or play-pause on an Apple TV simulator; 1.5 on home opens Control Centre. Refused on a physical device.", required: false)]) {
            $0.command(["remote"], platform: $0.text("platform", default: "simulator"),
                       options: $0.options([("hold_seconds", "--hold")], numeric: true), operands: [$0.text("button")])
        },
        .init(name: "rotate_crown", description: "Apple Watch simulator only (booted, by UUID): turn the Digital Crown in process through the simulator's dtuhidd scroll service. units is a non-zero integer, -10000...10000; positive scrolls toward later content. It is sent as events 1 s apart, slow enough that watchOS does not accelerate them; events (1...20, default the fewest of at most 1000 units) splits it evenly. Measured on a watchOS 27.2 simulator: 200 units moved a SwiftUI digitalCrownRotation value by 1 at low sensitivity; Watch Settings' list moved one row per event of 100 units or more and not at all for smaller events, so scroll lists with events. Another family or a physical device is refused before any input. Dispatch does not verify the effect; inspect the tree.", fields: [device, .init(name: "units", kind: .integer), .init(name: "events", kind: .integer, required: false)]) {
            $0.command(["crown"], platform: "simulator", options: $0.options([("events", "--events")], numeric: true), operands: [$0.number("units")])
        },
        .init(name: "fold_device", description: "Foldable simulator only (iPhone Duo, booted, by UUID): fold closes the hinge (0 degrees) and waits until the outer display LCD is awake and the inner LCD-1 off; unfold opens it (180 degrees) and waits for the inner display, where the interface is in landscape. One vendor-defined HID event (the one Device Hub's hinge control sends) through the simulator's dtuhidd, then display-information reads every 250 ms for at most 10 s. The result names activeDisplay and says whether it was observed (displayObserved). A simulator without two integrated displays, or a physical device, is refused before any input.", fields: [device, .init(name: "state", choices: ["fold", "unfold"])]) {
            $0.command([$0.text("state")], platform: "simulator")
        },
        .init(name: "set_hinge_angle", description: "Foldable simulator only (iPhone Duo, booted, by UUID): set the hinge to degrees, 0 (closed) ... 180 (fully open); the simulator animates to it. Whether an intermediate angle swaps the active display depends on the path (0 to 110 in one step unfolded, small steps to 110 did not), so the result only reports the display awake right after sending; use fold_device for a confirmed display. Refused on other simulators and physical devices before any input.", fields: [device, .init(name: "degrees", kind: .number)]) {
            $0.command(["hinge"], platform: "simulator", operands: [$0.number("degrees")])
        },
        .init(name: "get_hinge_angle", description: "Foldable simulator only (iPhone Duo, booted, by UUID): read the hinge angle once from CoreDevice's hinge-angle stream on the simulator's dtdeviceinfod (the first sample, then the stream is closed): angle, mechanicalAngle, minAngle (0), maxAngle (180), velocity and isAngleValid, in degrees, with the integrated display awake (activeDisplay) and a posture derived by manzanero (closed up to 5 degrees, flat from 175, else partially-open; not reported by the simulator). 0 is closed, 180 fully open. Read-only; other simulators and physical devices are refused.", fields: [device], readOnly: true) {
            $0.command(["hinge"], platform: "simulator")
        },
    ]

    /// `logs`, `console` and `last-crash` (docs/app-logs.md).
    static let appDiagnostics: [MCPToolDefinition] = [
        .init(name: "capture_logs", description: "Simulator only: a finite capture of one app's unified-log (os_log/Logger) entries through Apple's log tool inside a booted simulator (simctl spawn … log stream|show --style ndjson). Give exactly one time selection: seconds (1...60, stream from now), last_seconds (1...3600, persisted entries; debug entries are not persisted, so capture debug live) or start [end] (ISO-8601). Give exactly one target: bundle_id (matched by its installed .app path, which survives relaunches), pid or process. Optional subsystem, category (needs subsystem) and level default|info|debug (default: default). Bounded by max_entries (default 2000, at most 10000) and max_bytes (default 1 MiB, at most 8 MiB); stopReason says duration, complete, entryLimit or byteLimit, and truncated says whether entries were dropped. The tool builds the predicate; no raw predicate is accepted. Optional output writes every kept entry as NDJSON to a new host file and returns only the newest 50 inline. Captured messages can contain private data in clear text. Physical devices are not supported. Verified on one iPhone Air simulator (iOS 27.2).", fields: [
            device,
            .init(name: "seconds", kind: .integer, description: "Stream from now for 1...60 seconds.", required: false),
            .init(name: "last_seconds", kind: .integer, description: "Query the last 1...3600 seconds of persisted entries.", required: false),
            .init(name: "start", description: "ISO-8601 start of a persisted window.", required: false),
            .init(name: "end", description: "ISO-8601 end of the window; needs start.", required: false),
            .init(name: "bundle_id", required: false), .init(name: "pid", kind: .integer, required: false), .init(name: "process", required: false),
            .init(name: "subsystem", required: false), .init(name: "category", required: false),
            .init(name: "level", required: false, choices: LogCapture.Level.allCases.map(\.rawValue)),
            .init(name: "max_entries", kind: .integer, required: false), .init(name: "max_bytes", kind: .integer, required: false),
            .init(name: "output", description: "New host .ndjson path; its parent must exist.", required: false)], readOnly: true) { arguments in
            arguments.command(["logs"], platform: "simulator", options: arguments.options([("seconds", "--seconds"), ("last_seconds", "--last"), ("pid", "--pid"),
                                                                                            ("max_entries", "--max-entries"), ("max_bytes", "--max-bytes")], numeric: true)
                + arguments.options([("start", "--start"), ("end", "--end"), ("bundle_id", "--bundle"), ("process", "--process"), ("subsystem", "--subsystem"),
                                     ("category", "--category"), ("level", "--level"), ("output", "--output")]))
        },
        .init(name: "capture_console", description: "Launch (relaunching if running) an app and return byte-bounded tails of its stdout and stderr. seconds 1...60; max_bytes per stream 1024...1048576 (default 65536). os_log true sets OS_ACTIVITY_DT_MODE so the app's own os_log lines at info level and above are mirrored to its stderr (one line each, category but no level or subsystem; debug lines are not mirrored). app_arguments are passed to the app. Simulator: simctl launch with stdout/stderr redirected to host files under tmp/ (paths returned); waits until the app exits or seconds pass; the app keeps running unless terminate is true. Print output that the app never flushes is lost in this mode. exitStatus is null because simctl does not report how the app ended; use latest_crash. Physical (checked on one iPhone; an app that crashes returns its output with appEndedAbnormally and the signal in exitStatus): devicectl launch --console; at seconds the app is always ended by a forwarded SIGINT; output includes devicectl's own status lines, appOutputObserved/captured say whether anything else arrived, and an empty capture does not prove the app printed nothing. Launches an app, so it is not read-only.", fields: [
            platform, device, .init(name: "bundle_id"), .init(name: "seconds", kind: .integer),
            .init(name: "max_bytes", kind: .integer, required: false), .init(name: "os_log", kind: .boolean, required: false),
            .init(name: "terminate", kind: .boolean, required: false),
            .init(name: "app_arguments", kind: .stringArray, description: "Arguments passed to the app, at most 64.", required: false)]) { arguments in
            // The bundle precedes `--`, which here starts the app's own arguments.
            let options = arguments.options([("seconds", "--seconds"), ("max_bytes", "--max-bytes")], numeric: true)
                + (arguments["os_log"]?.boolValue == true ? ["--os-log"] : []) + (arguments["terminate"]?.boolValue == true ? ["--terminate"] : [])
            return arguments.command(["console"], options: options + [arguments.text("bundle_id")],
                                     operands: (arguments["app_arguments"]?.arrayValue ?? []).compactMap(\.stringValue))
        },
        .init(name: "latest_crash", description: "The newest crash report (bug type 309) for one app, as a parsed summary: exception type, signal, termination reason, crash messages, the crashed thread's top 12 frames (image, offset, symbol when the report has one; no further symbolication) and the report path. Give exactly one of bundle_id or process; since (ISO-8601) excludes older reports. Simulator: reads the reports the simulator left on the Mac (platform 7), excluding ones whose process path names another simulator; a report can take a few seconds to appear after the crash. Physical: lists the device's crash logs, downloads at most the newest 5 candidates into tmp/ until one matches (download route not yet verified on hardware). Optional download copies the report into an existing host directory. Returns found false when nothing matches.", fields: [
            platform, device, .init(name: "bundle_id", required: false), .init(name: "process", required: false),
            .init(name: "since", required: false), .init(name: "download", description: "Existing host directory to copy the report into.", required: false)], readOnly: true) { arguments in
            arguments.command(["last-crash"], options: arguments.options([("bundle_id", "--bundle"), ("process", "--process"), ("since", "--since"), ("download", "--download")]))
        },
    ]

    /// Per-request control of the inline image on tools that return one. The
    /// saved file is never affected; these only shape what travels in the result.
    static let imageFields: [MCPField] = [
        .init(name: "image_include", kind: .boolean, description: "False leaves the inline image out (the PNG is still saved and its path returned). Default true.", required: false),
        .init(name: "image_max_edge", kind: .integer, description: "Longest edge of the inline image in pixels, \(InlineImage.Options.edgeRange.lowerBound)...\(InlineImage.Options.edgeRange.upperBound), default \(InlineImage.defaultEdge), which keeps interface text readable. Smaller costs less; \(InlineImage.Options.edgeRange.upperBound) asks for the saved resolution.", required: false),
        .init(name: "image_format", description: "auto (default): lossless PNG when it fits image_max_bytes, otherwise JPEG. png: always lossless, shrinking further if needed. jpeg: always lossy and small.", required: false, choices: InlineImage.Format.allCases.map(\.rawValue)),
        .init(name: "image_quality", kind: .number, description: "JPEG quality 0.1...1, default 0.8. Not allowed with image_format png.", required: false),
        .init(name: "image_max_bytes", kind: .integer, description: "Cap on the encoded inline image in bytes, \(InlineImage.Options.byteRange.lowerBound)...\(InlineImage.Options.byteRange.upperBound), default \(InlineImage.defaultByteLimit). The image is converted, then downscaled, until it fits; base64 adds about a third in transit.", required: false)
    ]

    /// Reads and range-checks the image options before anything is captured.
    static func imageOptions(_ arguments: [String: Value]) throws -> InlineImage.Options {
        var options = InlineImage.Options()
        func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = arguments[key] else { return nil }
            guard case .int(let number) = value, range.contains(number) else {
                throw MCPError.invalidParams("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return number
        }
        if let include = arguments["image_include"]?.boolValue { options.include = include }
        if let edge = try integer("image_max_edge", in: InlineImage.Options.edgeRange) { options.maximumEdge = edge }
        if let limit = try integer("image_max_bytes", in: InlineImage.Options.byteRange) { options.byteLimit = limit }
        if let format = arguments["image_format"]?.stringValue.flatMap(InlineImage.Format.init(rawValue:)) { options.format = format }
        if let value = arguments["image_quality"] {
            let quality: Double? = if case .double(let number) = value { number } else if case .int(let number) = value { Double(number) } else { nil }
            guard let quality, InlineImage.Options.qualityRange.contains(quality) else {
                throw MCPError.invalidParams("image_quality must be a number in 0.1...1")
            }
            guard options.format != .png else { throw MCPError.invalidParams("image_quality does not apply with image_format png") }
            options.quality = quality
        }
        return options
    }

    static func call(name: String, arguments: [String: Value], execute: @Sendable ([String]) async throws -> CommandOutput) async throws -> CallTool.Result {
        guard let definition = definitions.first(where: { $0.name == name }) else { throw MCPError.invalidParams("Unknown tool: \(name)") }
        let command = try definition.command(arguments)
        let imageOptions = definition.imagePath == nil ? InlineImage.Options() : try imageOptions(arguments)
        do {
            let output = try await execute(command)
            let value = try? JSONDecoder().decode(Value.self, from: output.data)
            var content: [Tool.Content] = [.text(text: String(decoding: output.data, as: UTF8.self), annotations: nil, _meta: nil)]
            var structured: [String: Value] = [:]
            if let value { structured["result"] = value }
            if output.exitCode == 0, let key = definition.imagePath,
               let path = (definition.imageFromResult ? value?.objectValue?[key] : arguments[key])?.stringValue {
                let outcome = try InlineImage.attachment(for: URL(fileURLWithPath: path), options: imageOptions)
                switch outcome {
                case .attached(let attachment):
                    content.append(.image(data: attachment.data.base64EncodedString(), mimeType: attachment.mimeType, annotations: nil, _meta: nil))
                    if let note = attachment.note { content.append(.text(text: note, annotations: nil, _meta: nil)) }
                case .omitted(let reason):
                    content.append(.text(text: reason, annotations: nil, _meta: nil))
                }
                // The same facts as data: an agent that reads pixel positions
                // off the inline image needs its size and scale to compute with.
                structured["inlineImage"] = try JSONDecoder().decode(Value.self,
                    from: JSONSerialization.data(withJSONObject: outcome.description, options: [.sortedKeys]))
            }
            return .init(content: content, structuredContent: structured.isEmpty ? nil : .object(structured),
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
