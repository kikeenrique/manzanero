# Roadmap

The goal is a Swift CLI with broad Apple-device inspection and control, plus optional MCP sharing the same operations. Current work prioritizes physical controls and the observe → act → inspect loop.

iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope. [Feature status](feature-status.md) is the current availability inventory; this page explains the remaining work.

## Priorities

1. **Make physical testing dependable.** Improve recording startup/keyframe recovery, input/stream failure handling, useful readiness diagnostics and cleanup uncertainty.
2. **Coordinate ownership.** Prevent independent processes from competing for contacts, keys or streams; handle uncertain release before admitting later input.
3. **Improve agent targeting.** Expand AX action/overlay/rotation coverage and useful postconditions without turning old snapshot IDs into stale action handles.
4. **Complete direct replacements.** Restore simulator input/AX and required diagnostics through project-owned Apple APIs or Apple executables.
5. **Validate other Apple families.** Add family-specific backends and live evidence rather than treating generic identifier acceptance as support.
6. **Finish operational delivery.** Run the beta workflow, publish immutable release assets and update the Homebrew tap after repository/licensing/publication decisions.

These are implementation priorities, not evidence that a feature is complete or a request to change device settings automatically.

## Remaining capabilities

| Area | Work still needed |
| --- | --- |
| Media | Reliable first frame, negotiated feedback/live keyframe recovery, crash/disconnect recovery, rotation, mirroring/audio and broader devices |
| Input | Broader key/layout/app coverage, three-to-five-contact recognition, precise failure/release evidence and controller coordination |
| Accessibility | Overlay/embedded-process and rotated-display handling, broad selectors/actions, stable session semantics and recovery |
| Screens/OCR | Broader accuracy and targeting evidence; OCR text regions do not establish hittability |
| App development | Physical signing/deployment, scheme discovery, progress/cancellation, crash/source integration |
| Data/diagnostics | Actual app-container coverage, `.xcappdata` workflows, report downloads/parsing/symbolication, direct finite logs |
| Agents | Durable sessions/activity, broader assertions, automatic human-prompt detection and notifications |
| Interface | Consistent machine-readable CLI errors, later protocol versions where justified, optional HTTP if needed |

Readiness now distinguishes CoreDevice prerequisites from UI observations. It still cannot verify the Enable UI Automation switch or prove current UI unlock. A transient side-button wake observation does not establish unattended wake.

## Architecture constraints

Device operations communicate with Apple frameworks/APIs from this project's code or Apple executables. Non-Apple device helpers remain blocked. Use maintained general-purpose libraries where useful, and preserve attribution for implementation references.

Keep private interfaces behind backend boundaries. Avoid automatic replay of input or a fallback that changes the operation's semantics. Surface native acceptance, observed effect and cleanup as separate facts.

## Implementation references

Independent protocol references and their licenses are documented in [dependencies.md](dependencies.md). The capability inventory distinguishes those references from this project's implemented routes and live verification.

## Completion criteria

A build or dry run proves planning/compilation, not hardware behavior. Completion requires evidence for the claimed platform, device family, transport and operation, including material failure and interruption cases. A returned receipt alone cannot establish UI effect, exact contact delivery or release.
