# Roadmap

The goal is a Swift CLI with broad Apple-device inspection and control, plus optional MCP sharing the same operations. Current work prioritizes physical controls and the observe → act → inspect loop.

iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope. [Feature status](feature-status.md) is the current availability inventory; this page explains the remaining work.

## Priorities

1. **Make physical testing dependable.** Improve recording startup/keyframe recovery, input/stream failure handling, useful readiness diagnostics and cleanup uncertainty.
2. **Coordinate ownership.** A per-device lease now refuses a second process's input or native recording. Still needed: live two-process verification, and handling uncertain release before admitting later input.
3. **Improve agent targeting.** Expand AX action/overlay/rotation coverage and useful postconditions without turning old snapshot IDs into stale action handles.
4. **Complete direct replacements.** Simulator trees, element actions, waits, one-to-five-contact touch and gesture sequences in any orientation (iPhone and iPad), Home/lock, keys, typing in a named keyboard layout and Unicode entry by AX set-value are back in process ([simulator input](simulator-input.md)). Set-value also runs on physical devices. Still needed: simulator `wake`, a phone check of non-US layouts, then the required diagnostics, all through project-owned Apple APIs or Apple executables.
5. **Validate other Apple families.** Add family-specific backends and live evidence rather than treating generic identifier acceptance as support.
6. **Finish operational delivery.** Run the beta workflow in the public repository, publish immutable release assets and update and test the Homebrew tap.

These are implementation priorities, not evidence that a feature is complete or a request to change device settings automatically.

## Owner decisions, 2026-11-16

| Topic | Decision | State |
| --- | --- | --- |
| Typing and keyboard layouts | `type` must work with any keyboard layout, not only the US one, on physical devices and simulators | Built: the caller names the layout (`--layout`, `MANZANERO_KEYBOARD_LAYOUT`, MCP `layout`), tables come from the Mac's own layouts ([research](keyboard-layouts.md)), and a simulator's explicit layout setting is checked first. Verified on a simulator in five layouts ([verification](verification.md#keyboard-layouts-on-the-simulator)); a phone's layout cannot be read. On the iPhone 13 mini, Spanish – ISO typed exactly and the default `us` did not, because that phone uses Spanish – ISO on its own ([verification](verification.md#keyboard-layouts-on-the-phone)). Open: how to know a phone's layout without being told |
| `set-value` on physical devices | Enable it; it is wanted on phones as well as simulators | Done: enabled and run on the iPhone 13 mini ([verification](verification.md#unicode-entry-by-set-value-on-the-phone)) |
| `handoff` live test | Do it only when the owner says so | Waiting for the owner |
| Apple TV, Apple Watch, iPhone Duo | Quick research on their simulators first (all three have one installed) | Research done: [other families](other-families-research.md). Most commands already work on tvOS and watchOS; nothing built yet |
| Decoded-JPEG video mode in the bridge | Keep it and test it; do not remove it | Not started; no command reaches it yet |
| Other families: what to build | All of it: selectable Duo display, tvOS `remote`, watch `crown`, press with duplicate labels, tvOS focus and touch surface, and Duo fold | Built and run on simulators, except the Apple TV remote's touch surface, which could not be made to work ([guide](other-families.md)); the fold is in the next row. Left over: trees and touch on the Duo's inner display, the watch's left side button, keyboard input on watchOS, `wait --until focused` on physical devices, and an MCP call sent right after initialization that sometimes gets no answer |
| Duo fold | "Folding is missing in simctl. Look how other tools do it." | Route found and exercised on a simulator: a vendor-defined HID event sets the hinge angle and a CoreDevice stream reads it ([fold research](duo-fold-research.md)). `fold`, `unfold` and `hinge <degrees>` are built and verified on one simulator ([guide](other-families.md#fold-iphone-duo)); reading the angle and following the active display are not built yet |

## Remaining capabilities

| Area | Work still needed |
| --- | --- |
| Media | Reliable first frame, negotiated feedback/live keyframe recovery, crash/disconnect recovery, rotation, mirroring/audio and broader devices |
| Input | Broader key/layout/app coverage, how apps recognize three-to-five-contact gestures (delivery is now measured), precise failure/release evidence and controller coordination |
| Accessibility | Overlay/embedded-process and rotated-display handling, broad selectors/actions, stable session semantics and recovery |
| Screens/OCR | Broader accuracy and targeting evidence; OCR text regions do not establish hittability |
| App development | Physical signing/deployment, scheme discovery, progress/cancellation, crash/source integration |
| Data/diagnostics | Actual app-container coverage, `.xcappdata` workflows, live check of physical `console` and `last-crash` (report download), symbolication, physical `logs` through the native `os_trace_relay` only if `console` proves insufficient ([app logs](app-logs.md)) |
| Agents | Durable sessions/activity, live verification of the bounded exact-selector AX wait and assertions beyond it, automatic human-prompt detection and notifications |
| Interface | Classify the remaining unclassified failure sites and non-`CommandFailure` errors ([errors](errors.md#unclassified-sites)), later protocol versions where justified, optional HTTP if needed |

Readiness now distinguishes CoreDevice prerequisites from UI observations. It still cannot verify the Enable UI Automation switch or prove current UI unlock. A transient side-button wake observation does not establish unattended wake.

Two research notes size agent-facing work: [simulator input and UI tree](simulator-input-research.md) (milestones 1 to 8 implemented) and [app logs](app-logs-research.md) (milestones 1 to 6 implemented, 6 unverified on hardware; 7, the native relay, not built).

Several recent changes have local tests only. The [next live check plan](live-check-plan.md) orders their first run on a phone.

## Architecture constraints

Device operations communicate with Apple frameworks/APIs from this project's code or Apple executables. Non-Apple device helpers remain blocked. Use maintained general-purpose libraries where useful, and preserve attribution for implementation references.

Keep private interfaces behind backend boundaries. Avoid automatic replay of input or a fallback that changes the operation's semantics. Surface native acceptance, observed effect and cleanup as separate facts.

## Implementation references

Independent protocol references and their licenses are documented in [dependencies.md](dependencies.md). The capability inventory distinguishes those references from this project's implemented routes and live verification.

## Completion criteria

A build or dry run proves planning/compilation, not hardware behavior. Completion requires evidence for the claimed platform, device family, transport and operation, including material failure and interruption cases. A returned receipt alone cannot establish UI effect, exact contact delivery or release.
