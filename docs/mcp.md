# MCP server

`manzanero mcp` exposes the CLI's operations over local stdio using the official Swift MCP SDK. It shares validation, backends and verification limits with the CLI. There is no HTTP listener.

The tool schemas are written by hand for models; they are not generated from the CLI. Each tool turns its arguments into a CLI command line (for example `tap --device=<UDID> -- 0.5 0.45`) and runs it through the CLI's own parser, so a tool and its command cannot drift apart. A command line the parser rejects is a tool error with `code: usage`; the target never comes from `MANZANERO_DEVICE` or `MANZANERO_SIMULATOR`.

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

`tools/list` is the exact schema reference: 46 tools, enumerated operations and no unknown parameters. A listed tool does not imply that every platform combination is available.

| Tools | Current purpose |
| --- | --- |
| `list_devices`, `doctor`, `inspect_device` | Inventory/tool checks plus host-only private-interface availability per capability ([doctor output](dependencies.md#reading-doctor-output)); apps and physical details/processes/media status. |
| `device_readiness` | CoreDevice prerequisites plus separate display/passcode observations; see [readiness](readiness.md). |
| `get_ui_tree` | Native AX hierarchy with optional PID, physical or [simulator](simulator-input.md). |
| `get_screen`, `screenshot`, `ocr_image` | [PNG capture and analysis](screen-understanding.md), saved-image OCR. Auto mode prefers the tree on both platforms. Optional `display` chooses a simulator display ([iPhone Duo](other-families.md#displays-iphone-duo)). |
| `list_displays` | A simulator's displays: screen ID, name, size, backlight, active and primary state, the display the interface is on, and on a foldable simulator the hinge angle with a derived posture ([other families](other-families.md#displays-iphone-duo)); read-only |
| `press_element`, `scroll_to_element` | [Fresh exact AX selectors](direct-accessibility.md), guarded native press/scroll, physical or simulator. These two, `set_element_value` and `wait_for_element` take an optional `index` to choose among several matches by position |
| `set_element_value` | [Unicode entry by AX set-value](simulator-input.md#unicode-text-set-value): replaces one settable element's whole value, with the press guards, on a physical device (the default) or a simulator |
| `wait_for_element` | [Read-only bounded wait](direct-accessibility.md#bounded-wait-for-a-selector-condition) until an exact selector is visible, gone, enabled, disabled, has an exact value or ([Apple TV](other-families.md#focus-in-the-tree-and-in-waits)) has focus, within one AX session. A timeout over MCP was checked on the iPhone 13 mini and the met case on simulators; the CLI wait is verified on that phone. |
| `decode_accessibility_archive` | Offline data-only archive inspection |
| `record_screen` | [Finite MP4 recording](recording.md) to a new host path; optional `display` on a simulator |
| `capture_frames` | [Live screen frames as JPEG files](recording.md#frames-repeated-screenshots-from-one-stream) from one native stream on a physical device: `count`, `seconds`, `interval_ms`, `overwrite`; returns the index and the last frame inline (the `image_*` options apply). Cancellation keeps the frames written so far |
| `tap`, `drag`, `long_press` | Direct single-contact input, physical or simulator |
| `multi_tap`, `multi_drag`, `pinch`, `perform_gesture` | [Coordinated contacts](multitouch.md) and [timed sequences](gesture-sequences.md); optional `platform` (default physical); a booted simulator receives all of them |
| `type_text`, `paste_text`, `press_key`, `press_button` | [Typing in a named keyboard layout](physical-typing.md#layouts) (`layout`, default `us`), named keys and hardware buttons (physical or simulator, the same four buttons), and physical clipboard-replacing paste |
| `list_keyboard_layouts` | The layout names `type_text` accepts: the Mac's own layouts, read-only, no device contact |
| `detect_keyboard_layout` | [Which layout a device applies](physical-typing.md#finding-the-layout-detect-layout): types a probe into one named settable field, compares it with every Mac layout, reports `detected`, `ambiguous` or `no-match` with the `--layout` value, and restores the field; physical (default) or simulator. Sends input |
| `press_remote` | [Siri Remote](other-families.md#siri-remote-apple-tv) buttons on an Apple TV simulator: D-pad, select, menu, home, play-pause; other families and physical devices are refused |
| `rotate_crown` | [Digital Crown](other-families.md#digital-crown-and-side-button-apple-watch) on an Apple Watch simulator: integer units, optional event count; `press_button` also takes `side` and `action` there |
| `fold_device`, `set_hinge_angle`, `get_hinge_angle` | [Fold](other-families.md#fold-iphone-duo) an iPhone Duo simulator: fold or unfold and wait (bounded) for the matching display, set any hinge angle 0...180 without a display promise, or read the angle once (read-only); other simulators and physical devices are refused |
| `wake_device` | [Guarded wake](native-input.md#waking-a-dark-display) of a dark display: one side-button press only when the display reads off twice |
| `clear_quarantine` | Lift the [quarantine](native-input.md#quarantine-after-an-uncertain-release) that follows an input whose release is unknown, after inspecting the device; input tools fail with `device-quarantined` until then. Sends the device nothing |
| `app_action`, `app_data`, `simulator_state` | App lifecycle/URLs, raw physical container files, simulator boot/shutdown |
| `list_reports`, `download_report` | Saved physical report listing/download |
| `capture_logs`, `capture_console`, `latest_crash` | [App output and crashes](app-logs.md): a bounded unified-log capture for one app (simulator only, read-only), launch with stdout/stderr tails (launches an app, so not read-only; the CLI form is verified on a simulator and the iPhone 13 mini, the MCP tools by unit tests only), and the newest crash report parsed (read-only) |
| `build_run` | [Xcode build/install/launch](build-run.md). Optional physical-only booleans `allow_provisioning_updates` and `allow_device_registration` let Xcode change certificates, profiles and device registrations in the user's developer account; ask the user before setting them. |
| `request_handoff` | [Explicit human completion request](handoff.md) |

Device operations use Apple executables or in-process Apple interfaces. AXe/idevice/ipb executables are blocked at runtime, and neither the catalogue nor the shared CLI command service has any route to them: simulator selector taps, live raw callback archives, finite OS traces, `hid-info`, `pairing_file` and the input `backend` choice are gone. Physical input and trees always use the in-process CoreDevice route; simulator input and trees use the in-process [CoreSimulator route](simulator-input.md) and need a booted simulator addressed by UUID. Simulator operations that are not implemented (paste, wake) are not reachable from the tools above, and the CLI refuses them as `unsupported-operation`.

## Choose platform and coordinates explicitly

`get_ui_tree`, `type_text`, `press_element`, `scroll_to_element`, `wait_for_element`, `press_key`, `long_press`, `multi_tap`, `multi_drag`, `pinch` and `perform_gesture` default to `platform: "physical"`, so calls written before simulator support route as before. Other device tools require an explicit `platform` where they accept one.

Touch coordinates are normalized `0...1` in the current interface on both platforms; a simulator's orientation is read and mapped like a phone's. AX frames use logical points; screenshots use pixels. OCR text regions are not guaranteed tap targets.

A physical tree without `pid` selects/rechecks the awake portrait primary display-centre process; a simulator tree the frontmost application, or the process under the screen centre when the simulator reports none. An explicit positive PID can inspect a background app. IDs belong only to one non-atomic snapshot, not reusable action handles. Press/scroll selectors resolve fresh identities and apply additional guards.

Unicode text goes through `set_element_value` on both platforms: it names its target element and replaces its whole value, without the keyboard or the clipboard. Physical `paste_text` is the alternative at the current focus; it replaces the clipboard. `type_text` types at the current focus in the keyboard layout given in `layout` (default `us`; names from `list_keyboard_layouts`), does not change the clipboard, refuses the whole text at the first character that layout cannot produce, and never switches to either silently. Give the layout the device actually uses: a phone's cannot be read (receipt `deviceLayout.status: not-read`); a simulator's setting is read first, a different explicit layout is refused and `hw=Automatic` is reported as `not-checked`. The server's `MANZANERO_KEYBOARD_LAYOUT` is not used, as targets are not. None of them approves prompts or verifies insertion.

## Results and errors

Tool content includes the CLI output as text. JSON is also returned under `structuredContent.result`; plain simulator output remains text.

### Inline image options

`screenshot` and `get_screen` always save a full-resolution PNG, which is the evidence, and return its path. The image they return inline is a separate, reduced copy by default, because it is paid for in response size and in the model's context. Each call can change that:

| Parameter | Meaning | Default |
| --- | --- | --- |
| `image_include` | `false` leaves the inline image out | `true` |
| `image_max_edge` | Longest edge of the inline image in pixels, 64...8192. `8192` asks for the saved resolution | 1568 |
| `image_format` | `auto`: lossless PNG when it fits the byte cap, otherwise JPEG. `png`: always lossless. `jpeg`: always lossy | `auto` |
| `image_quality` | JPEG quality, 0.1...1. Not allowed with `image_format: png` | 0.8 |
| `image_max_bytes` | Cap on the encoded inline image, 16384...16777216 bytes | 1048576 (1 MiB) |

Reduction loses as little as it can, in this order: cap the longest edge; keep PNG if it fits the byte cap; with `auto`, switch to JPEG at the same size; only then halve the size until it fits. A screen that is already within the edge and the cap is sent as the saved file itself. Only a file that cannot be read or reduced far enough is left out, with a notice. An out-of-range option is rejected before anything is captured.

The result says what was sent in two places. A text block describes any difference from the saved file. `structuredContent.inlineImage` carries the same facts as data: `included`, `format`, `width`, `height`, `bytes` and `scale`, or `included: false` with a `reason`. Multiply a pixel position read from the inline image by `scale` to get the position in the saved file. Normalized coordinates, which the input tools take, are unaffected by any of this.

The 1568-pixel default is sized for a vision model to read interface text; larger images are commonly resized by the model before it looks at them. An agent working only from the accessibility tree can pass `image_include: false`; one that needs every pixel can pass `image_max_edge: 8192` with `image_format: png` and a larger `image_max_bytes`. The image travels as base64, about a third larger than the cap, and a host may enforce a limit of its own.

Other downloads are not embedded, parsed or symbolicated automatically.

- Unknown tools and invalid schema parameters produce JSON-RPC invalid-parameter errors.
- Backend/domain failures produce `isError: true` and diagnostics as text, plus `structuredContent.error` with the failure's `code`, `message`, `inputSent`, `retry` and `action`, the same object the CLI prints with `--error-format json`. See [errors](errors.md) for the categories and what each asks of a caller.
- A `wait_for_element` timeout is an answer: `status: timed-out` with the last observation and `isError: false` (the CLI exits 124). Session or transport failure sets `isError: true`.
- Unsuccessful readiness/doctor results preserve structured data and set `isError: true`. For doctor that means an unavailable Xcode, CoreDevice or CoreSimulator tool; a missing private interface is reported in its capability entry without `isError`.
- Readiness's top-level status describes CoreDevice prerequisites; inspect `ui` separately.
- Dispatch receipts retain unverified effect/release fields. Scroll callers must inspect `postconditionVerified`, even when the call exits successfully.

Follow actions with fresh observations or app-specific assertions. A completed call can have partial side effects or uncertain cleanup.

## Calls sent without waiting

A client may send requests without waiting for answers, from `initialize` on. Answers can arrive in any order; match them by id.

**Startup.** Messages that arrive after an `initialize` request, except `ping`, are held until that request has been answered, then handled in arrival order. A client that writes `initialize`, `notifications/initialized` and a `tools/call` at once gets an answer to each. (The MCP specification asks clients not to send other requests before the `initialize` response; this server does not rely on it.)

**Order of tool calls.** Each `tools/call` is placed in arrival order as it is read. What it waits for depends on what it does and which device it addresses:

| Call | Waits for | Holds its device |
| --- | --- | --- |
| A mutation: anything not read-only, such as input, `press_element`, `fold_device`, `app_action`, `build_run`, `simulator_state` | Every earlier mutation of the same device to end | Until it ends, so later calls to that device wait |
| An observation: a read-only call such as `get_ui_tree`, `get_screen`, `screenshot`, `wait_for_element`, `list_displays`, `get_hinge_angle`, `device_readiness` | Every earlier mutation of the same device to end | No |
| A capture: `record_screen`, `capture_frames`, `capture_console` | Every earlier mutation of the same device to end | Only until it begins, so input can follow it while it records. Later calls do not wait for its first frame: input sent right behind a capture can come before recording has started |
| `request_handoff` | Every earlier mutation of the same device to end | Until the person's response is pending; later mutations then run and are refused by the [handoff pause](#handoff-and-approvals), as before |
| A call with no device (`doctor`, `list_devices`, `list_keyboard_layouts`, `ocr_image`, `decode_accessibility_archive`), a dry run, or one whose arguments are invalid | Nothing | No |

So mutations of one device run one at a time in the order they were sent, and a later one never overtakes an earlier one; an observation sent after a mutation sees the state after it, and never runs inside it (`fold_device`'s wait included). An observation already running when a mutation arrives does not hold the mutation up: a `wait_for_element` sent before the tap that satisfies it keeps polling while the tap runs. Calls to different devices are not ordered against each other. A device is named by its identifier as given; UDIDs and UUIDs are compared without regard to case, but an alias and the identifier it stands for are two devices here. The per-device lease is unchanged: it is shared within the server process, which is what lets a capture and input run together, and keeps other processes out.

`notifications/cancelled` for a call still waiting for its device removes it: it never runs and gets no answer. Cancelling a running call cancels its task; the next call for the device starts after the cancelled one's cleanup has finished. Waiting is part of the owned operation below, so shutdown ends waiting calls too.

Why the server does this itself: the pinned SDK starts every request in a task of its own, so without it requests run in no fixed order, and a request that reached the SDK's initialization check before `initialize` finished was rejected with no answer at all (the SDK discards that error). `MCPSessionTransport` holds messages behind `initialize`, registers each `tools/call` with `MCPCallOrdering` as it is read, and passes the call's place to its handler in `params._meta` under `manzanero/ticket` (a value a client sends there is removed).

## Shutdown and operation ownership

Each tool call is registered as an owned task before device work starts. Request cancellation cancels that task and waits for its result/cleanup. Shutdown closes admissions, cancels owned operations (including calls still waiting for their device), stops the SDK transport and pending elicitation waits, then drains tasks.

| Event | Normal result |
| --- | --- |
| stdin EOF | Cancel/drain; exit 0 |
| SIGINT / SIGTERM | Cancel/drain; exit 130 / 143 |
| Cleanup grace expiry or repeated signal | Forced exit; cleanup is uncertain. If an input was running, the next input to that device is refused as `device-quarantined` until `clear_quarantine` |

The runtime grace is 30 seconds. Interrupted input does not publish an ordinary success receipt. Embedded sessions stop/drain without exiting their host process and cannot restart after shutdown.

Within one session, the ordering above serializes each device's mutations. It does not reach other processes: independent CLI/server processes are coordinated only by the per-device lease that input and native capture take, which fails at once rather than waiting. Blocking Apple calls can delay cancellation; force exit, crashes and disconnects do not guarantee release or roll back text/clipboard/app changes.

## Handoff and approvals

`request_handoff` with `until` watches the device and ends by itself when it shows the condition, with no form ([handoff](handoff.md#watching-the-device---until)); prefer it. Without `until` it uses a host form when form elicitation is advertised. The form has no fields: the host's own Accept acknowledges the person's response, not device success, and Decline or Cancel do not. Pending handoff pauses that device's mutations within the same server process while leaving observations available.

Do not send passcodes, keys or pairing-file contents through tool arguments. No MCP tool or CLI command initiates pairing; pair through Xcode/CoreDevice.

Read-only/destructive annotations are host hints, not permission enforcement. See [handoff](handoff.md) for identity and completion rules.

## Protocol and validation

The SDK is pinned to 0.12.1. Supported protocol versions are `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; later versions are not supported. The implementation follows the pinned [stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [tool](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) specifications.

HTTP/authentication, resources/prompts, automatic prompt detection, general progress and durable sessions remain absent.

Opt-in `test:mcp-*` tasks exercise real stdio. Read their help before running: some read state only; others press, type, scroll or record. [Development tasks](development-tasks.md) lists useful entry points, and [verification](verification.md) separates scoped live results from local protocol tests.
