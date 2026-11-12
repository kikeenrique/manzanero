import Foundation
import MCP

struct MCPField: Sendable {
    enum Kind: String, Sendable { case string, number, integer, array }
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
        case (.number, .int), (.integer, .int): valid = true
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
        let args = [platform ?? text("platform"), text("device")] + operands
        let paired = self["pairing_file"]?.stringValue.map { ["--pairing-file", $0] + args } ?? args
        if let backend = self["backend"]?.stringValue { return ["--physical-backend", backend] + paired }
        return paired
    }
}

enum MCPTools {
    private static let platform = MCPField(name: "platform", choices: ["physical", "simulator"])
    private static let device = MCPField(name: "device", description: "Explicit target identifier; use the UDID from list_devices.")
    private static let pairing = MCPField(name: "pairing_file", description: "Existing private pairing file for physical idevice operations only; pair using the CLI first.", required: false)
    private static let inputBackend = MCPField(name: "backend", description: "Physical input only: idevice (default) or coredevice (optional native Apple framework/ipb helper). Never automatically retries with another backend.", required: false, choices: ["idevice", "coredevice"])
    private static let x = MCPField(name: "x", kind: .number)
    private static let y = MCPField(name: "y", kind: .number)

    static let definitions: [MCPToolDefinition] = [
        .init(name: "list_devices", description: "List CoreDevice or available simulator inventory. Physical inventory may also include simulators.", fields: [platform], readOnly: true) {
            ["devices", $0.text("platform") == "physical" ? "physical" : "simulators"]
        },
        .init(name: "doctor", description: "Check Xcode and discovery services; does not verify input delivery or optional backends.", fields: [], readOnly: true) { _ in ["doctor"] },
        .init(name: "press_element", description: "Press one physical AX element by exact identifier or label. Requires current application PID and idevice. Fresh unique target, displayed-process, portrait display, live enabled/visible, frame, and exact centre-hit checks precede one native press. No coordinate fallback or automatic retry. Native acceptance does not verify UI effect; inspect afterward.", fields: [device, .init(name: "pid", kind: .integer), .init(name: "by", choices: ["identifier", "label"]), .init(name: "text"), pairing]) {
            $0.deviceCommand([$0.text("by") == "identifier" ? "press-id" : "press-label", $0.number("pid"), $0.text("text")], platform: "physical")
        },
        .init(name: "device_readiness", description: "Read physical Developer Mode, developer-image services, connection, and pairing state. Returns actionable preparation issues. PrerequisitesPresent does not verify UI Automation, HID, or capture.", fields: [device], readOnly: true) { $0.deviceCommand(["readiness"], platform: "physical") },
        .init(name: "request_handoff", description: "Ask a person to complete a step on the device (for example Face ID or a permission). Requires an MCP host supporting form elicitation. Only an explicit completed checkbox acknowledges the request; it does not verify device success. Do not put secrets in the message. Device mutation calls are paused in this server while the response is pending.", fields: [platform, device, .init(name: "message")]) { $0.deviceCommand(["handoff", $0.text("message")]) },
        .init(name: "inspect_device", description: "List apps on either platform, or physical details/processes/HID surfaces. hid-info requires the experimental idevice bridge; pairing_file applies only to hid-info.", fields: [platform, device, .init(name: "query", choices: ["apps", "details", "processes", "hid-info"]), pairing], readOnly: true) { $0.deviceCommand([$0.text("query")]) },
        .init(name: "get_ui_tree", description: "Read an accessibility tree. Default platform simulator uses AXe. Physical requires an explicit positive pid and the idevice bridge; returns a non-atomic native AX snapshot with snapshot-local path IDs, not reusable action handles. Explicit PID may select a background app. No selector action is submitted.", fields: [device, .init(name: "platform", required: false, choices: ["simulator", "physical"]), .init(name: "pid", kind: .integer, description: "Required only for physical: current application PID from processes or launch.", required: false), pairing], readOnly: true) {
            $0.deviceCommand(["tree"] + ($0["pid"] == nil ? [] : [$0.number("pid")]), platform: $0.text("platform", default: "simulator"))
        },
        .init(name: "get_screen", description: "Capture a PNG and inspect it. Auto prefers a useful simulator AXe hierarchy, then Vision OCR, then explicitly reports image-only. Physical auto uses OCR; explicit-PID physical trees are a separate get_ui_tree operation. Method can force tree (simulator) or ocr. Returns coordinate space, dimensions, diagnostics, and image content up to 8 MiB. Capture/analysis are sequential, not an atomic UI snapshot.", fields: [platform, device, .init(name: "method", required: false, choices: ["auto", "tree", "ocr"])], imagePath: "imagePath", imageFromResult: true) { $0.deviceCommand(["screen", $0.text("method", default: "auto")]) },
        .init(name: "get_accessibility_archive", description: "Experimental physical callback archive, not a parsed UI tree. Returns parsedHierarchy:false. Requires idevice. Optional path saves a new private .plist file and returns metadata instead of base64. USB callback acquisition and correlated disable reply verified on iPhone 13 mini; payload semantics remain under investigation.", fields: [device, pairing, .init(name: "path", description: "New local .plist destination; parent must exist. Prefer ignored tmp/.", required: false)]) {
            $0.deviceCommand(["ax-snapshot"] + ($0["path"]?.stringValue.map { [$0] } ?? []), platform: "physical")
        },
        .init(name: "decode_accessibility_archive", description: "Inspect a saved local keyed archive through the optional idevice bridge, without connecting to a device. Bounded structural decoding preserves unknown classes/fields, decodes nested archives, and represents opaque data by byte count. Does not produce a parsed physical hierarchy or establish numeric attribute meanings.", fields: [.init(name: "path")], readOnly: true) { ["decode-ax-archive", $0.text("path")] },
        .init(name: "screenshot", description: "Capture a PNG to a local path and return it as MCP image content if at most 8 MiB. May replace an existing local file. Simulator and awake/unlocked iPhone 13 mini USB capture verified; earlier captures before confirmed wake/unlock were black.", fields: [platform, device, .init(name: "path", description: "Local output path ending in .png; prefer ignored tmp/.")], imagePath: "path") { $0.deviceCommand(["screenshot", $0.text("path")]) },
        .init(name: "record_screen", description: "Record a finite screen video to a new host .mp4 path. Parent directory must exist. Duration 1...300 seconds; default h264, optional hevc. Returns duration/dimensions after decoding a frame; no inline video. Uses Xcode capture tools, not the idevice bridge. Simulator capture verified; native physical capture requires device capability and may be unsupported.", fields: [platform, device, .init(name: "path"), .init(name: "seconds", kind: .number), .init(name: "codec", required: false, choices: ["h264", "hevc"])]) {
            $0.deviceCommand(["record", $0.text("path"), $0.number("seconds"), $0.text("codec", default: "h264")])
        },
        .init(name: "tap", description: "Tap coordinates. Physical coordinates are normalized 0...1; simulator coordinates are interface points. Optional physical backend coredevice uses the native Apple framework helper. Dispatch is not verified delivery.", fields: [platform, device, x, y, pairing, inputBackend]) { $0.deviceCommand(["tap", $0.number("x"), $0.number("y")]) },
        .init(name: "tap_element", description: "Tap a simulator element by accessibility label or ID using AXe. Inspect a fresh tree to verify its effect.", fields: [device, .init(name: "selector_type", choices: ["label", "id"]), .init(name: "selector")]) { $0.deviceCommand(["tap-" + $0.text("selector_type"), $0.text("selector")], platform: "simulator") },
        .init(name: "drag", description: "Drag from start to end over seconds. Physical coordinates are normalized; simulator coordinates are interface points. Physical duration 0.03...10 seconds; simulator restrictions come from AXe. Optional physical backend coredevice uses the native Apple framework helper.", fields: [platform, device, .init(name: "x1", kind: .number), .init(name: "y1", kind: .number), .init(name: "x2", kind: .number), .init(name: "y2", kind: .number), .init(name: "seconds", kind: .number), pairing, inputBackend]) {
            $0.deviceCommand(["drag"] + ["x1", "y1", "x2", "y2", "seconds"].map($0.number))
        },
        .init(name: "multi_tap", description: "Physical simultaneous contact and release at two to five normalized coordinate pairs. Does not implement moving multitouch.", fields: [device, .init(name: "coordinates", kind: .array, description: "Flat numeric array [x1,y1,x2,y2,...], 4...10 values."), pairing]) {
            let numbers = ($0["coordinates"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.deviceCommand(["multi-tap"] + numbers, platform: "physical")
        },
        .init(name: "multi_drag", description: "Physical coordinated movement of two to five contacts along straight paths. Normalized top-left coordinates; duration 0.03...10 seconds. Optional native backend coredevice has scoped two-contact map zoom verification; idevice effects and three-to-five-contact behavior remain unverified. Attempts release after dispatch/failure; receipt does not verify delivery.", fields: [device, .init(name: "paths", kind: .array, description: "Flat array [startX,startY,endX,endY,...], 8...20 numbers, four per contact."), .init(name: "seconds", kind: .number), pairing, inputBackend]) {
            let paths = ($0["paths"]?.arrayValue ?? []).map { value -> String in
                if case .int(let n) = value { return String(n) }; if case .double(let n) = value { return String(n) }; return ""
            }
            return $0.deviceCommand(["multi-drag", $0.number("seconds")] + paths, platform: "physical")
        },
        .init(name: "pinch", description: "Physical horizontal two-contact pinch/spread around a normalized center. Positive start/end spans are fractions of screen width and both endpoints must fit the screen. Smaller end span pinches inward; larger spreads outward. Duration 0.03...10 seconds. Optional native backend coredevice has scoped Maps verification; default idevice effects remain unverified. Dispatch does not prove zoom.", fields: [device, .init(name: "center_x", kind: .number), .init(name: "center_y", kind: .number), .init(name: "start_span", kind: .number), .init(name: "end_span", kind: .number), .init(name: "seconds", kind: .number), pairing, inputBackend]) {
            $0.deviceCommand(["pinch"] + ["center_x", "center_y", "start_span", "end_span", "seconds"].map($0.number), platform: "physical")
        },
        .init(name: "type_text", description: "Type literal text. Platform defaults to simulator, using AXe's US mapping. Experimental physical typing accepts 1...512 printable US-layout ASCII characters, tab, and LF newline through an owned idevice keyboard. Physical output/layout remain unverified. For physical Unicode use paste_text, which replaces the device clipboard. pairing_file applies only to physical.", fields: [device, .init(name: "platform", required: false, choices: ["physical", "simulator"]), .init(name: "text"), pairing]) { $0.deviceCommand(["type", $0.text("text")], platform: $0.text("platform", default: "simulator")) },
        .init(name: "press_button", description: "Press a hardware button. Physical supports home, lock, volume-up, volume-down; simulator uses AXe button names. Optional physical backend coredevice uses the native Apple framework helper.", fields: [platform, device, .init(name: "button"), pairing, inputBackend]) { $0.deviceCommand(["button", $0.text("button")]) },
        .init(name: "press_key", description: "Send one physical key: return, escape, backspace, tab, space, up, down, left, right. Optional backend coredevice uses the native Apple keyboard helper; default idevice remains experimental.", fields: [device, .init(name: "key", choices: ["return", "escape", "backspace", "tab", "space", "up", "down", "left", "right"]), pairing, inputBackend]) { $0.deviceCommand(["key", $0.text("key")], platform: "physical") },
        .init(name: "paste_text", description: "Physical Unicode paste through the native CoreDevice helper. Replaces the device clipboard, then sends one paste sequence at the focused caret/selection. Does not focus a field, select all, submit, restore the clipboard, or retry. 1...65536 UTF-8 bytes without NUL. A permission prompt may interpose; inspect the field to verify insertion.", fields: [device, .init(name: "text")]) {
            ["--physical-backend", "coredevice"] + $0.deviceCommand(["paste", $0.text("text")], platform: "physical")
        },
        .init(name: "app_action", description: "Install, uninstall, launch, terminate an app, or open a URL. Value is a host app path for install, a URL for open-url, a positive PID for physical terminate, otherwise a bundle identifier. Uninstall deletes app data.", fields: [platform, device, .init(name: "operation", choices: ["install", "uninstall", "launch", "terminate", "open-url"]), .init(name: "value")]) { $0.deviceCommand([$0.text("operation"), $0.text("value")]) },
        .init(name: "app_data", description: "Physical app-container listing or raw pull/push. Remote paths are relative; '.' means root. Listing is nonrecursive. Copies may overwrite selected destinations; app access is permission-dependent and unverified live. Not .xcappdata export/replacement.", fields: [device, .init(name: "operation", choices: ["files", "pull", "push"]), .init(name: "bundle_id"), .init(name: "remote_path"), .init(name: "local_path", required: false)]) {
            let op = $0.text("operation"), base = [op, $0.text("bundle_id")]
            let paths = op == "files" ? [$0.text("remote_path")] : (op == "pull" ? [$0.text("remote_path"), $0.text("local_path")] : [$0.text("local_path"), $0.text("remote_path")])
            return $0.deviceCommand(base + paths, platform: "physical")
        },
        .init(name: "list_reports", description: "List saved physical report metadata without recursion. Optional relative directory, default '.'. Live listing verified; does not read contents.", fields: [device, .init(name: "directory", required: false)], readOnly: true) { $0.deviceCommand(["reports", $0.text("directory", default: ".")], platform: "physical") },
        .init(name: "download_report", description: "Download a selected saved physical report to a host path. May overwrite that destination. Download unverified live; no parsing or symbolication.", fields: [device, .init(name: "remote_path"), .init(name: "local_path")]) { $0.deviceCommand(["report", $0.text("remote_path"), $0.text("local_path")], platform: "physical") },
        .init(name: "capture_logs", description: "Experimental finite physical OS trace via idevice. 1...30 seconds after startup, max 2000 entries/4 MiB of entry JSON. Optional positive PID. Live capture unverified.", fields: [device, .init(name: "seconds", kind: .integer), .init(name: "pid", kind: .integer, required: false), pairing]) {
            $0.deviceCommand(["logs", $0.number("seconds")] + ($0["pid"] == nil ? [] : [$0.number("pid")]), platform: "physical")
        },
        .init(name: "build_run", description: "Build an iOS Xcode project/workspace, install and restart its app. Executes the project's build scripts. Explicit scheme required; configuration defaults Debug. Physical signing/deployment unverified. Requires xcsift. Does not verify UI health.", fields: [platform, device, .init(name: "project"), .init(name: "scheme"), .init(name: "configuration", required: false), .init(name: "app_target", required: false)]) {
            var args = $0.deviceCommand(["build-run", $0.text("project"), $0.text("scheme")])
            if let config = $0["configuration"]?.stringValue { args += ["--configuration", config] }
            if let target = $0["app_target"]?.stringValue { args += ["--app-target", target] }
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
                let url = URL(fileURLWithPath: path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size <= 8 * 1024 * 1024 {
                    content.append(.image(data: try Data(contentsOf: url).base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil))
                } else {
                    content.append(.text(text: "PNG saved; image content omitted because it exceeds 8 MiB.", annotations: nil, _meta: nil))
                }
            }
            return .init(content: content, structuredContent: value.map { .object(["result": $0]) }, isError: output.exitCode != 0)
        } catch {
            return .init(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
        }
    }
}
