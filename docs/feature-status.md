# Feature status

This page describes current product availability, not historical helper capability. “Verified” always means a scoped live result on the recorded device/environment; it is not a general reliability guarantee. See [verification](verification.md) for evidence and failures.

## Current runtime availability

| Area | Available now | Evidence and remaining limits |
| --- | --- | --- |
| Discovery/preparation | CoreDevice/simulator inventory, doctor, physical readiness | Physical inventory may include simulators. Readiness includes display/passcode observations but does not verify UI Automation or current UI unlock. |
| Physical single-contact input | Home/buttons, tap, long press, swipe/drag | Home, Settings navigation/scroll and Maps context menu visually verified on iPhone 13 mini. Delivery measured with the probe app on that phone: 150/150 actions after a fix for short gestures lost when the connection closed too early. |
| Keyboard | Named keys, typing in a named keyboard layout (any layout the Mac ships, with Shift, Option and dead keys; `keyboard-layouts` lists them), Unicode paste, Unicode entry by AX set-value | US ASCII typing, Backspace and synthetic Unicode paste checked in Settings search on iPhone 13 mini. Paste replaces clipboard. Set-value entered accented text, emoji, CJK and Arabic in the probe's field on that phone; other apps untested. Layouts, Option and dead keys verified on a simulator (US, Spanish – ISO, German, French, Latin American) and, for Spanish – ISO only, on that phone. A phone's layout setting cannot be read, so the caller must name it (receipt `deviceLayout: not-read`); the test phone used Spanish – ISO without anyone choosing it, so the default `us` typed wrong punctuation there. |
| Coordinated contacts | Two-to-five-contact multi-tap/multi-drag, pinch, timed complete-state schedules | Two-contact Maps zoom and selected timed sequences verified. The probe app received two, three, four and five simultaneous contacts as sent on iPhone 13 mini. What apps' gesture recognizers make of three or more contacts is not established. |
| Physical AX reads | Explicit-PID and portrait display-centre selected trees | Settings CLI/MCP trees and screenshot/tree workflow verified. Non-atomic, snapshot-local IDs; overlay, rotation and other-family coverage limited. |
| Physical AX actions | Exact identifier/label press; scroll-to-visible | Settings navigation and row movement verified. Target must resolve freshly; scroll requires materialized nodes and separate postcondition inspection. |
| Physical AX waits | Read-only bounded wait (`wait`, MCP `wait_for_element`) for visible, gone, enabled, disabled or exact value, in one session | Implemented and tested locally with fake sessions and virtual time; not verified on hardware. Snapshot cost, idle-subscription callbacks and exited-PID behavior are unobserved. |
| Screen analysis | PNG capture, Vision OCR, native physical hierarchy with fallback | Spanish Settings OCR and selected OCR-guided navigation verified. OCR regions are not guaranteed hittable; recognition has a cooperative deadline. |
| Offline archive inspection | Swift/Foundation data-only structural decoding | Saved phone callback decoded locally. This is not fresh capture or a normalized tree. |
| Physical recording | Explicit native CoreDevice HEVC input, H.264/HEVC MP4 output | Short CLI/MCP, one five-minute capture and one 20-second AX/Home interaction verified with owned cleanup. Startup and recovery remain incomplete. Default devicectl capture failed on this phone. |
| Input/media cancellation | Cooperative release/stop attempts; MCP cancellation/EOF/signals | Scoped iPhone checks and recording reuse passed. Device-side release after failure and crash/disconnect recovery remain incomplete. |
| Cross-process ownership | Per-device lease for physical and simulator input, AX actions and native recording; a second process is refused | Local tests; one live two-process check on a simulator (a tap during another process's long press was refused as `device-busy`), none on a physical device. Host-side exclusivity does not prove an earlier owner released the device. See [physical input](native-input.md#ownership-across-processes). |
| App operations | List/install/launch/uninstall, physical PID terminate, URLs | Physical app list and Settings launch verified. Other physical mutations/permissions need live coverage. |
| Container files | Nonrecursive list, raw pull/push | Command plans and a tool-owned temporary-domain round trip verified. Actual app-container access/round trips and `.xcappdata` export remain incomplete. |
| Saved reports | List/download; `last-crash` filters and parses the newest crash | Physical listing verified; one report downloaded on iPhone 13 mini. [`last-crash`](app-logs.md#last-crash) parsing and simulator selection verified on one iPhone Air simulator; physical `last-crash` found and summarised the probe's deliberate abort on iPhone 13 mini. Symbolication and deletion are missing. |
| App output | Simulator `logs` (unified log, bounded), `console` (stdout/stderr tails) on both platforms | [App logs](app-logs.md). Simulator `logs` and `console` verified with the probe app on one iPhone Air simulator (iOS 27.2). Physical `console` returned the probe's stdout, stderr and mirrored log lines on iPhone 13 mini, including for a launch that aborted; physical `logs` is not implemented. |
| Build & Run | Explicit iOS project/workspace + scheme + target | Simulator project/workspace flows verified; physical signing/deployment and general progress/cancellation incomplete. |
| Human handoff | Terminal responses, MCP form completion, process-local mutation pause | Synthetic terminal/MCP checks only; no automatic prompt detection or native notifications. |
| Simulator lifecycle/capture | simctl apps, boot/shutdown, screenshot, recording | Scoped capture/lifecycle/development checks exist. |
| Simulator input and AX | [In-process](simulator-input.md) tree, press/scroll by id or label, waits, tap, long press, swipe/drag, pinch, multi-tap and multi-drag with two to five contacts, timed gesture sequences, Home/lock, named keys, typing in a named keyboard layout (checked against the simulator's own setting first), Unicode entry by AX set-value, on a booted simulator by UUID | One iPhone 17e simulator, iOS 27.2, probe app and Settings: 48/48 single-contact touches, 20/20 two-contact actions and 70/70 built-in-plan actions (145/145 contacts, up to five at once) delivered, presses, scroll, waits, Home/lock/unlock swipe, typing and 14 Unicode set-values observed. [Typing in five layouts](verification.md#keyboard-layouts-on-the-simulator) gave the exact text, including dead keys, Shift and Option, and a different explicit simulator layout was refused before input. Landscape and iPad: touch mapped like a phone's and AX frames and hit points mapped by orientation; 70/70 built-in-plan actions in landscape on the iPhone and in portrait and landscape on an iPad mini simulator. Home Screen trees are read at depth 10 after the full-depth snapshot comes back empty (about 12 s); volume buttons showed the HUD. Other runtimes and families untested. |
| CLI/MCP interface | Shared command service; 37 stdio tools; classified failures as opt-in CLI JSON (`--error-format json`) and MCP `structuredContent.error` ([errors](errors.md)) | Error classification is unit-tested only; a few host-side recording and archive failures and non-`CommandFailure` errors remain unclassified. No HTTP, durable sessions or coordinated activity view. Host controls approvals. |

## Unavailable or missing

- Simulator `wake`: refused as not implemented (`unsupported-operation`). Simulator `paste` is refused because `simctl pbcopy` did not reach the pasteboard; `type` of text the named layout cannot produce is refused in favour of set-value, on both platforms.
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
| Simulators | Lifecycle/capture/development support; one-to-five-contact input, keys, AX and set-value checked on one iOS simulator runtime, on an iPhone in portrait and landscape and an iPad mini; other families unfinished |

Accepting an identifier or passing a build does not establish support for a new family.

## How to read progress

Use three separate questions: is there an executable route, has that route been checked on this hardware, and does it recover from interruption/failure? A feature can answer yes to the first two and still be unsuitable for unattended use.

Physical controls/actions remain the priority. The [roadmap](roadmap.md) orders the remaining work; no percentage is assigned because counting commands would hide differences in scope and evidence.
