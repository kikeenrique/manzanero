# Verification record

This is the evidence summary for the current implementation and the material failures that shaped it. It is organized by capability so readers do not have to reconstruct the latest state from an append-only development log.

**A build, fixture or dispatch receipt is not a hardware assertion.** Each result below applies to its stated backend/device/environment. Retired helper results are labeled separately. [Feature status](feature-status.md) describes current availability; [development tasks](development-tasks.md) explains repeatable checks.

## Environment and evidence handling

The latest physical checks used the designated iPhone 13 mini, iOS 27.2.1 (24B156), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2 and CoreDevice 651.32. Media work observed AVConference 2260.15.1. Some earlier input records used iOS 27.2 (24B119); results from one checkpoint do not establish all OS versions.

The phone had Developer Mode and Enable UI Automation enabled for the successful UI checks. Later checks found its display off. User preparation is not continuous proof that the device remains awake/unlocked.

Raw screenshots, movies, app/process inventories, addresses, device IDs, archives and stderr remain under ignored `tmp/`. They are not public fixtures. The Git commits named below retain the detailed implementation checkpoints; temporary artifact UUID lists and intermediate test counts are omitted here.

Checkpoint hashes below refer to the rewritten public history. The publication cleanup changed paths and documentation, not the recorded device observations.

## Current local validation

The latest implementation checkpoint passed 314 default Swift test functions through xcsift with zero errors/warnings; all 48 mise tasks validated. Default tests are local regression checks, not hardware runs. Live checks are explicitly enabled and may have device effects.

Coverage includes argument validation, literal subprocess arguments, bounded output/deadlines/reaping, DTX/archive parsing, identity/geometry guards, report encoding, timing/cleanup attempts, MCP routing/lifetime and recording artifacts. It does not establish the Apple service's delivery, exact scheduling, device-side cleanup or broad device compatibility.

## Discovery and readiness

**2026-11-11 through 2026-11-14 — current Apple-tool route.**

Physical CoreDevice details, app listing, Developer Mode/image preparation and pairing/connection observations were read successfully. The app inventory contained 74 entries including system components; it remains private. Physical inventory is unfiltered CoreDevice JSON and may contain simulators.

An explicitly disabled Developer Mode result blocked developer-operation dispatch with preparation guidance. Missing/unknown state was not treated as enabled.

The latest CLI and real MCP readiness checks reported:

- top-level `status: prerequisitesPresent`;
- `ui.displayPower: off`;
- `ui.passcodeRequired: false`, `ui.unlockedSinceBoot: true`;
- `ui.status: needsUserAction` with a wake instruction.

This verifies state reporting, not current UI unlock or UI Automation permission. The two UI queries are sequential. Wrong/missing identity, malformed Boolean data, ambiguous displays, failures and cancellation have local coverage.

Relevant checkpoints: `182ad0e` (initial readiness), `37ecf0a` (actionable display preflight), `cddd4a0` (separate UI observations). See [readiness](readiness.md).

### Transient wake, not reliable unattended wake

At `d58a229`, a fresh Apple display read showed off, one native `button lock` dispatch preceded an immediate active-display read, and the next media probe found it off again. The probe stopped before starting a stream. No passcode or unlock action was attempted and no button was replayed.

This is a transient observed state change, not a durable wake/unlock guarantee. Earlier native Home dispatch while off also left the display off. The side button can turn an awake screen off and is not an idempotent wake command.

## Direct physical input

**2026-11-12 through 2026-11-14 — project-owned in-process Apple backends.**

| Operation | Observed result | What remains unproven |
| --- | --- | --- |
| Home | Settings → Home in separate CLI/MCP checks; one later recording captured the transition | Every dispatch, other buttons, exact release |
| Tap/drag | Opened Settings, scrolled lists and navigated after fresh observation | Generic hittability/delivery, rotations, all apps |
| Long press | A 0.8-second Maps-icon hold opened its context menu through CLI/MCP | Universal timing threshold, failure release |
| Two-contact movement | Spread/inward pinch visibly changed Maps zoom through CLI/MCP | General independent paths and all recognizers |
| Timed schedules | Sampled swipe moved Home → App Library; repeated taps and a staggered two-contact spread zoomed Maps | Exact timestamps/individual lifts, broad contact patterns |
| Multi-tap / larger multi-drag | Two-contact MCP tap changed Maps zoom; three/five-path calls completed dispatch/barriers | Independent three/five-contact recognition; four-contact effect |
| ASCII typing | Mixed case, digits and shifted punctuation appeared in Settings search through CLI/MCP, then were cleared | Full layout/punctuation/field and maximum-length coverage |
| Unicode paste / Backspace | Synthetic accented/emoji/CJK text inserted after separate explicit paste-prompt approval; Backspace removed the final character | Other app/permission/layout states; rollback or release on failure |

Maps first-run preparation included explicit temporary permission/onboarding choices during testing. The tool does not automatically approve such prompts. Paste left the clipboard replaced with synthetic text.

Material negative results remain relevant:

- Some taps at visible General text and one Home call had no visible effect despite successful receipts.
- Scrolling and choosing a new target from a fresh image led to later successful navigation. The cause of the earlier misses was not isolated; an overlay was not proved.
- A three-contact attempt opened a place card rather than establishing its intended spread.
- Larger-contact screenshots did not prove independent tracking of every contact.

The project added a readiness barrier before ordinary button down events after mixed outcomes. Later Home checks succeeded, but that does not prove general reliability.

Key direct checkpoints: `5131483`, `98b5db5`, `0250200`, `49aa19a`, `1496281`, `f623d5b`, `6e9be0b`, `4f38e85`, `fb8c29c`, `3dbf7f2`, `1db8c86`, `e8c609f`. Contracts and limits are in [physical input](native-input.md), [multitouch](multitouch.md), [sequences](gesture-sequences.md) and [typing](physical-typing.md).

## Input cancellation and process shutdown

Local injected clocks/sinks verify full prevalidation, stop-before-future-events, release at last attempted positions, key/modifier release ordering, pre-cancelled no-send behavior and no duplicate release after balanced completion. A real Swift task cancelled during a long keyboard gap interrupted the synchronous scheduler. These establish attempted host ordering, not delivered contacts.

Scoped live iPhone checks cancelled nine-second holds/gestures after about two seconds. Follow-up readiness responses arrived before the uncancelled operation could finish. Screenshots were measured separately because Apple capture latency could hide early cancellation; one initial combined timing check failed and was retained as a failed timing check.

Owned CLI SIGINT/SIGTERM and MCP EOF/SIGINT/SIGTERM hold tests exited normally with 130/143 or EOF 0 after early interruption, without a late normal success response. Context-menu images established that some hold occurred, not exact delivered duration or release.

The MCP registry closes admissions, cancels and drains owned tasks. Local tests cover late admission, repeated shutdown, pending elicitation and the 30-second grace/force-exit path. Force-exit expiry itself was not demonstrated on a live device.

Checkpoints: `63f1c27`, `b34ae14`, `181d699`, `9087b03`. SIGKILL, crashes, cable loss, blocked synchronous calls, interrupted setup, cross-process ownership and quarantine after uncertain release remain unresolved. Text/clipboard changes are not rolled back.

## Physical accessibility and screen understanding

### Current native route

**2026-11-13/14 — Apple Network/RemoteXPC plus raw AX DTX.**

Diagnostic, CLI and real MCP captured 106 Settings nodes through explicit-PID and omitted-PID selection. A fresh screenshot matched the tree's logical geometry; MCP `get_screen` returned the native tree plus PNG.

The normalizer and guards have local coverage for bounded iterative decoding, node/depth limits, foreign references, target/status mismatches, opaque-token handling and non-atomic root rechecks. An unrelated type-11 notification with non-finite data motivated routing by bounded metadata before expanding matching responses.

A CLI identifier press navigated General → Información; a real MCP label press navigated back. Separate images verified those effects. The normal receipt still reports native acceptance rather than generic UI effect.

A CLI scroll moved a Settings row from outside/near the bottom into view. A later real MCP already-visible case returned native false with unchanged geometry and a passing visibility/hit postcondition. Subscription disable acknowledgement was unconfirmed in that MCP call, while tunnel release was acknowledged. Useful result data did not become cleanup proof.

Checkpoints: `dc85a7f`, `3e286f4`, `ded174a`, `86f0f57`. Broader apps, overlays, rotated/multiple displays, secure content, stable reusable handles and interruption recovery remain incomplete. See [native AX](direct-accessibility.md).

### Earlier transport/decoder failures

CoreDevice named AX sockets failed before subscription with error 4000, later exposing underlying POSIX 83 (`EDEVERR`). Raw RSD lookup/browse returned zero services even when Apple's inventory advertised AX. Apple `remotectl netcat` also failed before a DTX frame.

One early directory response succeeded, but later connected-FD/control attempts returned `Connection invalid`. Retaining an acknowledged tunnel assertion and copying service mode/version flags did not repair them. Generic TLS-renegotiation logs and differing Apple-tool entitlements did not establish a cause or justify changing phone settings.

Installed caller inspection later identified the unstarted-Network/mode-2 directory bootstrap, which succeeded. Earlier failed modes remain failed diagnostics, not fallbacks. See [transport](transport.md) and [protocol provenance](accessibility-protocol.md).

A synthetic deeply nested archive reproduced stack overflow during development; bounded iterative traversal replaced recursive expansion. DTX object/error kind mapping and low-byte auxiliary-tag interpretation were corrected against independent fixtures/references. Parser success alone did not establish a live tree.

### Screenshots and OCR

Awake/unlocked physical PNG capture succeeded at 1125×2436. Initial black captures preceded confirmed wake/unlock; their exact cause was not isolated. An earlier OCR attempt failed with `Failed to create CVPixelBuffer`.

Direct Vision OCR later recognized visible Spanish Settings labels with visually checked normalized bounds. One OCR-guided navigation opened Display & Brightness. Coordinate misses listed above show why text regions cannot be treated as hittable selectors.

The 120-second cooperative OCR deadline, cancellation draining and retained-image fallback have local tests. It is not a hard native cancellation bound. See [screen inspection](screen-understanding.md).

## Native media and recording

### Current owned path

**2026-11-14 — Apple negotiation, RTP/HEVC, VideoToolbox and AVFoundation.**

Read-only media-status passed through diagnostic, CLI and real MCP: support flags 972, AVC 2260.15.1, no running sessions in the checked state. This did not prove how earlier sessions ended or turn capability flags into capture proof.

Standard-RTP reception then delivered real packets under validated endpoint/cipher/profile bounds. HEVC reconstruction/VideoToolbox checks decoded 71 pictures with a Home input check and 65 without UI input. The tested coded image is 1136×2464 despite negotiated 1136×2448; only bounded padding is accepted.

Short CLI H.264 and MCP HEVC movies finalized and independently decoded with owned stop, fresh absence and tunnel release acknowledged. Later pixel-buffer work removed the movie JPEG roundtrip.

| Recording check | Observed result |
| --- | --- |
| 35-second CLI HEVC | 559 source frames, 35 local receiver-report sends; decoded artifact and required cleanup |
| 300-second CLI HEVC | Exactly 300 seconds, 5966 source frames, 295 report sends and 300 validated sender reports; stationary-screen scope |
| 20-second real MCP interaction | 360 frames and 20/20 report counters; 137-node AX read during capture, Home dispatch, then zero sessions |
| Temporal samples from interaction movie | Independently viewed Settings at time zero and Home near 18.983 seconds; numerical image difference alone was not the semantic assertion |

The interaction check establishes one AX-read/Home workflow during recording, not all gestures or every movie frame. The five-minute check does not prove motion quality or sustained frame rate.

Key checkpoints: `68beb1f`, `504ca28`, `d8aba6f`, `f88327f`, `d0c3e30`, `2ed88bc`, `3b5727b`.

### Material media failures

- The installed `AVCStreamOutput` access validator denied this process. The probe now fails before starting media; no allowlist override, process spoof or framework hook was applied.
- Earlier frame probes started owned streams but captured zero frames. Session-specific stop/fresh absence/tunnel release were acknowledged in the scoped checks.
- Early standard-RTP attempts received no packets within their budget.
- An actual CLI movie attempt exceeded the twelve-second first-frame budget despite an active owned stream; cleanup was acknowledged and no successful movie was published.
- The default physical `devicectl` recording capability returned error 1001 on this prepared phone.
- Historical helper movies left a visible sharing indicator after local helper exit. That result is not current owned-stop evidence.

`rtcp.negotiatedFeedback` is implemented with guarded native getters. Installed signatures were checked (`@`, `@`, `B`); a live value was not obtained because the phone's display was off. No PLI/FIR request or recovery behavior has been verified.

Receiver-report counts are local sends/validated received reports, not remote acknowledgements or proof that reports caused liveness. Startup, keyframe/crash/disconnect recovery, rotation and other devices remain unfinished. See [recording](recording.md).

### Recording interruption and reuse

At `2bc1c3e`, real MCP cancelled a 30-second requested recording after its first frame and an active-status check. Owned cleanup was observed about 0.107 seconds after cancellation, fresh status found zero sessions, no cancelled destination was published and a new two-second HEVC recording succeeded.

At `ab422a6`, active EOF/SIGINT/SIGTERM checks each passed once:

| Event | Exit | Observed host shutdown interval |
| --- | --- | --- |
| EOF | 0 | About 0.090 s |
| SIGINT | 130 | About 0.148 s |
| SIGTERM | 143 | About 0.100 s |

Each acknowledged owned cleanup, emitted no pending success output/partial published movie, found zero sessions from a separate process and recorded again there. These are observations, not latency guarantees. Cancellation/reuse also passed after pixel-buffer integration.

Forced exits, startup/finalization interruption, blocked framework calls and independent controllers remain unverified. An acknowledged stop plus fresh absence does not prove destruction of every native resource.

## Apps, files, reports and development

Physical Settings launch and app inventory succeeded. The launch option-order fix (`4c47998`) ensures devicectl options precede the bundle operand. One Safari URL preflight failed; broad physical URL/lifecycle claims are not made.

App-data command plans and an Apple-tool-owned temporary-domain synthetic copy round trip were checked. This is not actual app-container access/round-trip evidence. Physical saved-report listing passed. Download is implemented but hardware-unverified; parsing, symbolication, filtering and deletion are missing. See [feature status](feature-status.md).

Simulator screenshot and finite H.264/HEVC movie checks passed. Build & Run passed simulator project/Debug and workspace/Release flows with product validation/install/launch; complete physical signing/deployment remains unverified.

Human handoff has synthetic terminal/form completion and per-device mutation-pause coverage. No actual biometric/passcode/purchase action, automatic prompt detection or native notification is claimed.

## Retired implementations

These results are preserved as history, not current runtime availability:

| Former route | Historical evidence | Current implication |
| --- | --- | --- |
| AXe simulator adapter | SpringBoard tree → Settings label tap → Settings tree succeeded | Executable blocked; direct simulator input/AX replacement pending |
| idevice HID | Early phone unavailable through usbmuxd; later read-only HID discovery passed; Home/tap receipts lacked visible effect | Cause unresolved; not proof of current native input |
| idevice independent pairing | Protocol/build/validation existed | Live initial pairing/reconnection/input unverified; executable route blocked |
| idevice AX | Raw callback/offline decoding, Settings trees and selector navigation passed | Separate from unsuccessful idevice HID; replaced by native AX route |
| ipb native input/video helpers | Scoped input effects and short movies; video cleanup/sharing uncertainty | Helpers blocked; old tests do not validate current direct code |
| Finite OS trace bridge | Parser/duration/entry/byte-limit code tested | Live trace and remote cleanup unverified; route blocked |

The current policy is project-owned Apple API/framework calls or Apple executables. See [dependencies/provenance](dependencies.md); no commercial binary is a runtime dependency.

## Distribution and privacy checkpoints

The Manzanero rename passed all 314 local Swift tests with no build errors or warnings. Native multitouch and timed-gesture sender tests also passed without a device. All 48 mise tasks validated, and 41 documented command forms passed dry-run checks. The renamed stdio MCP server identified itself as `manzanero`, listed 33 tools and exited successfully on EOF without running device operations.

Both architecture builds and the universal `manzanero` beta archives passed packaging checks. Extraction into a Homebrew-style layout verified signatures, architectures, notices, symlink execution, version/help and a dry-run command. The `manzanero.rb` formula generated with valid Ruby syntax using a placeholder `example/manzanero` repository; that is a local generation check, not a real release URL or public Homebrew installation. Test environment variables now use the `MANZANERO_` prefix. No live-device verification was repeated for this rename.

`8681d00` added local universal beta archives, checksum/formula generation and the tag/manual workflow. Both architectures built, native version/help ran, signatures/linkage and Homebrew-style extraction/symlink smoke passed. The optimized archive was about 4.1 MiB and needed no supplemental Swift compatibility library. Root project licensing and hosting remain undecided; GitHub Actions, actual public release and public Homebrew install have not run.

The earlier source/history privacy review used Gitleaks 8.30.1 against the pre-cleanup snapshot and its 88 reachable commits and found no detected leaks. Those scan results apply to the original history, not the rewritten trees. The later publication cleanup preserved author identities, removed personal paths and private investigation material, and verified those specific removals throughout reachable history. No additional secrets scan was requested. See [public readiness](public-readiness.md).

## What these records do not establish

No result here completes all Apple-family coverage or reliable unattended testing. Important gaps include cross-process ownership, uncertain-release quarantine, crash/cable-loss recovery, broad app/overlay/orientation behavior, simulator input migration and dedicated iPad/Watch/TV/Duo validation.

When repeating a check, record the current versions/target/backend, separate transport acceptance from visible effect and cleanup, and retain failures rather than automatically retrying an input action.
