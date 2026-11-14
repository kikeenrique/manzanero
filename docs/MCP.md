# MCP server

`manzanero mcp` exposes the CLI's operations over local stdio using the official Swift MCP SDK. It shares validation, backends and verification limits with the CLI. There is no HTTP listener.

## Configure a host

Use the executable's absolute path and `args: ["mcp"]`. A common configuration shape is:

```json
{
  "mcpServers": {
    "manzanero": {
      "command": "/absolute/path/to/manzanero",
      "args": ["mcp"]
    }
  }
}
```

Host formats vary; this is not an installation into a particular application. Set a suitable working directory and PATH for Apple developer tools and xcsift when needed. Relative files and private `tmp/` artifacts use the server's working directory.

Stdout contains newline-delimited JSON-RPC only. Diagnostics go to stderr. The host controls tool approvals; the server has no approval UI or policy of its own.

## Tool catalog

`tools/list` is the exact schema reference: 33 tools, enumerated operations and no unknown parameters. A listed tool does not imply that every platform/backend combination is available.

| Tools | Current purpose |
| --- | --- |
| `list_devices`, `doctor`, `inspect_device` | Inventory/tool checks; apps and physical details/processes/media status. Legacy `hid-info` is unavailable. |
| `device_readiness` | CoreDevice prerequisites plus separate display/passcode observations; see [readiness](READINESS.md). |
| `get_ui_tree` | Native physical AX hierarchy with optional PID. Simulator hierarchy is currently unavailable. |
| `get_screen`, `screenshot`, `ocr_image` | [PNG capture and analysis](SCREEN-UNDERSTANDING.md), saved-image OCR |
| `press_element`, `scroll_to_element` | [Fresh exact physical AX selectors](DIRECT-ACCESSIBILITY.md), guarded native press/scroll |
| `decode_accessibility_archive` | Offline data-only archive inspection |
| `get_accessibility_archive` | Legacy live raw callback capture; currently unavailable |
| `record_screen` | [Finite MP4 recording](RECORDING.md) to a new host path |
| `tap`, `drag`, `long_press` | Direct physical single-contact input |
| `multi_tap`, `multi_drag`, `pinch`, `perform_gesture` | [Coordinated contacts](MULTITOUCH.md) and [timed sequences](GESTURE-SEQUENCES.md) |
| `type_text`, `paste_text`, `press_key`, `press_button` | Physical typing, clipboard-replacing paste, named keys and hardware buttons |
| `tap_element` | Legacy simulator selector tap; currently unavailable |
| `app_action`, `app_data`, `simulator_state` | App lifecycle/URLs, raw physical container files, simulator boot/shutdown |
| `list_reports`, `download_report` | Saved physical report listing/download |
| `capture_logs` | Legacy finite OS trace; currently unavailable |
| `build_run` | [Xcode build/install/launch](BUILD-RUN.md) |
| `request_handoff` | [Explicit human completion request](HANDOFF.md) |

Device operations use Apple executables or in-process Apple interfaces. AXe/idevice/ipb executables are blocked, including their old simulator input, raw callback, pairing and log paths.

## Choose platform and coordinates explicitly

Some tools retain a simulator default. For physical `get_ui_tree` and `type_text`, supply `platform: "physical"` rather than relying on defaults.

Physical touch coordinates are normalized `0...1`. Physical AX frames use logical points; screenshots use pixels. OCR text regions are not guaranteed tap targets.

A physical tree without `pid` selects/rechecks the awake portrait primary display-centre process. An explicit positive PID can inspect a background app. IDs belong only to one non-atomic snapshot, not reusable action handles. Press/scroll selectors resolve fresh identities and apply additional guards.

Physical Unicode paste is `paste_text`; it replaces the clipboard and uses current focus. ASCII `type_text` has a US-layout mapping and does not change the clipboard. Neither approves prompts or verifies insertion.

## Results and errors

Tool content includes the CLI output as text. JSON is also returned under `structuredContent.result`; plain simulator output remains text.

`screenshot` and `get_screen` append a PNG image block when the saved file is at most 8 MiB. Larger images stay on disk with an omission notice. Other downloads are not embedded, parsed or symbolicated automatically.

- Unknown tools and invalid schema parameters produce JSON-RPC invalid-parameter errors.
- Backend/domain failures produce `isError: true` and diagnostics.
- Unsuccessful readiness/doctor results preserve structured data and set `isError: true`.
- Readiness's top-level status describes CoreDevice prerequisites; inspect `ui` separately.
- Dispatch receipts retain unverified effect/release fields. Scroll callers must inspect `postconditionVerified`, even when the call exits successfully.

Follow actions with fresh observations or app-specific assertions. A completed call can have partial side effects or uncertain cleanup.

## Shutdown and operation ownership

Each tool call is registered as an owned task before device work starts. Request cancellation cancels that task and waits for its result/cleanup. Shutdown closes admissions, cancels owned operations, stops the SDK transport and pending elicitation waits, then drains tasks.

| Event | Normal result |
| --- | --- |
| stdin EOF | Cancel/drain; exit 0 |
| SIGINT / SIGTERM | Cancel/drain; exit 130 / 143 |
| Cleanup grace expiry or repeated signal | Forced exit; cleanup is uncertain |

The runtime grace is 30 seconds. Interrupted input does not publish an ordinary success receipt. Embedded sessions stop/drain without exiting their host process and cannot restart after shutdown.

This owns tasks, not exclusive access to a device. Independent CLI/server processes remain uncoordinated. Blocking Apple calls can delay cancellation; force exit, crashes and disconnects do not guarantee release or roll back text/clipboard/app changes.

## Handoff and approvals

`request_handoff` uses a host form when form elicitation is advertised. A required completion checkbox acknowledges only the person's response, not device success. Pending handoff pauses that device's mutations within the same server process while leaving observations available.

Do not send passcodes, keys or pairing-file contents through tool arguments. No MCP tool initiates pairing. The old interactive pairing route is also blocked by current execution policy.

Read-only/destructive annotations are host hints, not permission enforcement. See [handoff](HANDOFF.md) for identity and completion rules.

## Protocol and validation

The SDK is pinned to 0.12.1. Supported protocol versions are `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; later versions are not supported. The implementation follows the pinned [stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [tool](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) specifications.

HTTP/authentication, resources/prompts, automatic prompt detection, general progress and durable sessions remain absent.

Opt-in `test:mcp-*` tasks exercise real stdio. Read their help before running: some read state only; others press, type, scroll or record. [Development tasks](DEVELOPMENT-TASKS.md) lists useful entry points, and [verification](VERIFICATION.md) separates scoped live results from local protocol tests.
