# Optional MCP server

MCP cancellation notifications now reach all direct physical HID dispatch paths: touch/holds/drags, paired movement, buttons, named keys, typing, paste keys and Universal HID schedules. Schedulers stop future movement/typing, attempt release of attempted contacts/keys, and complete bounded barrier cleanup before cancellation propagates to the SDK. This does not prove device-side release or undo text/paste. Clipboard replacement can precede cancellation. CLI signals, interrupted transport setup, cross-process ownership and general cancellation coordination remain incomplete. See [input cancellation limits](NATIVE-INPUT.md#task-cancellation-and-release-attempts) and scoped live checks in [verification records](VERIFICATION.md).

**Current runtime policy:** MCP uses only project-owned in-process Apple backends or Apple executables for device operations. Physical buttons, named keys, single-contact touch and two-contact movement default to the direct CoreDevice backend. Tools requiring AXe/idevice/ipb executables return unavailable errors until migrated; the catalog and legacy examples below do not imply those backends remain executable. See [current availability](PARITY-STATUS.md#current-runtime-availability).

`appledevicescmd mcp` serves the existing operations over local stdio, using the official Swift MCP SDK. It waits for newline-delimited JSON-RPC on stdin. Stdout contains only protocol messages; diagnostics go to stderr. No HTTP listener is created.

`paste_text` uses Apple's clipboard command and in-process Command+V, with no helper executable. It replaces the phone clipboard; an iOS paste prompt may remain after a successful dispatch receipt. See [current paste semantics](NATIVE-INPUT.md#direct-unicode-paste). The server does not approve prompts or retry insertion.

`type_text` with `platform: physical` uses in-process US-layout keyboard events without changing the clipboard. It accepts 1...512 printable ASCII characters, tab and LF; focus, keyboard layout and app behavior affect output. See [direct typing and verification limits](PHYSICAL-TYPING.md#current-direct-implementation). The default simulator path remains disabled pending direct replacement.

`perform_gesture` uses the in-process Universal HID backend for one-to-five-slot complete-state schedules, including independent arrivals/lifts and repeated taps. It shares fresh identity/display checks and human-handoff pause with CLI dispatch. See [current direct gesture limits](GESTURE-SEQUENCES.md#current-direct-implementation); the historical helper notes elsewhere do not imply a helper runs.

Configure an MCP host to launch the built executable by absolute path with `args: ["mcp"]`. Set the working directory to this checkout and provide a PATH containing xcsift, AXe, and `tmp/bin` as needed for the selected backend. A common host configuration shape is:

```json
{
  "mcpServers": {
    "appledevicescmd": {
      "command": "/absolute/path/to/appledevicesmcp/.build/debug/appledevicescmd",
      "args": ["mcp"]
    }
  }
}
```

This is a configuration example, not an installation into a particular host. Hosts differ in how they configure working directory and environment. Paths are relative to the server's working directory; temporary artifacts go beneath its `tmp/`. Keep that directory ignored if using another working directory.

## Tools

The 33 tools have object schemas with required fields, enumerated operations where applicable, and no additional parameters. Their exact argument reference is returned by `tools/list`.

| Tools | Operations |
| --- | --- |
| `list_devices`, `doctor`, `inspect_device` | Discovery, tool checks, apps, physical details/processes/HID information |
| `device_readiness` | [Physical preparation status](READINESS.md), including Developer Mode and developer-image services |
| `request_handoff` | [Explicit human completion request](HANDOFF.md) using a host form, with per-device mutation pause |
| `get_ui_tree`, `get_accessibility_archive`, `ocr_image` | AXe simulator hierarchy or native physical AX snapshot with optional PID, separate raw physical callback archive, standalone Vision OCR |
| `press_element` | [Fresh physical AX press](ACCESSIBILITY-PROTOCOL.md#fresh-selector-presses) by exact identifier/label, with unique target, live state, hit, and display checks; native acceptance does not verify UI effect |
| `scroll_to_element` | [Physical scroll-to-visible](ACCESSIBILITY-PROTOCOL.md#scroll-an-element-into-view) by exact identifier/label for a target already in the snapshot; one native action followed by read-only visibility/frame/hit checks. Inspect `nativeResult` and `postconditionVerified` separately. |
| `decode_accessibility_archive` | [Offline structural archive inspection](ACCESSIBILITY-PROTOCOL.md#saving-and-inspecting-a-callback), with bounds and unknown fields preserved; no normalized physical tree |
| `screenshot` | Capture a PNG to a host path; inline MCP image content up to 8 MiB |
| `get_screen` | [Capture and inspect](SCREEN-UNDERSTANDING.md), preferring simulator or physical accessibility with OCR fallback and an explicit image-only result if automatic analysis fails |
| `record_screen` | [Finite screen recording](RECORDING.md) to a new host MP4, with decoded-artifact metadata |
| `tap`, `tap_element`, `drag`, `multi_tap`, `type_text`, `press_button`, `press_key` | Existing simulator/physical input operations, with their backend limits |
| `multi_drag`, `pinch` | [Experimental physical moving multitouch](MULTITOUCH.md), with two to five coordinated linear paths or a horizontal pinch/spread |
| `paste_text` | [Physical Unicode paste](NATIVE-INPUT.md#keyboard-and-unicode-paste) into the focused field, explicitly replacing the device clipboard |
| `long_press` | [Native physical held touch](NATIVE-INPUT.md#long-press), normalized coordinates and 0.1...10-second requested duration; dispatch receipt does not verify UI effect or release |
| `perform_gesture` | [Timed native touch sequence](GESTURE-SEQUENCES.md), supplied as a bounded JSON string with complete-state frames; sampled paths, holds, repeated taps, and contact arrivals/lifts |
| `app_action`, `app_data`, `simulator_state` | App lifecycle/URLs, raw physical container files, simulator boot/shutdown |
| `list_reports`, `download_report`, `capture_logs` | Saved physical reports and experimental finite OS trace |
| `build_run` | The existing [Xcode build/install/restart workflow](BUILD-RUN.md) |

Physical touch coordinates are normalized; simulator coordinates are interface points. `type_text` defaults to simulator but accepts `platform: "physical"` for [experimental US-layout ASCII typing](PHYSICAL-TYPING.md). Physical Unicode insertion is available through the separate clipboard-replacing `paste_text` operation. `get_ui_tree` keeps its simulator default and accepts `platform: physical`, `device`, optional integer `pid`, and optional `pairing_file` for a [native physical AX snapshot](ACCESSIBILITY-PROTOCOL.md#active-per-application-tree). Without PID, the primary display-centre process is selected and rechecked; an explicit PID can inspect a background app. Its geometry uses logical device points and its path IDs are snapshot-local, not reusable action references. No selector action is submitted. `press_element` also accepts optional `pid`; an explicit PID must match the display-centre process. Unsupported device/platform combinations return tool errors; publishing a tool does not establish hardware support.

Physical `tap`, `drag`, `multi_drag`, `pinch`, `press_button`, and `press_key` accept optional `backend: coredevice` for the [native Apple framework helper](NATIVE-INPUT.md). Default behavior remains idevice. Native Home/tap/drag, two-contact map zoom gestures, Unicode paste, and Backspace effects were verified on the USB iPhone 13 mini; individual receipts still require observation. Pairing files and simulator targets are rejected for this backend. `paste_text` uses native CoreDevice and reports clipboard replacement separately from unverified insertion. No automatic retry or backend fallback occurs.

## Shared execution and output

Tool calls use the same `CommandService`, planners, and backends as the CLI. Device actions are serialized within one server process. OCR and handoff confirmation can suspend, allowing another request during that suspension; handoff explicitly blocks mutations for its pending target. Multiple server/CLI processes are not coordinated.

Results contain text with the CLI output. JSON output is also wrapped under `structuredContent.result`; plain simctl output remains text. A screenshot or `get_screen` appends an `image/png` block when the saved PNG is at most 8 MiB. Larger images stay on disk with an omission notice. Other downloaded files are not automatically embedded, parsed, or symbolicated.

Backend/domain validation failures return `isError: true` and diagnostic text. Unknown tools, missing/unknown parameters, and schema type/enum violations return JSON-RPC invalid-parameter errors. An unsuccessful doctor check keeps its structured output and sets `isError: true`. Input and Build & Run receipts retain `verified: false`; follow with a fresh tree, screenshot, or app-specific health check.

## Pairing and approvals

Pair initially through the interactive CLI. No MCP tool initiates pairing, and the shared service rejects interactive pairing in server mode so a PIN prompt cannot consume protocol input. Physical bridge tools can accept an existing `pairing_file` path; the bridge checks device identity. Do not send a PIN, key, or pairing-file contents as tool arguments.

The MCP host controls approvals. This server has no approval prompt or policy of its own. Tool annotations identify read operations and conservatively mark mutation tools with `destructiveHint: true`, including host-file replacement and app-state changes. These are hints, not permission enforcement.

## Protocol and limitations

SwiftPM declares the official [Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) at exact version **0.12.1**, revision `a0ae212ebf6eab5f754c3129608bc5557637e605`; `Package.resolved` pins dependencies. Its newest protocol version is `2025-11-25`, with negotiation also supporting `2025-06-18`, `2025-03-26`, and `2024-11-05`. Later protocol revisions are not supported. The [upstream license and transition notice](../ThirdParty/swift-mcp-sdk-LICENSE.txt) are preserved.

Wire handling follows the SDK's strict initialization, the [stdio specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), and the [tool specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools). HTTP/authentication, resources/prompts, automatic human-prompt detection, progress, and process cancellation coordination are absent. Cancellation or client closure does not promise immediate termination or rollback of an external tool. Backend deadlines and all device-verification limits still apply.

The opt-in check `mise run test:mcp-live <booted-simulator-UUID>` launches the real server for initialization, discovery, invalid input, simulator inventory/tree reads, PNG/video capture, a synthetic handoff form response, and EOF shutdown. Artifacts stay under `tmp/`. The harness answers its own handoff form; it does not prompt the user or perform a device action. It does not send physical input or establish physical backend support. See [verification records](VERIFICATION.md).

`mise run test:mcp-physical <UDID> <pid>` uses the same real stdio harness for initialization, discovery, invalid input, an active physical AX tree read, and EOF shutdown. It requires the built idevice bridge and does not install/launch an app or send UI input. A current application PID is required; the query may inspect a background app. The native tree is saved privately under ignored `tmp/mcp-live-*/physical-tree.json`. The USB iPhone 13 mini Settings exchange passed; this does not verify other apps or transports.

`mise run test:mcp-foreground <UDID>` instead omits PID and verifies foreground selection, tree structure, `get_screen` accessibility analysis, inline PNG content, and EOF shutdown. It saves private tree and screen JSON under ignored `tmp/mcp-live-*/`. Cleanup may be confirmed or explicitly report connection closure before acknowledgement; the latter must carry an unconfirmed flag and warning. This harness sends no UI input.

`mise run test:mcp-scroll <UDID> <identifier>` opts into one `scroll_to_element` call after those foreground reads. It sends a native scroll action for the explicitly supplied identifier and requires its observed visibility postcondition to pass. It saves private `physical-scroll.json` alongside the read artifacts. The target must already exist in the current snapshot. This task can move the app's scroll position; it does not press the row, send another scroll on failure, or change a setting.

`mise run test:mcp-long-press <UDID> <x> <y> <seconds>` opts into one native `long_press` call at the supplied physical coordinates, followed by a screenshot and EOF shutdown. It requires the native helper, saves the receipt and PNG under ignored `tmp/mcp-live-*/`, and does not query an AX tree or automatically choose a control. Its assertions verify the protocol/receipt/capture; inspect the screenshot to establish the UI effect. No retry is sent on failure.

`mise run test:mcp-gesture <UDID> <file>` similarly opts into one `perform_gesture` sequence from a local JSON file, followed by a screenshot. It can send multiple scheduled contacts/taps as specified in that one sequence. Receipts and captures remain private under ignored `tmp/mcp-live-*/`; no replay or target selection is performed.
