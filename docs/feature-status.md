# Feature status

This page describes current product availability, not historical helper capability. “Verified” always means a scoped live result on the recorded device/environment; it is not a general reliability guarantee. See [verification](verification.md) for evidence and failures.

## Current runtime availability

| Area | Available now | Evidence and remaining limits |
| --- | --- | --- |
| Discovery/preparation | CoreDevice/simulator inventory, doctor, physical readiness | Physical inventory may include simulators. Readiness includes display/passcode observations but does not verify UI Automation or current UI unlock. |
| Physical single-contact input | Home/buttons, tap, long press, swipe/drag | Home, Settings navigation/scroll and Maps context menu visually verified on iPhone 13 mini. Some taps/Home dispatches had no visible effect. |
| Keyboard | Named keys, US-layout ASCII typing, Unicode paste | Mixed ASCII, Backspace and synthetic Unicode checked in Settings search. Paste replaces clipboard; other layouts/apps/keys need coverage. |
| Coordinated contacts | Two-to-five-contact multi-tap/multi-drag, pinch, timed complete-state schedules | Two-contact Maps zoom and selected timed sequences verified. Three/five-contact dispatch passed without proof of independent gesture recognition; four-contact effects unverified. |
| Physical AX reads | Explicit-PID and portrait display-centre selected trees | Settings CLI/MCP trees and screenshot/tree workflow verified. Non-atomic, snapshot-local IDs; overlay, rotation and other-family coverage limited. |
| Physical AX actions | Exact identifier/label press; scroll-to-visible | Settings navigation and row movement verified. Target must resolve freshly; scroll requires materialized nodes and separate postcondition inspection. |
| Screen analysis | PNG capture, Vision OCR, native physical hierarchy with fallback | Spanish Settings OCR and selected OCR-guided navigation verified. OCR regions are not guaranteed hittable; recognition has a cooperative deadline. |
| Offline archive inspection | Swift/Foundation data-only structural decoding | Saved phone callback decoded locally. This is not fresh capture or a normalized tree. |
| Physical recording | Explicit native CoreDevice HEVC input, H.264/HEVC MP4 output | Short CLI/MCP, one five-minute capture and one 20-second AX/Home interaction verified with owned cleanup. Startup and recovery remain incomplete. Default devicectl capture failed on this phone. |
| Input/media cancellation | Cooperative release/stop attempts; MCP cancellation/EOF/signals | Scoped iPhone checks and recording reuse passed. Device-side release after failure, crash/disconnect recovery and cross-process ownership remain incomplete. |
| App operations | List/install/launch/uninstall, physical PID terminate, URLs | Physical app list and Settings launch verified. Other physical mutations/permissions need live coverage. |
| Container files | Nonrecursive list, raw pull/push | Command plans and a tool-owned temporary-domain round trip verified. Actual app-container access/round trips and `.xcappdata` export remain incomplete. |
| Saved reports | List/download | Physical listing verified; download is implemented but hardware-unverified. Parsing, symbolication, filtering and deletion are missing. |
| Build & Run | Explicit iOS project/workspace + scheme + target | Simulator project/workspace flows verified; physical signing/deployment and general progress/cancellation incomplete. |
| Human handoff | Terminal responses, MCP form completion, process-local mutation pause | Synthetic terminal/MCP checks only; no automatic prompt detection or native notifications. |
| Simulator lifecycle/capture | simctl apps, boot/shutdown, screenshot, recording | Scoped capture/lifecycle/development checks exist. Current simulator input and hierarchy are unavailable. |
| CLI/MCP interface | Shared command service; 30 stdio tools | No HTTP, durable sessions, coordinated activity view or uniform structured CLI errors. Host controls approvals. |

## Unavailable or missing

These named interfaces may have planners/catalog entries but cannot currently execute:

- AXe-backed simulator input, hierarchy and selector taps;
- idevice-backed `hid-info`, live raw `ax-snapshot`, finite `logs`, independent Wi-Fi pairing and pairing-file operations;
- historical ipb input/video helpers.

Execution policy blocks those non-Apple device binaries. Retained code and earlier successes do not make them supported runtime paths.

User-facing live mirroring, reusable semantic element handles, automatic permission/Face ID handling, crash recovery, cross-process controller leases and a complete assertion system are missing or incomplete.

## Apple-family coverage

| Family | Current scope |
| --- | --- |
| iPhone | Primary physical testing target; evidence mostly iPhone 13 mini |
| iPad | In scope; generic paths exist, but dedicated physical/multitasking/display validation is missing |
| Apple Watch | In scope; dedicated control and hardware verification missing |
| Apple TV | In scope; dedicated tvOS control and verification missing |
| iPhone Duo | In scope; posture/display/control verification missing |
| Simulators | Partial lifecycle/capture/development support; direct input/AX migration unfinished |

Accepting an identifier or passing a build does not establish support for a new family.

## How to read progress

Use three separate questions: is there an executable route, has that route been checked on this hardware, and does it recover from interruption/failure? A feature can answer yes to the first two and still be unsuitable for unattended use.

Physical controls/actions remain the priority. The [roadmap](roadmap.md) orders the remaining work; no percentage is assigned because counting commands would hide differences in scope and evidence.
