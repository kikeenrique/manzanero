# Errors for unattended callers

Every failure carries a message for people and, alongside it, a small set of machine-readable facts: a category (`code`), whether anything may have reached the device (`inputSent`), whether repeating the call is appropriate (`retry`) and, when something must happen first, what (`action`). The facts are set where the failure is created in the code, never derived from the message text, so the wording can change without breaking a caller. The message itself is unchanged by this: the same text appears on stderr, in MCP text content and in the JSON below.

## Output formats

**CLI, default.** A failure prints its message on stderr followed by a newline and exits 1. Nothing else changes; existing scripts see the same bytes.

**CLI, JSON.** Pass `--error-format json` before the command (it may follow `--dry-run`), or set `MANZANERO_ERROR_FORMAT=json` in the environment. The option wins over the variable; `text` selects the default explicitly, and any other value is a usage error printed as text. A failure then prints one JSON object on one line on stderr and still exits 1:

```sh
$ manzanero --error-format json physical <UDID> tap 2 0.5
{"error":{"action":null,"code":"usage","inputSent":"none","message":"Physical input coordinates must be normalized numbers from 0 to 1.","retry":"no"}}
```

Both mechanisms exist because they suit different callers: an agent harness sets the variable once for every invocation, including those made by scripts it does not control, while the option keeps a single invocation self-describing in logs. Diagnostics printed while a command runs (readiness warnings, cleanup notes, the signal message) stay text on stderr; the failure object is always the last line. `action` is `null` when there is none.

**MCP.** A failing tool returns the message as text content with `isError: true`, exactly as before, and adds the same object as `structuredContent`:

```json
{"content":[{"type":"text","text":"Device is controlled by another manzanero process (pid 4242, tap). Wait for it to finish or stop it; no input sent."}],
 "structuredContent":{"error":{"code":"device-busy","message":"Device is controlled by another manzanero process (pid 4242, tap). Wait for it to finish or stop it; no input sent.","inputSent":"none","retry":"after-action","action":"wait"}},
 "isError":true}
```

Tools declare no output schema, so the MCP specification places no constraint on `structuredContent`; successful results keep using `structuredContent.result`. Unknown tools and invalid parameters remain JSON-RPC errors without this object.

### Exit codes

| Exit | Meaning |
| --- | --- |
| 0 | Success, or an answer that reports its own status (see below) |
| 1 | Failure; the category is in the JSON, not in the exit code |
| 124 | `wait-id`/`wait-label` timed out (an answer, JSON on stdout) |
| 130 / 143 | Interrupted by SIGINT / SIGTERM; release was attempted and is unverified |

Exit codes per category were considered and rejected: the JSON already carries the category, distinct codes would collide with the conventions above and with shells' own values, and a caller that branches on the reaction needs `inputSent` and `retry`, which an exit code cannot carry.

### Answers are not errors

Some commands report an unsuccessful outcome as a JSON answer on stdout with its own exit code, and are unaffected by the error format: `wake` (exit 1 for `unknown-display-state`, `not-awake` and `awake-locked`), the AX wait's timeout (exit 124), `readiness` (exit 1 unless CoreDevice prerequisites are present), `doctor` (exit 1 when an Xcode, CoreDevice or CoreSimulator tool is unavailable) and `handoff` (exit 1 unless the person acknowledged). Read their documented fields instead. In MCP, `wait_for_element`'s timeout and `wake_device`'s statuses do not set `isError`; readiness and doctor do, with their JSON under `structuredContent.result`.

## Facts

**`inputSent`** says whether anything that can change device state (touch, key, button, an accessibility action, an app install or launch, a file push, a clipboard write) may have reached the device during this call.

| Value | Meaning |
| --- | --- |
| `none` | Nothing was sent: the failure came first, or the command only reads |
| `possible` | Something was sent or attempted; its effect is unknown |
| `unknown` | The failure site cannot tell (every unclassified failure, and an Apple tool that may or may not have acted) |

A read-only command (`tree`, `wait-id`/`wait-label`, `screen`, `screenshot`, `details`, `apps`, `processes`, `files`, `pull`, `reports`, `report`, `logs`, `last-crash`, `readiness`, `media-status`, `devices`, `doctor`, `ocr`, `decode-ax-archive`) and every `--dry-run` report `none` for any failure, because they send nothing whatever stage failed. Recording sends no input either. `console` launches an app: a failed `simctl`/`devicectl` launch reports `unknown`, and a failure after the launch `possible` ([app logs](app-logs.md)).

**`retry`**

| Value | Meaning |
| --- | --- |
| `safe` | Repeating the identical call cannot duplicate a device effect. It may fail again |
| `after-inspection` | An effect may have happened. Observe the device (`tree`, `screen`) before deciding; never replay blindly |
| `after-action` | Nothing was sent, and repeating is pointless until `action` has been done |
| `no` | The identical call can never succeed; change it |

`retry` defaults from the other facts: anything with `inputSent` other than `none` is `after-inspection`. One site overrides it: a failed clipboard write before `paste` sends any key is `possible` but `safe`, because a retry writes the same text again and pastes once.

**`action`** (with `after-action`)

| Value | What has to happen |
| --- | --- |
| `wake` | Wake the display (`physical <UDID> wake`) and unlock the device |
| `wait` | Wait for the other owner of the device, or for the person answering a handoff |
| `human` | A person must act: enable Developer Mode, connect or trust the device, sign in or fix signing, change the Mac |
| `allow-firewall` | Allow incoming connections for this executable in the macOS firewall (see [recording](recording.md)) |

## Categories

| `code` | Meaning | Typical cause | What a caller should do | Input may have been sent? |
| --- | --- | --- | --- | --- |
| `usage` | The arguments are wrong | Bad coordinates, missing operand, unknown option or command, recording destination exists | Fix the call (`retry: no`) | No |
| `unsupported-operation` | The operation does not exist here | Simulator multi-contact input, paste or wake, unknown device operation, retired backend or helper executable | Use another operation (`retry: no`) | No |
| `device-not-ready` | Device prerequisites block the operation | Developer Mode disabled, device not connected or paired, no tunnel; a simulator that is not booted (the message names the `boot` command, which a caller may run itself) | Stop and ask a person (`action: human`) | No |
| `display-off` | The primary display is off or its state is unknown | Screen locked and dark before touch, capture or AX centre selection | Run `wake`, then retry (`action: wake`) | No |
| `device-busy` | Another owner controls the device | Another manzanero process holds the device lease; a native recording is already running in this process | Wait, then retry (`action: wait`) | No |
| `handoff-pending` | A human handoff is pending for the device | A mutation while the person has not answered; a second handoff | Wait for the person (`action: wait`) | No |
| `ambiguous-or-missing-target` | A selector, PID or identifier matched nothing, several things or the wrong thing | No match, duplicates, target offscreen or covered, PID not at the display centre, alias resolved to another device | Observe again and correct the selector or target | No |
| `precondition-changed` | Something changed between two checks | Display rotated, foreground app or element identity changed before the action | Observe again, then retry (`retry: safe`) | No |
| `tool-failed` | An Apple executable or framework step returned an error | `devicectl`, `simctl` or `xcodebuild` non-zero exit, an invalid capture | Read the message; inspect if `inputSent` is not `none` | Depends: `unknown` for a tool that may act |
| `transport-failed` | A connection, Apple service or device reply failed or was malformed | Tunnel assertion, RSD discovery, AX session, HID service not ready, media stream | Retry later if `inputSent` is `none`; otherwise inspect | Usually no; see `inputSent` |
| `timeout` | A deadline passed | An Apple tool timed out, the RSD connection or first video frame took too long | Inspect if `inputSent` is not `none`, then retry | Depends |
| `cancelled` | The operation was cancelled | MCP request cancelled, session shut down | Decide again; inspect if `inputSent` is not `none` | Depends |
| `signing-failed` | Xcode could not sign or provision the app | No team, account, certificate or profile, device not registered (from the build log) | Ask a person (`action: human`); see [Build & Run](build-run.md) | No |
| `host-requirement` | The Mac lacks something | macOS too old for native recording, no terminal or form-capable MCP host for a handoff, firewall drops video, lease directory unwritable | Fix the host (`action: human` or `allow-firewall`) | No |
| `input-outcome-unknown` | Input was attempted and its effect or release is unknown | HID barrier unconfirmed after sending, input stopped mid-schedule, AX action submitted without a usable reply or refused, paste keys failed after the clipboard changed, a later step failed after `wake` pressed a button | Inspect the screen; never replay automatically | Yes (`possible`) |
| `internal` | An internal invariant failed | A plan or encoding that should be impossible | Report it; retrying is unlikely to help | Usually no |
| `unclassified` | The failure site has not been classified | See below | Treat as `inputSent: unknown`, inspect before retrying | Unknown |

The set is deliberately small and closed; a new value would be a change to this document. Callers should treat an unrecognised value like `unclassified`.

## Where the facts come from

- **Input functions in the bridge.** `ADCPerformTouch`, `ADCPerformTwoContactTouch`, `ADCPressButton`, `ADCPressKeyboardKey`, `ADCPerformKeyboard` and `ADCPerformCancellableDigitizerReports` (and their simulator counterparts `ADCSimulatorPerformTouch`, `ADCSimulatorPerformKeyboard`, `ADCSimulatorPressKeyboardKey` and `ADCSimulatorPressButton`) return `ADCInputOutcomeUnknown` (2) when they fail after input was attempted (the two "do not replay automatically" paths) and another non-zero value when they stopped before sending any input. Swift maps the first to `input-outcome-unknown`/`possible` and the second to `transport-failed`/`none`. The messages are unchanged.
- **Accessibility actions** classify by the action's submission state, which their message already reports as `state=`: `not-sent` keeps the guard's category with `inputSent: none`; `submitted`, `refused` or `accepted` followed by a failure is `input-outcome-unknown`.
- **Read-only device queries** (identity details, displays, lock state) used by input commands run before any input, so their failures report `none`.
- **Wrapping.** When a failure adds context to an inner failure (for example "Recording failed: …" or "Direct physical wait failed: …"), it keeps the inner category.

## Unclassified sites

`Sources/Manzanero` constructs `CommandFailure` in 279 places (a helper such as `failure(_:)` counts once, however many guards call it; the 49 added with `logs`, `console` and `last-crash` are all classified). 273 are classified, 11 of them by keeping a wrapped failure's category. Six remain `unclassified`:

- `KeyedArchiveInspector`'s invalid-archive failure: it serves both offline `decode-ax-archive` files (a usage problem) and device replies (a transport problem), and cannot tell which.
- `NativeHEVCDecoder` (three sites, one of them its `failure(_:)` helper), `NativeVideoFrame` and native movie finalization: host-side VideoToolbox/AVFoundation failures whose cause (stream data or host) is not known at the site. They occur only during recording, so they still report `inputSent: none`.
- Errors that are not `CommandFailure` at all: Foundation and POSIX errors (a missing file for `ocr` or `decode-ax-archive`, malformed JSON from an Apple tool, socket errors), decoding errors and AVFoundation errors. They print exactly as before and are `unclassified` with `inputSent: unknown`, except that the accessibility action and tree paths, which know their stage, report `none` before the action.
- A wrapped failure keeps the inner category, so a wrapper around one of the above stays unclassified.
