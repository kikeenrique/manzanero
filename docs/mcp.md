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

`tools/list` is the exact schema reference: 32 tools, enumerated operations and no unknown parameters. A listed tool does not imply that every platform combination is available.

| Tools | Current purpose |
| --- | --- |
| `list_devices`, `doctor`, `inspect_device` | Inventory/tool checks plus host-only private-interface availability per capability ([doctor output](dependencies.md#reading-doctor-output)); apps and physical details/processes/media status. |
| `device_readiness` | CoreDevice prerequisites plus separate display/passcode observations; see [readiness](readiness.md). |
| `get_ui_tree` | Native AX hierarchy with optional PID, physical or [simulator](simulator-input.md). |
| `get_screen`, `screenshot`, `ocr_image` | [PNG capture and analysis](screen-understanding.md), saved-image OCR. Auto mode prefers the tree on both platforms. |
| `press_element`, `scroll_to_element` | [Fresh exact AX selectors](direct-accessibility.md), guarded native press/scroll, physical or simulator |
| `wait_for_element` | [Read-only bounded wait](direct-accessibility.md#bounded-wait-for-a-selector-condition) until an exact selector is visible, gone, enabled, disabled or has an exact value, within one AX session. Run on one simulator; not yet verified on physical hardware. |
| `decode_accessibility_archive` | Offline data-only archive inspection |
| `record_screen` | [Finite MP4 recording](recording.md) to a new host path |
| `tap`, `drag`, `long_press` | Direct single-contact input, physical or simulator |
| `multi_tap`, `multi_drag`, `pinch`, `perform_gesture` | [Coordinated contacts](multitouch.md) and [timed sequences](gesture-sequences.md); physical only |
| `type_text`, `paste_text`, `press_key`, `press_button` | US-layout typing, named keys and hardware buttons (physical or simulator; simulator buttons home and lock only), and physical clipboard-replacing paste |
| `wake_device` | [Guarded wake](native-input.md#waking-a-dark-display) of a dark display: one side-button press only when the display reads off twice |
| `app_action`, `app_data`, `simulator_state` | App lifecycle/URLs, raw physical container files, simulator boot/shutdown |
| `list_reports`, `download_report` | Saved physical report listing/download |
| `build_run` | [Xcode build/install/launch](build-run.md). Optional physical-only booleans `allow_provisioning_updates` and `allow_device_registration` let Xcode change certificates, profiles and device registrations in the user's developer account; ask the user before setting them. |
| `request_handoff` | [Explicit human completion request](handoff.md) |

Device operations use Apple executables or in-process Apple interfaces. AXe/idevice/ipb executables are blocked at runtime, and neither the catalogue nor the shared CLI command service has any route to them: simulator selector taps, live raw callback archives, finite OS traces, `hid-info`, `pairing_file` and the input `backend` choice are gone. Physical input and trees always use the in-process CoreDevice route; simulator input and trees use the in-process [CoreSimulator route](simulator-input.md) and need a booted simulator addressed by UUID. Simulator operations that are not implemented (multi-contact, paste, wake, Unicode typing) are not reachable from the tools above, and the CLI refuses them as `unsupported-operation`.

## Choose platform and coordinates explicitly

`get_ui_tree`, `type_text`, `press_element`, `scroll_to_element`, `wait_for_element`, `press_key` and `long_press` default to `platform: "physical"`, so calls written before simulator support route as before. Other device tools require an explicit `platform` where they accept one.

Touch coordinates are normalized `0...1` on both platforms (a simulator's interface is assumed portrait). AX frames use logical points; screenshots use pixels. OCR text regions are not guaranteed tap targets.

A physical tree without `pid` selects/rechecks the awake portrait primary display-centre process; a simulator tree the frontmost application, or the process under the screen centre when the simulator reports none. An explicit positive PID can inspect a background app. IDs belong only to one non-atomic snapshot, not reusable action handles. Press/scroll selectors resolve fresh identities and apply additional guards.

Physical Unicode paste is `paste_text`; it replaces the clipboard and uses current focus. ASCII `type_text` has a US-layout mapping and does not change the clipboard. Neither approves prompts or verifies insertion.

## Results and errors

Tool content includes the CLI output as text. JSON is also returned under `structuredContent.result`; plain simulator output remains text.

`screenshot` and `get_screen` append the saved PNG as an image block when it is at most 8 MiB. A larger file, which a detailed full-resolution phone screen can be, is sent as a downscaled PNG (longest edge at most 1568 pixels) with a text note giving both sizes and the scale factor; the saved file stays full resolution. Normalized coordinates are unaffected. Only a file that cannot be read or reduced is left out, with a notice. Other downloads are not embedded, parsed or symbolicated automatically.

- Unknown tools and invalid schema parameters produce JSON-RPC invalid-parameter errors.
- Backend/domain failures produce `isError: true` and diagnostics as text, plus `structuredContent.error` with the failure's `code`, `message`, `inputSent`, `retry` and `action`, the same object the CLI prints with `--error-format json`. See [errors](errors.md) for the categories and what each asks of a caller.
- A `wait_for_element` timeout is an answer: `status: timed-out` with the last observation and `isError: false` (the CLI exits 124). Session or transport failure sets `isError: true`.
- Unsuccessful readiness/doctor results preserve structured data and set `isError: true`. For doctor that means an unavailable Xcode, CoreDevice or CoreSimulator tool; a missing private interface is reported in its capability entry without `isError`.
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

Do not send passcodes, keys or pairing-file contents through tool arguments. No MCP tool or CLI command initiates pairing; pair through Xcode/CoreDevice.

Read-only/destructive annotations are host hints, not permission enforcement. See [handoff](handoff.md) for identity and completion rules.

## Protocol and validation

The SDK is pinned to 0.12.1. Supported protocol versions are `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; later versions are not supported. The implementation follows the pinned [stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [tool](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) specifications.

HTTP/authentication, resources/prompts, automatic prompt detection, general progress and durable sessions remain absent.

Opt-in `test:mcp-*` tasks exercise real stdio. Read their help before running: some read state only; others press, type, scroll or record. [Development tasks](development-tasks.md) lists useful entry points, and [verification](verification.md) separates scoped live results from local protocol tests.
