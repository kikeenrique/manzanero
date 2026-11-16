# Feature status

This page describes current product availability, not historical helper capability. “Verified” always means a scoped live result on the recorded device/environment; it is not a general reliability guarantee. See [verification](verification.md) for evidence and failures.

## Current runtime availability

| Area | Available now | Evidence and remaining limits |
| --- | --- | --- |
| Discovery/preparation | CoreDevice/simulator inventory, doctor, physical readiness | Physical inventory may include simulators. Readiness includes display/passcode observations but does not verify UI Automation or current UI unlock. |
| Physical single-contact input | Home/buttons, tap, long press, swipe/drag | Home, Settings navigation/scroll and Maps context menu visually verified on iPhone 13 mini. Delivery measured with the probe app on that phone: 150/150 actions after a fix for short gestures lost when the connection closed too early. |
| Keyboard | Named keys, US-layout ASCII typing, Unicode paste | Mixed ASCII, Backspace and synthetic Unicode checked in Settings search. Paste replaces clipboard; other layouts/apps/keys need coverage. |
| Coordinated contacts | Two-to-five-contact multi-tap/multi-drag, pinch, timed complete-state schedules | Two-contact Maps zoom and selected timed sequences verified. The probe app received two, three, four and five simultaneous contacts as sent on iPhone 13 mini. What apps' gesture recognizers make of three or more contacts is not established. |
| Physical AX reads | Explicit-PID and portrait display-centre selected trees | Settings CLI/MCP trees and screenshot/tree workflow verified. Non-atomic, snapshot-local IDs; overlay, rotation and other-family coverage limited. |
| Physical AX actions | Exact identifier/label press; scroll-to-visible | Settings navigation and row movement verified. Target must resolve freshly; scroll requires materialized nodes and separate postcondition inspection. |
| Physical AX waits | Read-only bounded wait (`wait-id`/`wait-label`, MCP `wait_for_element`) for visible, gone, enabled, disabled or exact value, in one session | Implemented and tested locally with fake sessions and virtual time; not verified on hardware. Snapshot cost, idle-subscription callbacks and exited-PID behavior are unobserved. |
| Screen analysis | PNG capture, Vision OCR, native physical hierarchy with fallback | Spanish Settings OCR and selected OCR-guided navigation verified. OCR regions are not guaranteed hittable; recognition has a cooperative deadline. |
| Offline archive inspection | Swift/Foundation data-only structural decoding | Saved phone callback decoded locally. This is not fresh capture or a normalized tree. |
| Physical recording | Explicit native CoreDevice HEVC input, H.264/HEVC MP4 output | Short CLI/MCP, one five-minute capture and one 20-second AX/Home interaction verified with owned cleanup. Startup and recovery remain incomplete. Default devicectl capture failed on this phone. |
| Input/media cancellation | Cooperative release/stop attempts; MCP cancellation/EOF/signals | Scoped iPhone checks and recording reuse passed. Device-side release after failure and crash/disconnect recovery remain incomplete. |
| Cross-process ownership | Per-device lease for physical and simulator input, AX actions and native recording; a second process is refused | Local tests; one live two-process check on a simulator (a tap during another process's long press was refused as `device-busy`), none on a physical device. Host-side exclusivity does not prove an earlier owner released the device. See [physical input](native-input.md#ownership-across-processes). |
| App operations | List/install/launch/uninstall, physical PID terminate, URLs | Physical app list and Settings launch verified. Other physical mutations/permissions need live coverage. |
| Container files | Nonrecursive list, raw pull/push | Command plans and a tool-owned temporary-domain round trip verified. Actual app-container access/round trips and `.xcappdata` export remain incomplete. |
| Saved reports | List/download; `last-crash` filters and parses the newest crash | Physical listing verified; download is implemented but hardware-unverified. [`last-crash`](app-logs.md#last-crash) parsing and simulator selection verified on one iPhone Air simulator; physical `last-crash` only by unit tests and dry run. Symbolication and deletion are missing. |
| App output | Simulator `logs` (unified log, bounded), `console` (stdout/stderr tails) on both platforms | [App logs](app-logs.md). Simulator `logs` and `console` verified with the probe app on one iPhone Air simulator (iOS 27.2). Physical `console` is unverified on hardware; physical `logs` is not implemented. |
| Build & Run | Explicit iOS project/workspace + scheme + target | Simulator project/workspace flows verified; physical signing/deployment and general progress/cancellation incomplete. |
| Human handoff | Terminal responses, MCP form completion, process-local mutation pause | Synthetic terminal/MCP checks only; no automatic prompt detection or native notifications. |
| Simulator lifecycle/capture | simctl apps, boot/shutdown, screenshot, recording | Scoped capture/lifecycle/development checks exist. |
| Simulator input and AX | [In-process](simulator-input.md) tree, press/scroll by id or label, waits, tap, long press, swipe/drag, pinch and two-path multi-drag, Home/lock, named keys, US-layout typing, Unicode entry by AX set-value, on a booted simulator by UUID | One iPhone 17e simulator, iOS 27.2, probe app and Settings: 48/48 single-contact touches and 20/20 two-contact actions delivered, presses, scroll, waits, Home/lock/unlock swipe, typing and 14 Unicode set-values observed. Home Screen trees come back empty; rotation, iPad, other runtimes and families untested. Three to five contacts not implemented. |
| CLI/MCP interface | Shared command service; 36 stdio tools; classified failures as opt-in CLI JSON (`--error-format json`) and MCP `structuredContent.error` ([errors](errors.md)) | Error classification is unit-tested only; a few host-side recording and archive failures and non-`CommandFailure` errors remain unclassified. No HTTP, durable sessions or coordinated activity view. Host controls approvals. |

## Unavailable or missing

- Simulator three-to-five-contact input (`multi-tap`, `multi-drag` with three or more paths, `gesture`) and `wake`: refused as not implemented (`unsupported-operation`). Simulator `paste` is refused because `simctl pbcopy` did not reach the pasteboard; non-ASCII `type` is refused in favour of set-value. Volume buttons and rotation are not implemented.
- Physical `set-value-id`/`set-value-label`: refused (`unsupported-operation`) until the request has been tried on a phone.
- Physical `hid-info` and live raw `ax-snapshot`: no direct Apple replacement yet; they fail as an unsupported physical-device operation. Physical `logs` is refused as `unsupported-operation` until the native `os_trace_relay` route exists ([app logs](app-logs.md)). Offline `decode-ax-archive` still works.
- Independent Wi-Fi pairing (`pair wifi`) and `--pairing-file`: not recognised as commands. Pair through Xcode/CoreDevice.

These routes used to reach AXe, idevice or ipb helpers. The CLI no longer contains them (see [retired helpers](dependencies.md#retired-helpers)), and execution policy would refuse those binaries anyway.

User-facing live mirroring, reusable semantic element handles, automatic permission/Face ID handling, crash recovery, quarantine after an uncertain release and a complete assertion system are missing or incomplete.

## Apple-family coverage

| Family | Current scope |
| --- | --- |
| iPhone | Primary physical testing target; evidence mostly iPhone 13 mini |
| iPad | In scope; generic paths exist, but dedicated physical/multitasking/display validation is missing |
| Apple Watch | In scope; dedicated control and hardware verification missing |
| Apple TV | In scope; dedicated tvOS control and verification missing |
| iPhone Duo | In scope; posture/display/control verification missing |
| Simulators | Lifecycle/capture/development support; single-contact input, keys and AX checked on one iPhone simulator runtime; multi-contact, rotation, iPad and other families unfinished |

Accepting an identifier or passing a build does not establish support for a new family.

## How to read progress

Use three separate questions: is there an executable route, has that route been checked on this hardware, and does it recover from interruption/failure? A feature can answer yes to the first two and still be unsuitable for unattended use.

Physical controls/actions remain the priority. The [roadmap](roadmap.md) orders the remaining work; no percentage is assigned because counting commands would hide differences in scope and evidence.
