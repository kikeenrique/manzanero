# Optional MCP server

`appledevicescmd mcp` serves the existing operations over local stdio, using the official Swift MCP SDK. It waits for newline-delimited JSON-RPC on stdin. Stdout contains only protocol messages; diagnostics go to stderr. No HTTP listener is created.

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

The 27 tools have object schemas with required fields, enumerated operations where applicable, and no additional parameters. Their exact argument reference is returned by `tools/list`.

| Tools | Operations |
| --- | --- |
| `list_devices`, `doctor`, `inspect_device` | Discovery, tool checks, apps, physical details/processes/HID information |
| `device_readiness` | [Physical preparation status](READINESS.md), including Developer Mode and developer-image services |
| `request_handoff` | [Explicit human completion request](HANDOFF.md) using a host form, with per-device mutation pause |
| `get_ui_tree`, `get_accessibility_archive`, `ocr_image` | AXe simulator hierarchy, experimental raw physical archive, standalone Vision OCR |
| `screenshot` | Capture a PNG to a host path; inline MCP image content up to 8 MiB |
| `get_screen` | [Capture and inspect](SCREEN-UNDERSTANDING.md), preferring simulator accessibility with OCR fallback and an explicit image-only result if automatic analysis fails |
| `record_screen` | [Finite screen recording](RECORDING.md) to a new host MP4, with decoded-artifact metadata |
| `tap`, `tap_element`, `drag`, `multi_tap`, `type_text`, `press_button`, `press_key` | Existing simulator/physical input operations, with their backend limits |
| `multi_drag`, `pinch` | [Experimental physical moving multitouch](MULTITOUCH.md), with two to five coordinated linear paths or a horizontal pinch/spread |
| `app_action`, `app_data`, `simulator_state` | App lifecycle/URLs, raw physical container files, simulator boot/shutdown |
| `list_reports`, `download_report`, `capture_logs` | Saved physical reports and experimental finite OS trace |
| `build_run` | The existing [Xcode build/install/restart workflow](BUILD-RUN.md) |

Physical touch coordinates are normalized; simulator coordinates are interface points. `type_text` defaults to simulator but accepts `platform: "physical"` for [experimental US-layout ASCII typing](PHYSICAL-TYPING.md). Unicode physical entry and a parsed physical hierarchy remain unavailable. Unsupported device/platform combinations return tool errors; publishing a tool does not establish hardware support.

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
