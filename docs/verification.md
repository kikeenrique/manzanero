# Verification record

This is the evidence summary for the current implementation and the material failures that shaped it. It is organized by capability so readers do not have to reconstruct the latest state from an append-only development log.

**Commands recorded before 2026-11-16 use the earlier grammar**, with the platform and device first (`physical <UDID> tap 0.5 0.5`, `simulator <UUID> press-id <id>`). From that date the CLI names the operation first and the target as an option (`tap 0.5 0.5 --device <UDID>`, `press --id <id> --simulator <UUID>`); see the [argument parser proposal](cli-argument-parser-proposal.md). The records below are kept as they were run.

**A build, fixture or dispatch receipt is not a hardware assertion.** Each result below applies to its stated backend/device/environment. Retired helper results are labeled separately. [Feature status](feature-status.md) describes current availability; [development tasks](development-tasks.md) explains repeatable checks.

## Environment and evidence handling

The latest physical checks used the designated iPhone 13 mini, iOS 27.2.1 (24B156), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2 and CoreDevice 651.32. Media work observed AVConference 2260.15.1. Some earlier input records used iOS 27.2 (24B119); results from one checkpoint do not establish all OS versions.

The phone had Developer Mode and Enable UI Automation enabled for the successful UI checks. Later checks found its display off. User preparation is not continuous proof that the device remains awake/unlocked.

Raw screenshots, movies, app/process inventories, addresses, device IDs, archives and stderr remain under ignored `tmp/`. They are not public fixtures. The Git commits named below retain the detailed implementation checkpoints; temporary artifact UUID lists and intermediate test counts are omitted here.

Checkpoint hashes below refer to the rewritten public history. The publication cleanup changed paths and documentation, not the recorded device observations.

## Current local validation

The latest implementation checkpoint (typing in a named keyboard layout, 2026-11-16) passed 571 default Swift tests through xcsift with zero errors/warnings, normally and once with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, and all 41 mise tasks validated. The checkpoint before it (app logs, console and crashes, 2026-11-16) passed 516 default Swift tests through xcsift with zero errors/warnings, three times normally and three times with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (one earlier strict run failed an existing streaming-runner wall-clock bound while new blocking tests shared the single pool thread; those suites now run on a dedicated thread); `mise run probe-app:test` passed 98; all 40 mise tasks validated; `mise run test:probe-touch <UDID> --dry-run` exited 0. Default tests are local regression checks, not hardware runs. Live checks are explicitly enabled and may have device effects.

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

### Guarded wake

**2026-11-15 — `physical <UDID> wake` at `dbac428`**, iPhone 13 mini with no passcode and Auto-Lock set to Never, macOS 27.2.1, Xcode 27.2 (27B52).

Readiness first reported `ui.displayPower: off`, `passcodeRequired: false`. One `wake` then returned `status: awake` with `displayPowerBefore: off`, `displayPower: on`, `sideButtonPressed: true` and `homePressed: true`, exit 0. A screenshot taken afterwards showed the Home screen, and three further readiness reads over the next seconds still reported the display on. A second `wake` on the lit display returned `already-awake` with both press fields false: nothing was sent.

This was one run on one phone. It does not establish behaviour with a passcode, on a lock screen with a notification or call, after a restart before first unlock, or on other devices. Unlike the earlier bare side-button press, the display stayed on; whether the Home press is what made the difference was not isolated.

The same run was the first on hardware for the command service's own queue, the per-device lease and the prefetched identity details. One side-button press and one Home press were dispatched through them, and the lease file was left zero-length afterwards. That is a single observation, not a two-process lease check.

### First live run of the queue, lease, wait and trimmed bridge

**2026-11-15, after `a59af0c`**, same iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52). The build included the removal of unreachable bridge paths.

| Check | Observed |
| --- | --- |
| `tree` on the Home screen | 245 nodes in about 5 s; subscription stop and tunnel release acknowledged |
| `button home`, `launch` of Settings, `screenshot` | Dispatched; the screenshot showed Settings |
| Lease across two processes | While one process held an 8 s `long-press`, a second process's `tap` exited 1 at once with `Device is controlled by another manzanero process (pid …, long-press)`. A `tree` from the second process succeeded. After the hold, a `tap` was accepted and the lease file was empty |
| SIGINT during an 8 s `long-press` | Exit 130 with the interruption message and no receipt; the next `tap` was accepted; the screen was unchanged |
| `wait-id` for a visible Settings row | `condition-met` on the first poll in about 1 s |
| `press-id` on that row, then `wait-id … --until gone` | The press was accepted and a screenshot showed the next page; the wait met on its first poll |
| `wait-label` for text that does not exist, 3 s timeout | Exit 124, `timed-out`, 3 polls, cleanup acknowledged |
| `wait-label` for a visible Settings row | First attempt timed out as `ambiguous`: the row and a hidden text node inside it share the label. After the change that accepts one visible match among explicitly hidden ones, it met on the first poll and reported the row's identifier |

One `wait-id` reported `subscriptionStop: unconfirmed` while its tunnel release was acknowledged; the others acknowledged both. The cause was not investigated.

**Native recording failed.** Five 3-second `--recording-backend coredevice` attempts in a row ended with `exceeded its twelve-second first-frame budget`, `packets=0`, with owned stop, stream absence and tunnel release acknowledged each time. A build of `276ec6c`, the code as it stood before any of this day's changes, failed the same way twice, so the failure is not attributed to those changes. `media-status` reported no running session and support flags 972. The recordings that succeeded on 2026-11-14 have not been reproduced since; the cause is unknown.

**The cause appears to be the macOS firewall.** It was on, with an "allow incoming connections" rule for this project's earlier executable name and path and none for `manzanero`. The opt-in packet probe, which runs the same media code inside Apple's SwiftPM test helper (a process the firewall does allow), received 194 datagrams (about 205 kB) in two seconds from the same phone minutes later, while the `manzanero` executable received none in six attempts. After the owner added a firewall rule for the executable, `doctor` reported `allowed` and recording worked: a 3-second HEVC capture produced 51 source frames at 1136×2464 with every cleanup acknowledged, and nine of eleven 2–3-second captures succeeded in all, including six in a row after a rebuild at the same path. The two failures happened back to back before any packet stage, with `Apple pairing daemon did not select the exact hardware endpoint within the bounded browse`, within about two seconds each. They did not recur; that error now names which browse failure occurred.

Two longer checks followed with the rule in place. A 60-second CLI HEVC capture of a still screen finished in 63 seconds with 1070 source frames, 58 receiver reports sent, 60 sender reports observed and every cleanup acknowledged. The opt-in real-MCP interaction check then recorded 20 seconds (365 source frames, 19/20 report counters) while the same server read the accessibility tree and pressed Home; frames taken from that movie near its start and end show Settings and then the Home screen, and a media status read afterwards reported no session. Within one process the device lease is shared, so input during the server's own recording was accepted. Motion quality and frame pacing were not assessed. One of two probe runs first failed with `mediastreamgetsupportinfo failed: unknown Apple socket failure`; the retry passed. `doctor` now reports the firewall state and a recording that receives no packet names it as the likely cause. Earlier "intermittent startup" results may have had the same cause after a rebuild at a new path; that was not checked.

**Probe app not installed.** `build-run` with `--allow-provisioning-updates` resolved the destination and failed at signing: Xcode reported no account, and the existing wildcard profile does not include this phone. The failure hints named both causes. Nothing about the probe or the touch measurement runner has run on hardware.

These are single observations on one phone. The lease check used one pair of processes and one timing; the interrupt check does not show the contact was released on the device.

### Wider command run on the phone and a simulator

**2026-11-15, through `084b809`**, same iPhone 13 mini and host. Each row is one run unless it says otherwise; effects were checked by screenshot or a follow-up read.

| Command | Observed |
| --- | --- |
| `screen auto`, `screen ocr` | In Settings: accessibility method with 106 nodes; OCR returned the visible Spanish labels |
| `swipe`, `drag` | Scrolled the General list down and back; the tree's row positions changed accordingly |
| `scroll-id` | A partly off-screen row was scrolled into view: native result true, postcondition verified |
| `wait-id … --until enabled` | Met for that row |
| `press-label` | First attempt refused before sending: the row and its hidden text share the label. After the change that accepts one visible match among explicitly hidden ones, it navigated |
| `button volume-up`, `volume-down` | The volume indicator appeared after volume-up; volume-down was dispatched |
| `type`, `key backspace` | `Wifi 12` typed into Settings search and two backspaces left `Wifi `, with matching results listed |
| `paste` | The clipboard was replaced and iOS asked whether Settings may paste. After the operator allowed it, the field read `Wifi mañana 🚀 中` |
| `pinch`, two-path `multi-drag`, two-contact `multi-tap` | In Maps: zoomed out, zoomed in and zoomed out respectively |
| `gesture` (timed double tap) | Zoomed Maps in |
| Three-contact `multi-tap` | Opened the place card under the middle contact, as a single tap would. Not evidence of three contacts |
| `processes`, `terminate` | Maps was terminated by PID and left the process list |
| `open-url` | An https URL opened in the default browser |
| `reports`, `report` | 30 reports listed; one `.ips` (about 290 kB) downloaded and began with its JSON header |
| MCP readiness and Home button checks | Passed |
| MCP foreground check (`get_ui_tree`, `get_screen`) | Failed on the Home screen: its PNG is about 8.9 MB and was left out of the result. Passed after oversized images are sent downscaled |

Two observations about system prompts. The paste prompt is not reachable through accessibility: `press-label` on its button failed before sending with `semantic refusal or notification in request response (error 8)` at process selection, while a coordinate tap worked. And a `wait-label` for a static detail row reported the single match as not visible, so labels of non-interactive rows are not reliable wait targets.

Operator errors during this run, recorded because they changed device state: a 6-second long press meant for a Settings page was sent on the Home screen and put it into edit mode, left with one Home press and no layout change; and a `terminate` was first sent to the PID of the process listed before Maps (`passwordbreachd`, a system daemon) because of a wrong filter on the process list.

**Simulator** (iPhone 17e, iOS 27.2, shut down beforehand and afterwards): `boot`, `apps`, `build-run` of the probe app, `screenshot`, `screen ocr` (read the probe's on-screen counters), `screen auto` (fell back to OCR with the "hierarchy is not available yet" diagnostic), a 3-second `record`, `terminate`, `launch`, `open-url`, `uninstall` and `shutdown` all exited 0 with the expected effect where one was checked. `tap` and `tree` were refused with the unsupported-operation error; that was before [simulator input and accessibility](#simulator-input-and-accessibility) existed. The page opened by `open-url` was not checked beyond the foreground change.

### Touch delivery measured with the probe app

**2026-11-15/16**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52). The probe app was signed and installed after the owner registered the phone with the team; `build-run` with `--allow-provisioning-updates` then built, installed and launched it in about 12 seconds.

**Probe readback by hand.** With an explicit PID, `tree` returned the probe's nine nodes, the readouts as JSON values, and attribute 3003 equal to the probe's bundle identifier. A `tap` at (0.5, 0.45) was recorded at (0.50044, 0.44992) with a 0.081 s hold. `press-id probe.touch.reset` started a new session with no touch recorded, so the press activates through accessibility rather than a synthesized tap. `pull` of `Documents/touch-log.jsonl` wrote a single file.

**`tree` without a PID failed on the probe** with `semantic refusal or notification in request response (error 8)`: the display centre of the probe has no accessibility element, and the centre hit test was refused. Process selection now asks with client type 2, which answers with the enclosing container; `tree` then selected the probe's process, and `tree`, `press-label`, waits and `scroll-id` were re-run in Settings with the same results as before. The earlier refusal while a paste prompt was showing may have had the same cause; that was not re-checked.

**Measurement runner, built-in plan** (14 actions: taps, long press, swipe, drag, two-to-five-contact gestures, two timed sequences; evidence from the pulled log, foreground identity matched on every readback):

| Run | Delivered | Notes |
| --- | --- | --- |
| 1 round | 14/14, contacts 29/29 | Three, four and five contacts each arrived as that many simultaneous touches |
| 5 rounds | 66/70 | The four missing actions were all 80 ms taps or multi-taps; nothing was received for them |
| Tap-versus-hold plan, 10 rounds | 33/80 | Taps 8/50, 0.1 s holds 5/10, 0.2 s and 0.4 s holds 20/20. Delivered actions had exact durations, so loss was all-or-nothing |
| Same plan after the fix below, 10 rounds | 80/80 | |
| Built-in plan after the fix, 5 rounds | 70/70, contacts 145/145 | Start error median 0.0004, max 0.0005 of the screen; hold error median +3 ms, max +12 ms |

**Cause of the lost short gestures.** The input connection was cancelled as soon as the completion barrier was acknowledged. That acknowledgement does not mean the device has injected the events: a gesture shorter than about 0.2 s could be discarded whole when the connection closed first, while its receipt still said `dispatched`. The connection now stays open for 400 ms after the barrier. This is the likely explanation of the taps and the Home press that had no visible effect on 2026-11-12/14; the same function sends buttons and keys, which were not separately re-measured. The 400 ms value was a first margin. On 2026-11-16 the tap-versus-hold plan was repeated with shorter waits on a quiet Mac: 50 ms delivered 50 of 80 actions, 100 ms 76 of 76 (the run stopped on an unrelated tunnel error), and 200 ms 80 of 80. The wait is now 200 ms, and the built-in plan then delivered 70 of 70 actions and 145 of 145 contacts. Three earlier attempts at this measurement, made while the Mac's load average was above 20, each stopped early on connection setup failures and are not counted.

These are results from one phone on one iOS version, with the probe in front and nothing else running. They measure what reached a UIKit view, not behaviour in other apps, near screen edges, during animations or in landscape.

### Operation-first grammar on the phone

**2026-11-16, at `f821443`**, after the CLI moved to Swift Argument Parser with typed dispatch. iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52). Every command below was run through the real CLI in the new grammar, most with the target taken from `MANZANERO_DEVICE`.

| Family | Commands run | Observed |
| --- | --- | --- |
| State | `wake`, `readiness`, `details`, `apps`, `processes`, `media-status` | All exit 0 |
| Accessibility | `tree`, `press --id`, `wait --id`, `wait --label` for a missing label | Seven probe identifiers; press accepted; wait met; the missing label exited 124 |
| Touch | `tap`, `pinch`, three-contact `multi-tap`, `gesture`, `long-press`, `swipe` | The probe recorded six gestures, nine contacts begun and ended, at most three at once, as sent |
| Capture | `screenshot`, `screen`, `record … --backend coredevice` | Screen used the accessibility method; a 3-second recording had 59 source frames |
| Apps and files | `launch`, `files list`, `files pull`, `reports list`, `build-run` | The pulled log had 63 lines; Build & Run reinstalled and launched the probe |
| Diagnostics | `console … -- -probeLogToken N1`, `last-crash --bundle` | The token came back nine times; the earlier abort was found |
| Keys and buttons | `button home`, `key escape` | Dispatched |
| Options | `--dry-run` after the operation; explicit `--device` over the environment; both targets together; `tap 2 0.5` | Plan printed; explicit target used; "Give exactly one of --device or --simulator" with exit 64; the coordinate message with exit 64 |

The measurement runner then delivered 28 of 28 actions and 58 of 58 contacts over two rounds, and the opt-in MCP readiness, foreground and button checks passed. `paste`, `type` into a field, `uninstall`, `files push`, `reports get` and `terminate` were not repeated in the new grammar on the phone; their plans were compared with the earlier grammar's by dry run.

### Unicode entry by set-value on the phone

**2026-11-16**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), with the probe app's text field (`probe.text.field`, readout `probe.text.value`). This was the first time the settable query (request type 3, attribute 53) and the set-value request (type 8) were sent over the physical accessibility session; both answered with the shapes seen on the simulator.

| Command | Observed |
| --- | --- |
| `set-value --id probe.text.field 'mañana 🚀 中'` | `status: acknowledged`, `valueMatches: true`, 16 bytes requested and read back |
| `set-value --label 'Probe text field'` with accented Latin, typographic quotes, Japanese, a three-person family emoji and Arabic | `valueMatches: true`, 75 bytes requested and read back |
| `tree` afterwards | The app's own readout reported the same text, 75 UTF-8 bytes, 38 scalars, two edits, field focused |
| `set-value --id probe.touch.summary x` (a static text) | Refused at the settable query, `state=not-sent`; nothing sent |

The clipboard was not involved. Not covered: other apps (SwiftUI fields, secure fields, web views, search fields), text longer than 75 bytes, a field under the keyboard, and the MCP tool against the phone.

### Remaining phone checks: keys, files, waits, prompts and a live MCP session

**2026-11-16**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), with the 200 ms input drain.

| Check | Observed |
| --- | --- |
| Separate key presses | Twelve typed letters were removed by twelve separate `key backspace` calls, and two separate `key space` calls arrived (iOS turned them into ". ", its double-space shortcut) |
| Taps in Settings | Opening and closing Settings search by coordinate tap worked 30 times out of 30, checked through the tree, and the first tap after switching apps worked 6 times out of 6. One earlier tap on the search field had no effect; it did not recur and is unexplained |
| `wait … --until disabled` / `enabled` | On the greyed-out Personal Hotspot row, by identifier: `disabled` met with `enabled: false`; `enabled` timed out as `not-enabled` |
| `wait … --value` | On the Airplane Mode switch: met for its current value `0`, timed out as `value-differs` for another |
| A label wait on a row whose label includes its value | Matched only the hidden inner text and reported `not-visible`. Use the identifier for such rows |
| `files`, `push`, `pull` | In the probe app's container: listed `Documents`, pushed a small file, listed it, and pulled it back byte-identical |
| `uninstall`, then `build-run` without the provisioning flag | The app left the app list, then was reinstalled and launched using the existing profile |
| `tree` and `press-label` with a system prompt showing | With the paste-permission prompt up, `tree` returned 158 nodes selected by the container hit test, 156 of them owned by SpringBoard, including the prompt's title and both buttons. `press-label` on the decline button was accepted and a wait confirmed the prompt was gone. So the earlier refusal with error 8 was the empty-centre hit test, not a protected prompt |

**Live MCP session** (one `manzanero mcp` process over stdio, eleven requests):

| Tool call | Result |
| --- | --- |
| `wake_device` | `already-awake`, not an error |
| `press_button` home | `dispatched` |
| `screenshot`, default options, Home screen | Inline image 724×1568 JPEG, 155 kB, scale 1.554; the saved PNG is 1125×2436 and 9.1 MB. `auto` chose JPEG because the PNG at that size exceeded 1 MiB |
| `screenshot` with `image_format: jpeg`, `image_quality: 0.6` | 95 kB |
| `screenshot` with `image_max_edge: 800` | 369×800, 47 kB |
| `screenshot` asking for the saved resolution as PNG with a 16 MiB cap | The 9.1 MB PNG itself; the response was 12.2 MB |
| `get_screen` with `image_include: false` | Tree result, `inlineImage.included: false`, no image block |
| `wait_for_element` for a missing label, 2 s | `timed-out` with `isError: false` |
| `tap` with x = 2 | `isError: true` with `structuredContent.error.code: usage` |
| `screenshot` with `image_max_edge: 1` | JSON-RPC invalid-params error before any capture |

Not covered: `handoff` with a real prompt, `set_element_value` on a phone (refused at the time; enabled and run later, see [set-value on the phone](#unicode-entry-by-set-value-on-the-phone)), and anything on a second device.

### App console and last crash on the phone

**2026-11-16**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), with the probe app's log probe.

| Check | Observed |
| --- | --- |
| `console <bundle> --seconds 10 --os-log -- -probeLogToken P1` | Exit 0. stdout carried the flushed and the unflushed line, stderr the stderr line plus the mirrored log lines; `exitStatus` reported terminating signal 2, the forwarded interrupt |
| The same without `--os-log` | stdout and stderr lines only; no mirrored log lines |
| `console … -- -probeCrash abort` | First attempt failed with `devicectl failed (exited(1))` and returned nothing, because `devicectl` exits non-zero when the app it launched aborts. After the change that treats this as the app's outcome, the result carried the output, `appEndedAbnormally: true` and terminating signal 6 |
| `last-crash --bundle <bundle> --since <time>` a few seconds after the abort | `found: true`, `EXC_CRASH`, `SIGABRT`, "Abort trap: 6", with frames from `libsystem_kernel` upward; the report was downloaded under `tmp/` |

This answers the research note's first two open questions for this phone: `devicectl`'s console does bridge stderr, the mirroring setting does copy the app's log lines on a device, and the termination result is reported. Debug-level lines, a large output, and other iOS versions were not checked.

**The phone stopped answering before this run.** Every `devicectl` query timed out while the phone was still listed as connected; replugging and unlocking did not help. Stopping `CoreDeviceService` and `remotepairingd` on the Mac, which macOS restarts on demand, restored it at once. The services' state was not captured before they were stopped and the system log held no entries for them, so the cause is unknown. It followed a period of very high load on the Mac and two console launches that failed to start.

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

## Simulator input and accessibility

**2026-11-15**, one simulator: iPhone 17e (390 × 844 points at 3×), iOS 27.2 runtime (24B8117), headless (Simulator.app not running). Host macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreSimulator 1174.21, Swift 6.4.2. The simulator was booted for the run and shut down afterwards; no other simulator and no physical device was contacted. Apps: the project's probe app and Settings. Route and limits: [simulator input](simulator-input.md).

| Command | Observed |
| --- | --- |
| `doctor` | `simulator-input` (18 interfaces) and `simulator-accessibility` (22) available |
| Any command on the shut-down simulator | `tree` refused with `device-not-ready` before any connection |
| `tree` | Probe: 9 nodes, the three readouts with their JSON values and `nativeAttributes["3003"]` = the probe's bundle identifier. Settings: 133 nodes. Lock screen: 105 nodes. Home Screen: failed, the full-depth SpringBoard snapshot came back empty after about 3 s (depth 4: 0.39 s, depth 10: 2.0 s in a separate experiment) |
| `press-id probe.touch.reset` | Accepted; the probe session changed and no touch was recorded |
| `press-label Appearance`, later `press-label General` | Settings navigated (screenshot, and a wait for the next page's row) |
| `scroll-id com.apple.settings.standBy` | Native true, postcondition verified; the row moved from y 799 to y 377 (screenshot) |
| `wait-id probe.touch.summary` | `condition-met` in one poll, 0.10 s |
| `wait-id` for a missing identifier, `--timeout 2` | Exit 124, `timed-out` after 5 polls, 2.04 s |
| `wait-label "Reset probe" --until enabled --timeout 0` | Met |
| `wait-label General` started 1.5 s before `simctl launch` of Settings | Met after 8.5 s and 13 polls, following the process change (two PIDs observed) |
| `wait-label Dark` in Settings' Appearance | Timed out `not-visible`: the SwiftUI static text reports visibility false while its row reports true |
| `tap`, `long-press`, `swipe`, `drag` on the probe | Delivered at the requested positions; see the runner results below. Tap at (0.5, 0.45): received (0.5, 0.44984), held 0.074 s. 0.8 s long press held 0.800 s. 0.8 s drag: 30 moves, 0.802 s |
| `tap` on a Home Screen icon | Opened the probe |
| `button home` | Returned to the Home Screen (screenshot) |
| `button lock` | Display black; the frontmost process became SpringBoard's lock screen |
| `button home` on the dark display, then `swipe 0.5 0.99 0.5 0.4 0.3` | Lock screen shown, then unlocked back to the probe |
| `tap` on Settings search, `type 'Wi-Fi 5'` | The field read `Wi-Fi 5` |
| `key backspace` twice, `key return` | The field read `Wi-Fi`; return submitted the search ("No Results") |
| SIGINT / SIGTERM during a 5 s `long-press` | Exit 130 / 143; the probe recorded the contact `ended` after 0.95 s / 1.0 s, none left down |
| `tap` while another process held a 3 s `long-press` | Refused immediately with `device-busy` naming the holder; a concurrent `wait-id` (no lease) was met |
| `--platform simulator` runner, built-in plan | 6 single-contact actions delivered; multi-contact ones refused, measured `missing`, run stopped after 3 consecutive dispatch failures (expected) |
| Runner, 8 single-contact actions × 5 | 40/40 delivered; start error median 0.0001, max 0.0005; hold error median +0.6 ms, max +5.4 ms ([details](probe-touch-runner.md#simulator-runs)) |
| `mise run test:mcp-live` (real stdio MCP session) | Passed: `get_ui_tree`, `press_element` reset, `tap`, `wait_for_element` reading one new gesture, `screenshot`, `record_screen`, synthetic `request_handoff`, `get_screen` (accessibility method). Run twice, once in each foreground-selection state below |

Findings beyond the research:

- The project's own request archives unarchive with secure coding into the framework's `AXPTranslatorRequest`, and the archived responses decode with the physical decoder unchanged ([research open question 3](simulator-input-research.md#open-questions-and-the-experiment-that-settles-each)).
- Client type 2 is what makes a hit test over an empty area work: with type 0 it failed with error 8, with type 2 it returned the container; at an element centre both returned the element.
- **Frontmost selection is not always available.** After the first boot the frontmost request answered within seconds. After a second fresh boot it answered with no application for at least 15 minutes, whatever was in front (Home Screen, probe, Settings), also through Apple's own `AXPTranslator` layer, while centre hits and explicit-PID trees worked. The session therefore falls back to a centre hit with client type 2 and reports which was used (`foregroundSelection`). The single-contact runner pass and the MCP check were repeated in that state and passed.
- Twelve taps and swipes sent with no drain before disconnect all arrived; the 380 ms drain is kept from IDB's measurement on another model, not from evidence here.
- The first request after boot was slow (about 3 s for the first tree) only on the first boot.

Not observed: rotation or landscape, iPad or other families, other runtimes or Xcode versions, two contacts or more, Unicode entry, volume buttons, and a simulator under Xcode's own UI tests or with Simulator.app open.

**Second run and physical re-check, 2026-11-15 at `7b1bfbd`.** A separate run on the same simulator repeated the refusal when shut down, `tree` (9 probe nodes), `press-id probe.touch.reset`, a `tap` sent at (0.3, 0.6) and recorded by the probe at (0.3, 0.59992), a 0.4-second `swipe` recorded with exact endpoints and 16 moves, both waits (met, and exit 124), `screen auto` on Settings (accessibility, 141 nodes) and `button home`. The probe's recent-gestures readout was read through the tree here for the first time, about 500 bytes for two gestures.

Because the accessibility code shared with the phone was refactored, the iPhone 13 mini was re-checked with the same build: `tree` (137 nodes, both cleanups acknowledged), `press-label`, `wait-id` met and timed out with exit 124, `scroll-id` with its postcondition verified (a row moved from y 793 to 416), `screen auto`, `swipe`, a 2-second native recording (39 frames) and `button home` all behaved as before. A `scroll-id` for a row that the lazy Settings list had not yet created was refused before sending with "no match", which is the documented limit, not a change.

### Two contacts on the simulator

**2026-11-16**, same iPhone 17e simulator, iOS 27.2 runtime (24B8117), Xcode 27.2 (27B52), macOS 27.2.1, headless; the probe app in front. `pinch 0.5 0.5 0.2 0.5 0.6` was recorded as two simultaneous contacts (`maxActive` 2) from (0.4, 0.5) and (0.6, 0.5) to (0.2504, 0.5) and (0.7504, 0.5). The measurement runner with `--platform simulator` and a four-action plan (a 0.6 s spread and a 0.4 s inward pinch, two parallel upward paths over 0.5 s, two paths moving apart over 0.8 s), five rounds: 20 of 20 actions and 40 of 40 contacts `delivered`, all through the recent-gestures readout; `maxActive` 2 in every action; start error median 0.0003, max 0.0005; end error median 0.0004, max 0.0082; hold error median +0.5 ms, max +9.2 ms; foreground identity matched on all 21 readbacks.

### Three to five contacts on the simulator

**2026-11-16**, same simulator and versions. The simulator's `universalhidservice` answered the phone's Universal HID requests; it lists two touchscreens, one per display, and only the primary display's delivered (details in [research open question 1](simulator-input-research.md#open-questions-and-the-experiment-that-settles-each)). `multi-tap 0.3 0.45 0.5 0.45 0.7 0.45` reached the probe as three simultaneous contacts at (0.3, 0.44984), (0.5, 0.44984) and (0.7, 0.44984), held 0.082 s, through service 257. The built-in measurement plan over five rounds: 70 of 70 actions and 145 of 145 contacts delivered, every scheduled contact count (one to five) reached; start error at most 0.0005; absolute hold error median 0.7 to 3.0 ms per contact count, max 20.5 ms ([table](probe-touch-runner.md#simulator-runs)). The display information request (`getdisplayinfo`) needs the device identifier and the host CoreDevice version (651.32 here); without either it answered with a `CoreDevice.ActionError` naming the missing key.

### Rotation and iPad on the simulator

**2026-11-16**, iPhone 17e (390 × 844 points at 3×) and iPad mini (A17 Pro) (744 × 1133 points at 2×), both on the iOS 27.2 runtime (24B8117), headless; same host and Xcode. The probe app was rebuilt for iPhone and iPad (full screen) and launched with `-ProbeAllowRotation YES`; the device orientation was changed through the simulator's `devicecontrol.orientation` service (`changeOrientation`). Route and mapping: [simulator input](simulator-input.md#how-it-works).

Findings, each from direct readback of the probe:

- `getdisplayinfo` reported `nativeOrientation: rot0` on both models and `currentOrientation` `rot270` (landscape left), `rot90` (landscape right), `rot180` (iPad upside down). With the iPhone turned upside down, the interface stayed `rot90`.
- Before mapping, a raw digitizer tap at (0.2, 0.3) in landscape left landed at (0.30016, 0.8) of the 844 × 390 interface and (0.7, 0.6) at (0.59992, 0.3): the digitizer is portrait-native. After mapping, `tap 0.2 0.3` landed at (0.19984, 0.3) in landscape left and right on the iPhone and at (0.2, 0.3) ± 0.0003 in all four orientations on the iPad; multi-tap, pinch and swipe likewise.
- The tree's frames were interface points in landscape. `press-id probe.touch.reset` failed at the centre-hit guard with error 8 until hit points were mapped to native points; afterwards it was accepted in every orientation on both models. `set-value-id probe.text.field` matched in landscape on both models (after the probe's field moved to the top of the screen in landscape; lower down it reported itself not visible).

Measurement runner, built-in plan, five rounds each (70 actions, 145 contacts per run), all through the recent-gestures readout with identity matched on every readback:

| Simulator | Orientation | Delivered | Contacts | Start error median / max per contact count 1, 2, 3, 4, 5 | Absolute hold error max per contact count (ms) |
| --- | --- | --- | --- | --- | --- |
| iPhone 17e | portrait | 70/70 | 145/145 | 0.0002/0.0002, 0.0004/0.0005, 0.0001/0.0002, 0.0001/0.0001, 0.0004/0.0004 | 20.5, 19.3, 4.0, 4.1, 4.8 |
| iPhone 17e | landscape left | 70/70 | 145/145 | 0.0004/0.0005, 0.0001/0.0004, 0.0002/0.0004, 0.0002/0.0002, 0.0001/0.0004 | 4.2, 13.3, 3.6, 4.2, 4.7 |
| iPhone 17e | landscape right | 70/70 | 145/145 | 0.0004/0.0005, 0.0001/0.0004, 0.0002/0.0004, 0.0002/0.0002, 0.0001/0.0004 | 14.9, 3.2, 2.0, 1.9, 2.4 |
| iPad mini | portrait | 70/70 | 145/145 | 0.0001/0.0003, 0.0001/0.0002, 0.0003/0.0003, 0.0003/0.0003, 0.0002/0.0002 | 12.3, 12.3, 7.8, 1.9, 2.2 |
| iPad mini | landscape left | 70/70 | 145/145 | 0.0003/0.0003, 0.0002/0.0003, 0.0002/0.0003, 0.0002/0.0002, 0.0001/0.0003 | 3.7, 4.1, 2.3, 1.9, 2.6 |

Every scheduled contact count was reached in every action. Median absolute hold errors were 0.7 to 3.0 ms. Not run: the runner in upside-down and landscape-right on the iPad (single taps, multi-taps, swipes and presses were checked there by hand), other iPad models, Split View or windowed iPad apps (the probe requires full screen), and orientation changes during an action (the two display reads would refuse a change between them, not one during sending).

### Volume buttons and the Home Screen tree on the simulator

**2026-11-16**, iPhone 17e, same versions. Volume: one press of usage 233 (the phone's volume-up) on the button service showed the system volume HUD with its level raised; usage 234 lowered it to empty. `button volume-up` through Manzanero returned `dispatched`. Both are now accepted on simulators.

Home Screen (second page, SpringBoard in front): with raw snapshot requests, depth 6 answered in 0.53 to 0.63 s, 8 in 0.87 to 0.99 s, 9 in 1.25 s, 10 in 1.8 to 2.5 s (with the page's icons and the dock; depth 8 and 9 lacked the dock), 12 came back empty after 3.0 s. Directly after an empty full-depth answer, every snapshot of SpringBoard, at any depth, came back empty within a millisecond, three rounds out of three; about three seconds later depth 10 answered again. With the shallow retry, `tree` on the Home Screen returned 123 nodes (22 records cut at the limit) in 12.5 s and 11.6 s, of which 8.1 s and 7.8 s were waiting. `wait-label Probe` was met in one poll (11.9 s in all). `press-label Probe` was refused at the exact centre-hit guard with "target centre hit is another native element"; `wait-label Settings` timed out because that icon was on the other page (visible false).

### Unicode entry by set-value on the simulator

**2026-11-16**, same simulator and versions, with the probe's new text field (`probe.text.field`, readout `probe.text.value`). `set-value-id probe.text.field 'mañana 🚀 中 héllo'` returned `acknowledged` with `valueMatches: true`, and the readout showed exactly that text (23 UTF-8 bytes, 16 scalars). Then ten values in a row (one ASCII letter, accented Latin, emoji, CJK, Greek, Hebrew, Devanagari, a skin-tone ZWJ emoji sequence, and 301 characters) each matched in the receipt and in the readout's byte count; three more by label (`set-value-label "Probe text field" …`, including Japanese and a family emoji) also matched. `type ' ok 5'` and `key backspace` afterwards appended at the caret of the focused field, so HID typing and set-value combine as documented.

Refusals: a `set-value-id` on the summary readout (a static text) was refused at the settable query with nothing sent. With the first probe build the set-value focused the field and the on-screen keyboard covered it; the next set-value was refused by the visibility guard (`stage=live-attributes`). The probe field now has no on-screen keyboard. Physical `set-value-*` is refused before any device query.

Paste: `printf … | simctl pbcopy <UUID>` exited 0 three times, and `simctl pbpaste` each time returned 13 characters of other text, not the copied text (the content was not recorded). `simctl pbinfo` listed one item with promised `public.utf8-plain-text`, `public.html`, RTF types and `com.apple.coredevice.dtpasteboardd.sync`. Simulator `paste` stays refused.

Also observed: after the probe's XCUITest suite ran on this simulator (6 of 6 tests passed, including a new text-field test), every snapshot of the probe came back empty within 1 ms, also after relaunching the probe; frontmost and application requests answered. A reboot cleared it. In about the first minute after the reboot, four snapshots came back empty; then 20 of 20 trees in a row succeeded.

### Keyboard layouts on the phone

**2026-11-16, at `17a6560`**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), the probe app's text field. No hardware keyboard has been attached to this phone and its hardware-keyboard setting was not changed or looked at; its interface language is Spanish. Before each run the field was emptied with `set-value … x` and `key backspace`; the result is the probe's own readout.

| Command | Requested | Read back |
| --- | --- | --- |
| `type` (default `us`) | `Ab9!z;[ ~"<>? mañana café über ß €` | ``Ab9!zñ`>¨;:_ ma nana caf€e. uber ∫ ˝``: wrong from the first punctuation on |
| `type --layout spanish-iso` | `Año Ñandú ¿Qué? ¡Sí! €5 ç <º> @# à ü` | The same text exactly (dead acute, grave and diaeresis; Shift; Option) |
| `type --layout spanish-iso` | `Ab9!z;[ ~"<>? mañana café über` | The same text exactly |
| `type --layout latin-american` | `<>≤ \|°¬` | `<>≤ ºª\`: the phone is not on that layout, as expected |

What this shows:

- **This phone applies the Spanish – ISO layout to key events**, although nobody chose it; it probably follows the phone's language. The default `us` is therefore wrong on it for most punctuation. Letters, digits and `!` are the same in both layouts, which is why the earlier US-only checks in Settings search looked right.
- Shift, Option and dead keys work on a phone, and the key left of Z (`<`, `>`, `≤`) arrived, so the phone uses the ISO keyboard type like the simulator.
- A wrong layout name types wrong text with exit 0, as documented; the receipt says `deviceLayout: not-read`.

Not covered: changing the phone's layout in Settings (and whether that section exists without a keyboard attached), any layout other than Spanish – ISO, other phones, and MCP `type_text` with a layout against the phone.

### Keyboard layouts on the simulator

**2026-11-16**, the build committed as `a525c03`; the German row and the first Latin American row ran on the same code before its keyboard type changed from ANSI to ISO (German's table is the same in both), one iPhone 17e simulator, iOS 27.2 runtime (24B8117), headless (no Simulator or DeviceHub window opened). Host macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2; host input source Spanish – ISO. The simulator was booted for the run with `manzanero boot` and shut down afterwards; no other simulator was touched. No physical device was contacted. Research and design: [keyboard layouts](keyboard-layouts.md).

Method: the simulator's hardware layout was set by writing an input mode with an explicit `hw=` into `AppleKeyboards` (global domain) and into `KeyboardLastUsed` and `KeyboardsCurrentAndNext` of `com.apple.keyboard.preferences` with `xcrun simctl spawn <UUID> defaults write`, then the probe app was relaunched. The probe's field was focused with `set-value-id probe.text.field x` and emptied with `key backspace`; the text was sent with `type --layout <name> --simulator <UUID> -- '<text>'`, and the readout `probe.text.value` was read from `tree`. "Exact" means the readout's `text` equalled the requested string code point for code point.

| Simulator input mode | Command | Readout | Receipt `deviceLayout` |
| --- | --- | --- | --- |
| `es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO` | `type --layout spanish-iso 'Año Ñandú ¿Qué? ¡Sí! €5 ç <º> @# à ü'` (106 events) | Exact: dead acute and grave (`ú é í à`), dead diaeresis (`ü`), Shift (`Ñ ¿ Q`), Option (`€ @ #`), `<` on HID 53 and `º` on HID 100 | `matches` |
| same | `type --layout spanish-iso 'ok → no'` | Unchanged; refused with exit 64: "cannot type '→' (U+2192), character 4 …", pointing to set-value | — |
| `de_DE@sw=QWERTZ-German;hw=German` | `type 'hello'` (no layout, so `us`) | Unchanged; refused with exit 64: "uses the german hardware keyboard layout, not us. Pass --layout german …" | — |
| same | `type --layout german 'Grüße, Straße! @ € ê ÄÖÜ y<z> {[\|]} ~'` | Exact: `ß` and umlauts on their own keys, `y`/`z` swapped back, Option `@ € { [ \| ] } ~`, dead circumflex `ê` | `matches` |
| `es_419@sw=QWERTY-Spanish;hw=Latin American` | first build (ANSI keyboard type): `type --layout latin-american '\|°¬ ñÑ ¿? á'` | `<>≤ ñÑ ¿? á`: HID 53 typed the ISO table's `<`, `>`, `≤` instead of the ANSI `\|`, `°`, `¬` | `matches` |
| same | after switching the tables to the ISO type: `type --layout latin-american '<>≤ \|°¬ ñÑ ¿? á'` | Exact | `matches` |
| `fr_FR@sw=AZERTY-French;hw=French` | `type --layout french 'Ça va? àéèùç ê ë 1234 @#€ AZERTY qw'` | Exact: AZERTY letters, Shift digits, dead circumflex and diaeresis, Option `€` | `matches` |
| `en_US@sw=QWERTY;hw=Automatic` (the simulator's default) | ``type 'Ab9!z;[ ~`"<>?'``, then `type ' mañana café über ß €'` | Exact: US ASCII, Option dead keys (`ñ é ü`), Option `ß` and Shift+Option `€` | `not-checked` (`hw=Automatic`) |
| `de_DE@sw=QWERTZ-German;hw=Automatic` | MCP `type_text` over a real stdio session, `platform: simulator`, `layout: german`, `Grüße @ ê` | Exact; `isError: false` | `not-checked` (`hw=Automatic`) |

Other observations, from the research on the same simulator (details in [keyboard layouts](keyboard-layouts.md#where-the-layout-comes-from)):

- With `hw=Automatic`, `de_DE` typed German and `es_ES` Spanish – ISO, but the multilingual `es_419@…;hw=Automatic;ml=120` typed US.
- A layout change reached the probe only after it was relaunched; a running probe kept the previous layout.
- An explicit `hw=German` in an `es_ES` mode typed German: the explicit value wins over the language.
- The host's Spanish – ISO input source did not change what the simulator typed.

Not verified: any physical device (only US ASCII has ever been typed on a phone); layouts other than the five above; Shift+Option dead keys outside US; input-method layouts (Japanese, Chinese, Korean); Caps Lock on; texts near the 2048-event limit; other runtimes and Xcodes. The simulator's keyboard preferences were restored to their earlier values (`en_US@sw=QWERTY;hw=Automatic`, no `AppleKeyboards`) after the run.

## App logs, console and crashes

First run of [`logs`, `console` and `last-crash`](app-logs.md), 2026-11-16: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), devicectl 651.32, one iPhone Air simulator on iOS 27.2 (24B8117), booted for the run and shut down afterwards, with the probe app's [log probe](probe-app.md#log-probe) installed through `simulator <UUID> build-run`. Every command went through the real CLI. Captured output stayed under `tmp/`; only shapes and counts are recorded here. No physical device was contacted.

| Check | Result |
| --- | --- |
| `logs --seconds 10 --bundle <probe> --level debug`, with `press-id probe.log.emit` three seconds in | Exit 0, `stopReason: duration`, 6 entries kept, 1 filtered out (not a log event), `toolReportedCount` 7. Debug, info, default, error and fault tokens each arrived once with the probe's subsystem and category `probe`; the private-interpolated value arrived in clear text. Every entry came from `ProbeApp` |
| Same, earlier, when the emit did not land | 9 entries, all from `ProbeApp` (UIKit, RunningBoard and other frameworks logging inside the app's process) |
| `logs --last 120 --bundle <probe> --level debug` | `stopReason: complete`, 422 entries kept of 439 reported. The emitted set was there at info, default (twice, with the private line), error and fault; **no debug**, as the research predicted |
| `logs --start <5 min ago> --bundle … --subsystem … --category probe` | 8 entries, levels default, error and fault only (no `--level`). The first attempt failed with exit 64: `log show --start` parses with `%z` (`+0000`), not the `+00:00` the man page shows; fixed |
| Bounds on SpringBoard at debug: `--max-entries 3`, then `--max-bytes 1024` | `entryLimit` after 2.2 s and `byteLimit` after 1.2 s of a 30-second request, both `truncated: true`; 3 entries (1,013 bytes) kept in the byte case |
| Q7: `logs --seconds 10 --bundle <probe>` across two `simctl launch --terminate-running-process` relaunches | Entries from both new processes (2 PIDs, both tokens) |
| `console <probe> --seconds 5 --os-log -- -probeLogToken C1` | `stopReason: duration`, app still running. stdout had the flushed token only (21 bytes); stderr had the stderr token and the DT-mode lines for info, default, error, fault and the private line, in the form `[probe] probe.log …` |
| `console … --seconds 3 --terminate -- -probeLogToken C2` | `terminatedByTool: true`, `stillRunning: false`; still only the flushed stdout token, and no `os_log` lines on stderr without `--os-log` |
| `console … --seconds 6 -- -probeLogToken K1 -probeCrash abort` | `stopReason: exited` when the app aborted; stdout had both stdout tokens and the `about to crash` line (the crash path flushes stdout) |
| `last-crash --bundle <probe> --since <before launch>` | Called at once: `found: false` (the report was written about two seconds later). Again a few seconds later: `found: true`, `EXC_CRASH`/`SIGABRT`, `Abort trap: 6`, `deviceMatch: procPath`, top frames `__pthread_kill`, `pthread_kill`, `abort`, then the probe's closure in `LogProbeEmitter.launched`, symbolised in the Debug build |
| `-probeCrash trap`, then `last-crash --process ProbeApp --since …` | `EXC_BREAKPOINT`/`SIGTRAP`, `Trace/BPT trap: 5`, top frame `_assertionFailure` then the probe's closure; `crashMessages` empty (no application-specific information in the report) |
| Physical dry runs | `console` planned `devicectl device process launch --device <UDID> --console --terminate-existing --timeout 70 --json-output <tmp>/launch.json <bundle> <app args>` with `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable`; `last-crash` planned the `systemCrashLogs` listing and `copy from`; physical `logs` failed as `unsupported-operation`, `inputSent: none` |

**Open questions settled** (research section 6):

- **Q3.** Unflushed `print` output was lost with `simctl launch --stdout=<file>` both while the app ran and after `simctl terminate`, and with `--console` (simctl's stdout redirected to a file) after SIGTERM to simctl. With `--console-pty` the unflushed line arrived at once. `console` keeps file mode and documents the loss.
- **Q7.** `processImagePath BEGINSWITH "<installed .app>/"` matched a user app's entries in the simulator (entries carry host paths) and kept matching across two relaunches. Extensions were not tested; the probe has none.
- **Q8.** With `OS_ACTIVITY_DT_MODE=enable` alone, info, default, error and fault lines were mirrored to stderr and debug was not. Adding `OS_ACTIVITY_MODE=debug` (set directly through `simctl launch`) mirrored debug too, once each.
- **Q9.** Yes for a user app: the simulator crash report's `procPath` is the host path under `CoreSimulator/Devices/<simulator UUID>/data/Containers/Bundle/Application/…`, so `last-crash` excludes other simulators' reports.

**Process hygiene.** After a normal end, after an entry or byte limit, after SIGINT (exit 130) and after SIGTERM (exit 143) to `manzanero logs`, no `simctl spawn` process and no in-simulator `log stream` process was left (during the capture both were visible, the latter as a child of the simulator's launchd). An unrelated host `log stream` belonging to other work was present before and after and was not touched.

**Probe trigger.** A `manzanero-probe://` URL opened with `open-url` showed "Open in “Probe”?" and needed a touch, so the trigger became the accessibility element `probe.log.emit`, which `press-id` activated (`status: accepted`).

Not established: anything on a physical device (physical `console` and `last-crash` have only unit tests and dry runs), `log show` over long windows, extensions, other runtimes or Xcode versions, and MCP calls against a live simulator (the tools' routing and schemas are unit-tested).

## Apps, files, reports and development

Physical Settings launch and app inventory succeeded. The launch option-order fix (`4c47998`) ensures devicectl options precede the bundle operand. One Safari URL preflight failed; broad physical URL/lifecycle claims are not made.

App-data command plans and an Apple-tool-owned temporary-domain synthetic copy round trip were checked. This is not actual app-container access/round-trip evidence. Physical saved-report listing passed. Download is implemented but hardware-unverified. Filtering and parsing now exist as [`last-crash`](#app-logs-console-and-crashes), verified on a simulator only; symbolication and deletion are missing. See [feature status](feature-status.md).

The [probe app](probe-app.md) fixture and its touch probe passed its core unit tests, a warning-free simulator build, a simulator launch, XCUITest recording checks and a simulator `build-run` (2026-11-15, iPhone 17e simulator, iOS 27.2). It has not been run on hardware, so it has produced no delivery evidence yet. Its [touch measurement runner](probe-touch-runner.md) passed offline tests against canned tree output, receipts and logs, and its dry run's commands were accepted by `manzanero --dry-run`; it has not been run against a device.

Simulator screenshot and finite H.264/HEVC movie checks passed. Build & Run passed simulator project/Debug and workspace/Release flows with product validation/install/launch; complete physical signing/deployment remains unverified.

Human handoff has synthetic terminal/form completion and per-device mutation-pause coverage. No actual biometric/passcode/purchase action, automatic prompt detection or native notification is claimed.

## Other simulator families

Three simulators created for this work, headless (Simulator.app not opened): `manzanero-research-tv` (Apple TV 4K (4th generation) at 1080p, tvOS 27.2, 24K150), `manzanero-research-watch` (Apple Watch Series 12 (46mm), watchOS 27.2, 24S118) and `manzanero-research-duo` (iPhone Duo, iOS 27.2, 24B91016s). Host macOS 27.2.1 (26B131), Xcode 27.2 (27B52). No physical device was contacted. Background and the first pass are in [the research](other-families-research.md); the commands are described in [other simulator families](other-families.md).

### iPhone Duo displays

**2026-11-16**, `manzanero-research-duo` freshly booted, Home Screen and then Settings in front.

| Command | Observed |
| --- | --- |
| `displays` | Five displays: `LCD` id 1 primary, 1398 × 2034 px (466 × 678 pt), `activeOn`, active; `LCD-1` id 3, 2007 × 2853 px (669 × 951 pt), `rot90`, backlight `off`, not active (the research saw `activeOn` after its first boot); `TVOut`, `Wireless` and `Resizable` 0 × 0, not capturable. `defaultCaptureDisplay` 1 |
| `screenshot` (no option) | Exit 0; 1398 × 2034 PNG of the outer Home Screen (before: `Cannot choose between 2 displays`) |
| `screenshot --display LCD-1` | Exit 0; 2007 × 2853 PNG, black (the device is folded) |
| `screenshot --display LCD-9`, `--display TVOut` | Exit 1 before capture: unknown display, and no framebuffer, each listing `LCD (id 1, primary), LCD-1 (id 3)` |
| `screen` with Settings in front | `method: accessibility`, 122 nodes, display LCD in the receipt. A run directly after `launch`, with the Home Screen still in front, fell back to OCR because the Duo's Home Screen tree is empty (known from the research) |
| `screen ocr --display LCD-1` | `method: ocr`, 2007 × 2853 image, display `LCD-1`, `primary: false` |
| `screen tree --display 3` | Refused before capture: the tree describes the primary display only |
| `record 2` (no option), `record 2 --display primary-1` | 2.02 s H.264 at 1398 × 2034 (display LCD), and 2.02 s at 2006 × 2852 (display LCD-1) |

On `manzanero-research-tv` the first version refused `screenshot` (`no single capturable primary display`): its only display, `TVOut`, reports `nativeSize` 0 × 0 and backlight `off` while its current mode is 1920 × 1080. Capturability now follows the current mode's size; `displays` lists TVOut as capturable and primary, and `screenshot` ran with the unchanged `simctl` arguments (simctl: `Defaulting to display … TVOut`).

Not observed: an unfolded Duo (no fold control exists yet), so nothing showed on `LCD-1`, and trees and touch were not tried on it.

### Press refused on the Duo and the Apple TV: the hit-test client type

**2026-11-16**, `manzanero-research-duo` (Settings) and `manzanero-research-tv` (Settings). Reproduced: `press --label General` on the Duo was refused at `stage=target-hit` with `target centre hit is another native element`. With temporary diagnostics, the fresh snapshot had two `General` nodes: the row (visible, 362 × 52 pt) and its static text child (visibility false), so the selector had already chosen the row as the only visible match. The hit test at the row's centre, sent with client type 2 as the simulator bridge then did for every hit, answered with an unrelated zero-size, invisible container near the top of the tree, not the row or its text. Sent with client type 0 (what the physical route sends for element hits) it answered with the row, and the press was accepted and Settings opened General (a wait for `About` was met). After the change (element hits type 0, the process-selection centre hit still type 2):

| Simulator | Command | Observed |
| --- | --- | --- |
| Duo | `press --label General`, then `press --label About` | Both accepted; the tree then showed the About page |
| Duo | `scroll --label "44,15 GB"` on About | Native true, the text moved from y 628 to 590; postcondition `failed` on visibility (the SwiftUI static text reports not visible, as noted in [simulator input](simulator-input.md#observed-limits)) |
| TV | `press --label "Video and Audio"` | Accepted; the tree then showed the Video and Audio page (`VIDEO`, `AUDIO`, `CALIBRATION`) |

The selector, duplicate-match rule and press guards in `DirectAccessibilityAction` are unchanged and physical requests are unchanged. Not re-checked: the iPhone 17e simulator (in use elsewhere), where type 2 had worked; the Home Screen icon press refused there by the same guard may have the same cause.

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

`8681d00` added local universal beta archives, checksum/formula generation and the tag/manual workflow. Both architectures built, native version/help ran, signatures/linkage and Homebrew-style extraction/symlink smoke passed. The optimized archive was about 4.1 MiB and needed no supplemental Swift compatibility library. The project now uses MIT, and its public source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero). GitHub Actions, actual beta release and public Homebrew install have not run.

The earlier source/history privacy review used Gitleaks 8.30.1 against the pre-cleanup snapshot and its 88 reachable commits and found no detected leaks. Those scan results apply to the original history, not the rewritten trees. The later publication cleanup preserved author identities, removed personal paths and private investigation material, and verified those specific removals throughout reachable history. No additional secrets scan was requested. See [public readiness](public-readiness.md).

## What these records do not establish

No result here completes all Apple-family coverage or reliable unattended testing. Important gaps include cross-process ownership, uncertain-release quarantine, crash/cable-loss recovery, broad app/overlay/orientation behavior, simulator input migration and dedicated iPad/Watch/TV/Duo validation.

When repeating a check, record the current versions/target/backend, separate transport acceptance from visible effect and cleanup, and retain failures rather than automatically retrying an input action.
