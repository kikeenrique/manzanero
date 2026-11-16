# Roadmap

The goal is a Swift CLI with broad Apple-device inspection and control, plus optional MCP sharing the same operations. Current work prioritizes physical controls and the observe → act → inspect loop.

iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope. [Feature status](feature-status.md) is the current availability inventory; this page explains the remaining work.

## Priorities

1. **Make physical testing dependable.** Improve recording startup/keyframe recovery, input/stream failure handling, useful readiness diagnostics and cleanup uncertainty.
2. **Coordinate ownership.** A per-device lease now refuses a second process's input or native recording. Still needed: live two-process verification, and handling uncertain release before admitting later input.
3. **Improve agent targeting.** Expand AX action/overlay/rotation coverage and useful postconditions without turning old snapshot IDs into stale action handles.
4. **Complete direct replacements.** Simulator trees, element actions, waits, one-to-five-contact touch and gesture sequences in any orientation (iPhone and iPad), Home/lock, keys, ASCII typing and Unicode entry by AX set-value are back in process ([simulator input](simulator-input.md)). Still needed: simulator `wake`, set-value tried on a phone, then the required diagnostics, all through project-owned Apple APIs or Apple executables.
5. **Validate other Apple families.** Add family-specific backends and live evidence rather than treating generic identifier acceptance as support.
6. **Finish operational delivery.** Run the beta workflow in the public repository, publish immutable release assets and update and test the Homebrew tap.

These are implementation priorities, not evidence that a feature is complete or a request to change device settings automatically.

## Owner decisions, 2026-11-16

| Topic | Decision | State |
| --- | --- | --- |
| Typing and keyboard layouts | `type` must work with any keyboard layout, not only the US one, on physical devices and simulators | Not started; needs a design for how the layout is known or chosen |
| `set-value` on physical devices | Enable it; it is wanted on phones as well as simulators | Not started; one change and a phone test |
| `handoff` live test | Do it only when the owner says so | Waiting for the owner |
| Apple TV, Apple Watch, iPhone Duo | Quick research on their simulators first (all three have one installed) | Research in progress |
| Decoded-JPEG video mode in the bridge | Keep it and test it; do not remove it | Not started; no command reaches it yet |

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
