# Verification record

This is the evidence summary for the current implementation and the material failures that shaped it. It is organized by capability so readers do not have to reconstruct the latest state from an append-only development log.

**Commands recorded before 2026-11-16 use the earlier grammar**, with the platform and device first (`physical <UDID> tap 0.5 0.5`, `simulator <UUID> press-id <id>`). From that date the CLI names the operation first and the target as an option (`tap 0.5 0.5 --device <UDID>`, `press --id <id> --simulator <UUID>`); see the [argument parser proposal](cli-argument-parser-proposal.md). The records below are kept as they were run.

**A build, fixture or dispatch receipt is not a hardware assertion.** Each result below applies to its stated backend/device/environment. Retired helper results are labeled separately. [Feature status](feature-status.md) describes current availability, the [roadmap](roadmap.md) summarises what is achieved and pending, the [live check plan](live-check-plan.md) lists the hardware runs still owed, and [development tasks](development-tasks.md) explains repeatable checks.

**Entries are not rewritten.** A few undated summary paragraphs were written before later dated sections; where they differ, the dated section is the later record, and a "Later:" note points to it.

Where to find the physical results: [discovery and readiness](#discovery-and-readiness) through [app console and last crash](#app-console-and-last-crash-on-the-phone) and the runs of 2026-11-17 and 2026-11-18, the newest on the phone: [the log relay](#the-log-relay-on-the-phone), the [morning session](#phone-session-of-2026-11-17), [web content](#web-content-on-the-phone), [a passcode, pairing and the lock screen](#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen), and human handoff [with a physical step](#handoff-with-a-physical-step), [with a permission prompt](#handoff-with-an-app-permission-prompt), [through an MCP host](#handoff-through-an-mcp-host-the-pause-and-the-form) [watching the device](#handoff-that-watches-the-device), its [timeout and simulator runs](#handoff-watch-a-timeout-on-the-phone-and-runs-on-a-simulator) and [the last runs with the owner](#the-last-handoff-runs-on-the-phone), the [selector, layout and screenshot changes](#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note) and [the offer that asked for RTCP feedback](#an-offer-that-asks-for-rtcp-feedback); then [direct physical input](#direct-physical-input), [physical accessibility](#physical-accessibility-and-screen-understanding), [native media](#native-media-and-recording) and [frames](#frames-on-the-phone). Other devices, inside the project's probes: [the first iPad](#first-run-on-a-physical-ipad-the-ipad-mini-6th-generation), [the first Apple Watch](#first-run-on-a-physical-apple-watch) and [its remaining commands](#the-physical-apple-watchs-remaining-commands), and [the first iPhone Duo](#first-run-on-a-physical-iphone-duo). Simulator results: [simulator input](#simulator-input-and-accessibility), [keyboard layouts](#keyboard-layouts-on-the-simulator), [layout detection](#layout-detection), [app logs](#app-logs-console-and-crashes) and [other simulator families](#other-simulator-families). MCP ordering: [calls sent without waiting](#mcp-calls-sent-without-waiting). Distribution: the [release rehearsal](#release-rehearsal), the [first beta](#first-beta-published), its [Homebrew install](#homebrew-install-from-the-tap) and the [Apple silicon requirement](#apple-silicon-only-xcode-27-and-macos-266).

## Environment and evidence handling

The latest physical checks used the designated iPhone 13 mini, iOS 27.2.1 (24B156), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2 and CoreDevice 651.32. Media work observed AVConference 2260.15.1. Some earlier input records used iOS 27.2 (24B119); results from one checkpoint do not establish all OS versions.

The phone had Developer Mode and Enable UI Automation enabled for the successful UI checks. It had no passcode until the evening of 2026-11-17, when the owner set one for testing; records before that describe a phone without one. Its default browser was Chrome until the same evening and is Safari since. Later checks found its display off. User preparation is not continuous proof that the device remains awake/unlocked.

Raw screenshots, movies, app/process inventories, addresses, device IDs, archives and stderr are working files and are not kept or published; this page is the record. The Git commits named below retain the detailed implementation checkpoints; temporary artifact UUID lists and intermediate test counts are omitted here.

Checkpoint hashes below refer to the rewritten public history. The publication cleanup changed paths and documentation, not the recorded device observations.

## Current local validation

On 2026-11-18, after the deployment target moved to macOS 26.6, the suite passed 703 default Swift tests through xcsift with zero errors and warnings, and all 42 mise tasks validated; hosted CI last passed on the commit before that change, with 702 tests on macOS 27.0.1 and Xcode 27.2. The paragraphs below are earlier checkpoints.

The MCP startup and call-order checkpoint (2026-11-16) passed 663 default Swift tests through xcsift with zero errors/warnings, once normally and three times with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; the three MCP suites also passed 15 strict runs in a row; all 41 mise tasks validated. The implementation checkpoint before (typing in a named keyboard layout, 2026-11-16) passed 571 default Swift tests through xcsift with zero errors/warnings, normally and once with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, and all 41 mise tasks validated. The checkpoint before it (app logs, console and crashes, 2026-11-16) passed 516 default Swift tests through xcsift with zero errors/warnings, three times normally and three times with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (one earlier strict run failed an existing streaming-runner wall-clock bound while new blocking tests shared the single pool thread; those suites now run on a dedicated thread); `mise run probe-app:test` passed 98; all 40 mise tasks validated; `mise run test:probe-touch <UDID> --dry-run` exited 0. Default tests are local regression checks, not hardware runs. Live checks are explicitly enabled and may have device effects.

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

One `wait-id` reported `subscriptionStop: unconfirmed` while its tunnel release was acknowledged; the others acknowledged both. The cause was not investigated. Since 2026-11-17 an unconfirmed stop's `diagnostic` also says how long the stop exchange ran (of its 3 s) and how many cleanup frames were read (of 32), which tells a lost acknowledgement from a device still sending callbacks; it has not recurred since.

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

**2026-11-16, at `184d064`**, after the CLI moved to Swift Argument Parser with typed dispatch. iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52). Every command below was run through the real CLI in the new grammar, most with the target taken from `MANZANERO_DEVICE`.

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

### The log relay on the phone

**2026-11-18, about 01:00**, the iPhone 13 mini (iOS 27.2.1), macOS 27.2.1. Two experiments the owner approved before deciding whether physical `logs` is worth building (later that day he made it a pending task). Neither is a command: the second is the opt-in task `test:os-trace-relay`.

What the service advertises, read from `/usr/libexec/remotectl dumpstate` on the Mac without opening anything on the phone: `com.apple.os_trace_relay.shim.remote` has `UsesRemoteXPC => false` and `EncryptSocketData => false`, and nothing else; `syslog_relay` and `crashreportcopymobile` shims the same.

The stream, over the route accessibility uses (tunnel assertion, port discovery, RSD directory), then a plain TCP socket to the port the directory advertises for the shim:

| Step | Observed |
| --- | --- |
| Settings' PID, 50 records or 5 s | `RSDCheckin` and `StartService` answered, `StartActivity` returned `RequestSuccessful` after one leading byte (1). No records in 5 s: Settings was idle. The reopen on the same directory failed, because the directory connection was no longer active 5 s after its handshake |
| The probe app's PID, 50 records, a directory of its own for each stream, `press --id probe.log.emit` from a second process | 50 records in 0.3 s (19,379 bytes), all from that PID, none failing to parse: 49 debug and 1 notice, mostly UIKit's. A second stream on a new directory read 5 records |
| The same with a bound of 3000 records and 15 s, the log trigger pressed twice | 165 records (64,853 bytes), no parse failures; levels 148 debug, 5 info, 8 notice, 2 error, 2 fault. From the probe's own subsystem 12 records: per press 2 notice, 1 info, 1 debug, 1 error and 1 fault. The rest were UIKit (132), hangtracer, network and Siri subsystems in the same process. The second stream again read 5 records; the tunnel assertion was released each time |

So the relay works over Apple's native tunnel on this phone, a PID filter holds on the device, the reference's record layout decoded every record seen, and debug-level lines of an app arrive, which `console` never shows. Not shown: entries with long or unusual fields, a stream of every process (`Pid: -1`), minutes-long streams, what a relaunch does to a PID stream, and whether closing the socket ends the subscription on the phone (a new stream opening is the only evidence). One phone, one iOS version.

### Web content in an app's own inset web view

2026-11-22, Xcode 27.2, macOS 27.2.1, the iOS probe's new web screen (`-ProbeWeb YES`, [web probe](probe-app.md#web-probe)): a `WKWebView` 40 points in from the safe area on every side, below a native label.

- **iOS 27.2 simulator** (`manzanero-research-phone`). The web view sat at (40, 154) and the page's process was the one its `AXRemoteElement` named, reached with `--pid`. The page's remote element came into the host's tree some seconds after launch (11 reads of the tree at about three a second, once). The first `tree --pid` of the page then had its frames relative to the web view ("Top button" at (12, 95) and the web area at (0, 0)); the second, 0.3 s later, had them in screen points ((52, 249), web area at (40, 154)), and every later one too. Reading the host's tree twelve more times over five seconds first changed nothing: the first page read was still relative. So it is the first read of the page, not its age. After the fix (the first page snapshot in a command is read twice), a `press --label "Top button" --pid <page>` sent on the page's first read hit (52, 249) and the label read `web-top`. `scroll --label "Bottom button"` moved the page, as a screenshot showed, but its check failed (`target enabled/visible state is unavailable, changed or unsuitable`): read at once, the target was still hidden in the snapshot while its live attributes said it was shown. With the check reading until the target stops moving, `scroll` to the bottom and back to the top both ended `postcondition-verified`, a press on "Bottom button" after the scroll read `web-bottom`, and `press --label "Web field" --index 2`, `type hola` and `wait --until value --value web-field:hola` all succeeded.
- **iPhone 13 mini** (iOS 27.2.1, on the tool's own tunnel over the cable). The web view sat at (40, 142); the page was the display-centre process, as with Chrome and Safari, and its first `tree` already had screen points ("Top button" at (52, 237)). `press` on "Top button", `scroll` down to "Bottom button" and back up (both `postcondition-verified`), `press` on "Bottom button", then `press --label "Web field" --index 2` and `type hola`: a screenshot showed `hola` in the field and the label `Last: web-field:hola`. The button presses were accepted; their effect was not read separately, since the field's value replaced it.

Not shown: a web view in a third-party app, a page that zooms, a horizontal scroll on a page.

### Hold and act on the phone, and the Apple TV without a person

2026-11-22, late afternoon. The iPhone 13 mini on Wi‑Fi, the probe launched with `-ProbeSystemEdges YES`; the Apple TV 4K (tvOS 27.2) on its paired tunnel.

**`hold` and `release` on the phone** ([design](gesture-sequences.md#holding-a-contact-across-steps)):

| Batch | Result |
| --- | --- |
| `hold 0.3 0.6`, `tap 0.7 0.6`, `tree`, `release`, `tree` | `completed`; during the hold the probe read one contact down (`active: 1`) after the tap had lifted; afterwards one gesture of two contacts, the held one 2.92 s at (0.300, 0.600), the tap 82 ms at (0.700, 0.600); `release: confirmed-by-barrier`, 17 reports, 10 of them refreshes |
| `hold`, `tap` and no release | `releasedBy: end-of-batch`, confirmed; both contacts ended in the probe |
| `hold`, a 40-second `wait` for an element that does not exist, SIGINT after 6 s | Exit 130, the device quarantined, the held contact ended normally in the probe after 3.9 s |
| `hold`, a short swipe opening Control Centre, `wait --id flashlight`, `press --id flashlight`, `wait … --value Brillante`, `press`, `wait … --value No`, `button home`, `release` | `completed` in 151 s: the contact held 147 s through 617 reports while the flashlight was switched on and off and each state read back; the release confirmed. Two earlier tries failed at the press's second snapshot, with the hold released and confirmed (`releasedBy: failed-step 4`) |
| The same with `press --id wifi-button` | The press `accepted`; the next step found no device, the release `unknown`, the device quarantined; the human owner switched Wi‑Fi on again. The probe had the held contact `cancelled` 0.9 s in, when Control Centre opened |

Control Centre's tree could not be read at first: every request had four seconds to be answered, and with Control Centre open each read of SpringBoard (the display-centre process then) took longer. A snapshot's answer may now take 40 s and a session 120 s (it was 30 s); then a `tree` took 21 s and a `press` in Control Centre 37 s. Its controls carry identifiers that do not depend on the language: `wifi-button`, `airplane-button`, `airdrop-button`, `flashlight`, `orientation-lock`, `cc-volume-slider`, `cc-brightness-slider`.

**The Apple TV 4K, no person needed:**

- The pairing two days after it was made: `tree` over `own-tunnel`, `ownTunnelLink: paired`.
- `record … 180 --backend coredevice --audio` on the tvOS probe's still screen, nothing playing: `recorded`, 180 s of video (49 pictures: a still screen sends almost none) and 179.97 s of sound, 18,011 packets with none lost or refused, 174 receiver reports, no restart.
- Swipe durations, sideways between the probe's text field and its rows, counting only swipes that could move the focus: 0.04 to 0.15 s, 0 of 20; 0.2 s (then the default), 3 of 9; 0.3 s, 9 of 11; 0.4 and 0.5 s, 16 of 16. The default became 0.4 s, and four default swipes between two buttons then moved the focus four times.
- `remote sleep` from the screen saver could not run: with the probe in front and no input for 20 minutes, checked every two minutes by screenshot, no screen saver started. Later the Home Screen was in front instead of the probe, for a reason not seen.

### Phone session of 2026-11-22, afternoon: with the human owner at the phone

The same phone, after the morning's runs, with the human owner's hands for the three checks that need them. No Apple TV command was sent.

**Another viewer.** `record … 90 --backend coredevice`; when the human owner opened Device Hub's screen view of the phone, the recording ended at once as `status: partial`, `stopCause: another-viewer`, a 6.7-second movie that plays (111 frames). Device Hub's view left open then refused the next recording ("Another media session is active; no recording started").

**Sound across a pulled cable, a fault and its fix.** The probe with `-ProbeTone YES` (its flash with each round's first beep), the phone on its cable (`ownTunnel: cable`) at about half volume, `record … 60 --backend coredevice --audio`, the human owner pulling the cable some 20 s in and plugging it back 10 s later. The recording recovered (`status: recorded`, one restart, a 7.0-second gap at 17.8 s), but its sound track was one unbroken 53.3 s run while the picture had the gap: after the restart every beep came about seven seconds before its flash, and the beep spacing broke once (1.24 s instead of 1.6 s) where the sound was spliced. `NativeAudioTrack` placed the restarted sound at its arrival, after the gap, but the movie's AAC writer encodes the samples it is given back to back whatever their times, so the gap vanished. The writer now fills a gap with silence (`NativeVideoEncoder.consumeAudio`). The same run with the fix (an 8.5-second gap at 17.4 s): a sound track of 59.97 s; measured from the movie (each flash's rise in brightness against the onset of each round's first beep), the sound trailed the picture by 48 ms at the median before the restart (11 pairs, 43 to 93 ms) and by −2 ms after it (21 pairs, −90 to +52 ms).

**A full ten minutes of logs.** `logs --seconds 590 --pid <probe> --subsystem <probe's> --level debug` ran its whole time (`stopReason: duration`), 119 records received, the probe's emit set kept.

**A lost network path during input, over the probe.** For the probe to record where a held contact ends, the tool itself cut the phone's Wi‑Fi in one `gesture` while contact 0 stayed down in the probe: the probe's new `-ProbeSystemEdges YES` gives the screen edges back, so a second contact can open Control Centre over it. Three lessons came first:
- Control Centre scrolls between its pages with the same drag that opens it: a swipe from the top edge to half the screen opened it and moved on to its second page. A swipe to 0.15 of the height opens page 1, twice of twice. laia-LLM took the page for unpredictable until the human owner pointed this out.
- With the long swipe, the first tap meant for Wi‑Fi landed on the media tile and opened Music, and the second on the second page's layout; that run ended "Input stopped after cancellation or transport failure", with no network loss, and Wi‑Fi stayed on although laia-LLM first read the failure as the cut.
- `tree` times out with Control Centre in front (`code: timeout`, "Accessibility socket deadline exceeded", in 6 s, on a newly opened connection too): each request has four seconds to be answered. Close Control Centre before reading the app.
With a button for Wi‑Fi that the human owner added to page 1, the short swipe and a tap there switched Wi‑Fi off: the gesture failed after 16 s as `input-outcome-unknown` ("the Apple service barrier was not confirmed"), a `tap` afterwards was refused as `device-quarantined` since that moment, and the human owner turned Wi‑Fi on again. The probe then showed why the release point cannot be seen this way: both contacts ended `cancelled` 0.52 s into the gesture, contact 0 at its own place (0.500, 0.600), when Control Centre took the swipe. iOS cancels an app's touches when Control Centre opens over it, so a Wi‑Fi cut made through Control Centre ends the held contact long before the network goes.

### Phone session of 2026-11-22, morning: the owed runs that need no person

iPhone 13 mini (iOS 27.2.1), unlocked, on the network (`ownTunnelUnavailable`: Apple's MobileDevice framework did not list it, so accessibility went over Apple's tunnel, `serviceDirectory: opened` or `reused-saved-port`), the probe built at that morning's commits and installed with `build-run`. No Apple TV command was sent.

| Check | Result |
| --- | --- |
| `console <probe> --seconds 10 -- -probeLogToken B1 -probeBulk 128` | The first attempt failed in `devicectl` ("process identifier of the launched application could not be determined"); the next ran. 133,349 and 133,165 bytes; each tail exactly 65,536 bytes, the stderr tail ending `end lines=2048`, the stdout tail with devicectl's `App terminated due to signal 2.`; lines end in `\r\n` (devicectl's terminal). `-probeBulk 4096`: `stopReason: byteLimit` |
| `set-value` on the [SwiftUI form](probe-app.md#swiftui-form-probe) by identifier (`Año café`) and by label (`second`) | `acknowledged`, `valueMatches: true`; the bound value followed, one change each, as on a simulator |
| `record … 60 --backend coredevice`, SIGINT after 12 s | Exit 130; "8.8 s movie of 153 source pictures kept … (partial)" on stderr; the file plays: H.264, 1136 × 2464, 154 frames, 8.84 s |
| `frames --count 1000 --seconds 120` on the still SwiftUI form | `stopReason: count`, 1000 frames in 87.4 s, 173 MB, 1125 × 2436, no restart. Meanwhile, from a second process, `record`, `frames` and `tap` were each refused: "Device is controlled by another manzanero process (pid …, frames) … no input sent" |
| `logs --seconds 590` for a group (bundle and process) at debug, filtered to the probe's subsystem | `stopReason: byteLimit` in under seven minutes: a group streams every process, and 256 MiB (750,900 records) arrived; 12 probe entries kept |
| `logs --seconds 590 --pid <probe>` at debug, unfiltered | `stopReason: entryLimit` (2000) after about five minutes of typing and gestures in the probe, whose frameworks log at debug |
| MCP `capture_logs`, `platform: physical`, `pid`, 20 s, with `press --id probe.log.emit` during it | `stopReason: duration`, the emit set at every level with the private value redacted, `processWatch: devicectl` |
| MCP `press_element`, `by: label`, `text: ^Row 1`, `match: regex`, `index: 2`, on the list probe | Row 10 pressed (rows 1 and 10–19 match; 10 is the second), `probe.list.last` read `row-10` |
| The staggered list (`-ProbeListStagger YES`) | Row 55 in 11 steps down (24 s), row 1 in 45 steps up (60 s), both pressed and recorded |
| The probe's framed page (`-ProbeWebFrame YES`) | The page is the display-centre process, so no `--pid`. `press --label 'Frame button'`, `press --with-value 'Frame input'` then `type hola`, and `press --label 'Page button'`, read back from `Last:` by text recognition (`probe.web.last` is in the app's process, not the page's, so a `wait` there timed out): `web-frame-button`, `web-frame-field:hola`, `web-outer`. A first Page button press with the keyboard up was refused at the live-attribute guard |
| System gestures as edge swipes | Up from the bottom edge (from y 0.999 and 1.0, 0.3 and 0.5 s) over Settings: Settings stayed, as on a simulator. Down from the top-right corner: Control Centre opened. Down from the top-left: Notification Centre opened. From the left edge in Settings › General: back to Settings (the app's own gesture). `button home` closed both centres |
| Three contacts in a real recognizer | In the probe's text field after typing `uno dos`, a three-path `multi-drag` to the left undid ` dos` (`uno`), and one to the right redid it: iOS's text editing took three contacts as undo and redo |

### The phone in landscape: keys, several contacts, frames and a recording

2026-11-22, the iPhone 13 mini (iOS 27.2.1), the probe launched with `-ProbeAllowRotation YES` and the phone turned with `rotate landscape-left` (`tree`: `rot270`, 812 × 375), on the tool's own tunnel over the cable; landscape-right at the end.

- **Keys.** `press --id probe.text.field`, `type "ab cd"` (`probe.text.value` read "ab cd"), then `key backspace`, `key left` twice and `key space`: the field read "ab  c", which is what those keys do. `key return` closed the keyboard.
- **Several contacts.** `multi-tap` with three points at y 0.45 arrived as three contacts at (0.30008, 0.44978), (0.5, 0.44978) and (0.69992, 0.44978); with five points from x 0.2 to 0.8 at y 0.4, as five contacts within 0.0002 of each. `pinch 0.5 0.45 0.2 0.5 0.5` arrived as two contacts moving from 0.39984 and 0.60016 to 0.25 and 0.74507, 21 moves each, in 0.504 s. All in the probe's landscape interface coordinates.
- **`frames` and `record --backend coredevice`.** Three frames and an 8-second movie (129 source pictures), both whole and both in the display's native portrait size: frames 1125 × 2436, the movie 1136 × 2464, with the landscape interface sideways in them. The tool does not turn them; a viewer must.

The phone was turned back to portrait afterwards (`rot0`). Later the same day all four were repeated in landscape-right (`rot90`, 812 × 375) with the same results: the field read "ab  c"; three and five contacts arrived within 0.0002 of their points; the pinch went from 0.39984 and 0.60016 to 0.25 and 0.74507 in 23 moves; three 1125 × 2436 frames and an 8-second 1136 × 2464 movie (126 source pictures), the interface sideways the other way. Not shown: a held key, a recording across a rotation.

### A cable pulled during a long press

2026-11-22, the iPhone 13 mini (iOS 27.2.1), the probe's touch surface, the tool's own tunnel over the cable, the human owner at the phone. A run of `long-press 0.5 0.4 10` was started and the human owner pulled the cable a few seconds later. The first press failed 8 s in (exit 1): `input-outcome-unknown`, `inputSent: possible`, `retry: after-inspection`, "Input stopped after cancellation or transport failure; release was attempted for active contacts or keys". Nothing was repeated. Six seconds later, with the cable back, `readiness` answered and a `tap` was refused before sending: `device-quarantined`, naming the `long-press` and the moment of its failure. A `tree` (own tunnel, cable) read the probe: one gesture, one contact, `began` 1, `ended` 1, `cancelled` 0, `active` 0, the contact `ended` after 6.662753 s from (0.50044, 0.39984), with its end position `[0,0]`. `clear-quarantine` cleared the mark, and a `tap 0.5 0.4` then arrived and ended at its own point, (0.50044, 0.39984). The `[0,0]` end matches the killed owner of 2026-11-17. Not shown: a pull during other kinds of input.

**A lost network path, the same night.** The cable out, the phone on Wi‑Fi (the tool's own tunnel was not up yet, `ownTunnelUnavailable: Apple's MobileDevice framework does not list the device`; input goes through Apple's input service either way). A first run of six 10-second `long-press` all completed, because Wi‑Fi stayed on. Then, at the human owner's request that the tool switch Wi‑Fi off itself, one `gesture` in Settings › Wi‑Fi did both: contact 1 tapped the Wi‑Fi switch at (0.825, 0.391) and lifted at 80 ms, contact 0 stayed down on the header card at (0.62, 0.23) and was sent again every 250 ms until 10 s. It failed 13 s after it started (exit 1): `input-outcome-unknown`, `inputSent: possible`, "Input was attempted, but the Apple service barrier was not confirmed. UI effect and release are unknown". With the cable back, a `tap` was refused as `device-quarantined` with `since` at the failure, and a screenshot showed Wi‑Fi off and Settings otherwise unchanged; Settings records no touches, so where contact 0 was released is not known. `clear-quarantine`, then `press --id wifiSettings.powerToggle` switched Wi‑Fi on and `wait --id wifiSettings.currentNetworkConnected --until visible` met its condition: the phone was back on its network. Not shown: a network loss that comes back within the gesture, the release point of a held contact after a network loss.

### Sound across a pulled cable

2026-11-22, the iPhone 13 mini (iOS 27.2.1), the probe launched with `-ProbeTone YES` at the phone's volume as the human owner left it, `record <movie> 60 --backend coredevice --audio` on the tool's own tunnel over the cable, the human owner pulling the cable and putting it back. A first 60-second recording ran whole with no restart (6008 sound packets, none lost, 60.08 s of sound, 57 receiver reports): the cable had stayed in. In the second the cable was pulled about 8 s in: exit 0, `status: recorded`, a 60-second movie of 864 source pictures, `recovery: {restarts: 1, gaps: [{atSeconds: 7.79, seconds: 7.312, reason: stream-ended}]}`, and `audioTrack` with 5314 packets, `packetsLost: 0`, `packetsRefused: 0`, `secondsWritten: 53.14` (the movie less the gap), `restarts: 1` and 49 receiver reports summed over both sessions. The probe was closed afterwards. Not shown: whether the sound after the restart is in step with the picture (a measurement with the probe's flashes was started and stopped at the human owner's request before it was read), a lost link that needed the stop of both streams by identifier (unit-tested only), the Apple TV.

### Phone session of 2026-11-21: the day's new commands, landscape and a recording

On the iPhone 13 mini (iOS 27.2.1), the evening of 2026-11-21, at the human owner's word, with the probe app. The tool's own tunnel was not available ("Apple's MobileDevice framework does not list the device"), so accessibility ran over Apple's tunnel (`serviceDirectory: reused-saved-port`).

- **`launch` with app arguments** failed at first: `devicectl` read `-ProbeList` as its own short options and its `-t` took `YES` ("The value 'YES' is invalid for '-t <seconds>'"). `console`'s `-ProbeTone YES` had passed only because it has no lowercase `t`. Both now put `--` before the bundle when the app has arguments, as `devicectl`'s help asks; then `launch … --relaunch --env PROBE_X=1 -- -ProbeList YES` opened the list screen.
- **`--match regex`**: `press --label '^Row 4$' --match regex` was accepted and the probe read `row-4`.
- **`terminate <bundle>`** ended the probe (no ProbeApp process afterwards); a second one said "is not running; nothing was terminated".
- **`double-tap 0.5 0.3`**: the probe counted two gestures.
- **Landscape** (the probe launched with `-ProbeAllowRotation YES`, the phone turned with `rotate landscape-left` and `landscape-right`): `tree` read `rot270` with 812 × 375 bounds; `press --id probe.text.field` was accepted in both turns and `set-value` wrote "landscape ok" into it, so the mapping of hit points to native portrait holds on the phone. `press --id probe.touch.reset` was refused in landscape at the hit check and accepted in portrait: in landscape its centre (406, 269) lies inside the frame of `probe.touch.last-gesture` (y 164 to 284), which answers the hit; a layout overlap of the probe, and the guard doing its job. `probe.log.emit` was refused as not visible: at y 400 it is below a 375-point screen. `rotate portrait` turned it back.
- **`location 40.4168,-3.7038`** and **`location --clear`** succeeded. **`paste`** then **`clipboard`** read back "clip ñ 13m" exactly.
- **`status-bar`** is refused by the phone: "The capability “Simulate Status Bar” is not supported by this device" (CoreDevice error 1001); the command now refuses a device before contacting it.
- **`record … 8 --backend coredevice`** made an 8-second movie as before, with `recovery: {restarts: 0, gaps: [], lastPictureHeldFrom: null}` and the device's stop confirmed. Recovery itself (a stream taken away mid-recording) needs the human owner at the phone and did not run.
- **Later the same evening, the small checks.** `open-url manzanero-probe://from-settings` with Settings in front brought the probe forward with the URL (`1 manzanero-probe://from-settings`) and no prompt: the "Open in Probe?" question had been answered on this phone before. A six-step `batch` (two waits, a press, `settings`, `clipboard`, `screenshot`) and an MCP session (`initialize`, then `get_ui_tree`, `read_settings`, `double_tap`, `press_element` with `match: contains`) all succeeded over Apple's tunnel with the phone off its cable, the network route. In landscape (the probe's list with `-ProbeAllowRotation YES`, `rotate landscape-left`): `screenshot` gave 2436 × 1125 pixels, `scroll --id probe.list.row.30 --search 30` found the row in 5 steps, and a `tap` at that row's centre from the tree made the probe read `row-30`, so touch maps the turned interface too. Not run: an action in flight when the cable is pulled, which needs the human owner at the phone.
- **The cable pulled mid-run**, the human owner pulling it at about 15:06:05 and putting it back some 20 s later. A `wait` on the tool's own tunnel (`ownTunnelLink: cable`) lost its tunnel, was run once more as designed, found the tunnel gone ("Apple's MobileDevice framework does not list the device"), ran over Apple's tunnel instead and answered `timed-out` with the first attempt's error in `retriedAfter`; the three waits after it were back on the cable tunnel. A `record … 240 --backend coredevice` that had delivered 101 pictures failed instead of recovering: the restart first closes the lost session and needs its stop confirmed, and with the phone unreachable it was not ("could not confirm the end of a lost session, so it was not restarted: owned stop=false, stream absent=false"), so by the design's rule no second session was opened and the recording failed after 12 s, its pictures discarded. An earlier run of the same, at 15:00 to 15:02, showed nothing because the cable was pulled after it. After the recovery learnt to wait for the device and stop its lost stream by identifier (options A and B, [recovery](recording-recovery.md)), a pull 62 s into a run kept a 62.6-second movie as `partial` (before the stop by identifier existed), and a pull 27 s into the next one recovered: a 240-second movie, one restart, a 7.2-second gap, clean final stop.
- **An action in flight when the cable is pulled**, later that evening (17:18 to 17:29, at `6b60bb8`), with the probe's list screen in front and the human owner at the phone. A loop relaunched the probe and ran `scroll --id probe.list.row.60 --search 15`, ten times, each search about 11 s and nearly all of it in flight. The human owner pulled the cable at the phone end twice; the Mac's kernel log gives the times (`0x05ac/12a8 (iPhone): hardware connection lost`):

  | Cable out | Search in flight | The search after it |
  | --- | --- | --- |
  | 17:26:57.6, back at 17:27:17 | Failed once as `input-outcome-unknown`, "Accessibility socket deadline exceeded … stage=search … No automatic retry", subscription stop unconfirmed, route `own-tunnel`, `cable`; not run again | Over Apple's tunnel (`serviceDirectory: opened`, `ownTunnelUnavailable`: "Apple's MobileDevice framework does not list the device"), row 60 found; the next three back on the cable tunnel |
  | 17:28:03.3, back at 17:28:19 | The same, at `stage=live-attributes` | Over Apple's tunnel (`reused-saved-port`), row 60 found; the next three back on the cable tunnel |

  So a `scroll` whose tunnel ends under it fails once and is not repeated, as designed; Apple's connection to the phone read `connected (connectable)` afterwards. A first attempt at 17:18 pulled a cable at the Mac's end: the kernel log shows it was the iPad's (`0x05ac/12ab`), on the same Mac, which the tool sent nothing; the phone's tunnel was untouched. The `batch` across a change of link did not run: three batches of thirty steps (`wait`, `press`, `tree` on rows 1 to 10) all ran on the cable tunnel, 90 results of 90, with no pull during them.
- **A search upward on this list takes four times the steps of one downward.** In the same loops, `scroll --id probe.list.row.1 --search 15 --toward up` from the bottom of the list failed six times of six with "selector not found after 15 search step(s)", while the search down to row 60 took 4 steps every time. On `manzanero-research-phone` the same pair failed the same way, and with `--search 60` the search up found row 1 in 16 steps. The table keeps rows below the screen in the tree and almost none above it, so a step upward moves the list three or four rows and a step downward about a screen. Give a search upward a larger budget.
- **Later that evening (about 19:06), with nobody at the phone**, unlocked, the probe's list screen in front, everything on the tool's own tunnel over the cable. Searches in four directions, each `postcondition-verified`: down to row 60 in 4 steps, up to row 1 in 16 (`--search 30`), right to column 38 in 17 and left to column 2 in 17. `record … 8 --backend coredevice`, the first since the recording loop was moved behind `NativeRecordingLink`: `status: recorded`, 8 s, 133 source pictures, the device's stop confirmed and the stream gone, the tunnel assertion released, `recovery.restarts: 0`. And a still screen for a minute: `frames … --count 1000 --seconds 60` with no `--interval` saved every picture that arrived, 650 in 59.9 s, a median of 98 ms apart and at most 119 ms, none 250 ms or more (the probe's list, unchanged throughout; the display dimmed before the run). The same minute with `MANZANERO_KEEP_STREAM=1` kept 1390 packets, whose RTP timestamps are 0 in the first packets and do not read as a 90 kHz clock, so the gaps were taken from the pictures' arrival on the Mac instead.
- **`frames` and a `batch` across a pulled cable**, about 22:00 that night, at `a9fe7e1` plus the error category below, with the human owner at the phone pulling its cable at the phone end; the Mac's kernel log gives the times. A first `frames` run of 90 s saw no pull (none was made during it). Then `frames … --count 1000 --seconds 120 --interval 250`: the cable out at 22:02:28.9, 7.5 s into the run, and back at 22:02:40.6. The run recovered: `recovery: {restarts: 1, gaps: [{atSeconds: 5.619, seconds: 6.866, reason: stream-ended}]}`, the offsets of the saved frames jump by 6.9 s there, 480 frames, `stopReason: duration`, the last session's stop acknowledged and its stream gone. Then three `batch` runs of thirty steps (`wait`, `press` and `tree` on rows 1 to 10): the first two ran whole on the cable tunnel (60 results of 60), and in the third the cable came out at 22:07:53.2 (back at 22:08:07.7) while step 11, `press --id probe.list.row.4`, was opening its connection: it failed before anything was sent ("Accessibility socket deadline exceeded … state=not-sent, stage=start", `inputSent: none`, `retry: safe`), the batch stopped there with `completedSteps: 10, failedStep: 11`, and steps 12 to 30 did not run; nothing was repeated. The phone was listed on the cable tunnel again afterwards. The failure's category read `unclassified`; the accessibility socket's own failures are classified since (a deadline is `timeout`, [errors](errors.md#unclassified-sites)).
- **Device Hub taking the stream**, about 22:22 that night: a two-minute `record --backend coredevice` of the probe's list, and the human owner opening Device Hub's screen view of the phone. At 15.5 s the stream ended (`stream-ended`); the restart found the device still running a media session, which was Device Hub's, could not stop its own lost one by identifier (not acknowledged: the device had ended it), and so opened nothing and stopped nothing, as designed. The 15.5 seconds captured were kept (`status: partial`, 257 pictures). The tool does not take the screen back from another viewer. Repeated at 22:43 with the human owner watching Device Hub: the stream ended 3.2 s in, the tool kept those 3.2 s (`partial`, 58 pictures) and opened nothing, and Device Hub's view showed the phone live at once, with no freeze or flicker, stayed live, and controlled the phone.
- **Safari on the phone** (Safari named for this check by the human owner), a `data:` page typed into its address bar in the phone's Spanish – ISO layout (heading "Ready", a field labelled Email, a Send button writing "Clicked " and the field's text into the heading). Unlike Chrome, the page's tree is not rooted at the browser's remote element. On the tool's own tunnel: the default `tree` was the page (process 7977; Safari 6891); `wait --label Send` met; `press --label Email` and `type 'phone ok'`, then `press --label Send`, and the heading read "Clicked phone ok"; `set-value --label Email` was acknowledged and changed nothing (`valueMatches: false`), as in Chrome; `press --id TabBarItemTitle --pid 6891`, Safari's own address bar by the browser's PID, was accepted.
- **An interrupt during a recording.** A five-minute `record --backend coredevice` on the Apple TV 4K (the tvOS probe in front, video only) was stopped from the outside after three minutes, at the human owner's request. It printed nothing more, and the Apple TV kept streaming: `record` was not under the CLI's signal scope, so the interrupt ended the process before its stream was stopped. A one-frame `frames` run on the Apple TV replaced that session and stopped cleanly (owned stop acknowledged, stream absent). Since then an in-process recording is under the signal scope: on the phone, SIGINT eight seconds into a recording printed "Interrupted by SIGINT; stopping native recording", exited 130, and reported owned stop true, stream absent true and the tunnel released ([recording](recording.md#ownership-cleanup-and-publication)).
- **Picture against sound**, about 22:50, the human owner at the phone: the iOS probe with `-ProbeTone YES` and its new flash (white during the first beep of each 1.6-second round, [probe](probe-app.md#tone-probe)), rebuilt and installed by `build-run`. The phone's volume was at its lowest and nothing was heard until the human owner raised it. `record … 60 --backend coredevice --audio`: a 60-second movie with a video and a sound track, 1033 source pictures. Measured on the Mac from the movie (each flash's rise in mean brightness against the rise of each round's first beep after 0.35 s of quiet), 19 pairs: the sound came before the picture by 192 ms at the median, and by more as the recording went on, about 96 ms over the first ten pairs and 390 ms over the last ten, across 59 s, some 5 ms a second. So the sound and the picture of a recording with `--audio` drift apart. The run also ended `partial`: the movie ran its full 60 s, but the final stop was not acknowledged although the stream was gone ("Owned media stop is unconfirmed"), and that receipt said `audio: false` although the movie has sound. The human owner then asked for the beeps to stop, and the probe was closed. The movie gave the cause: the picture's rounds were 1.59973 s apart, true to the probe's 1.6 s, and the sound's 1.57322 s, 1.7% short, so the sound track was compressed, not delayed. Each 480-sample piece was placed at its RTP timestamp over 48 000 in floating point, truncated to nanoseconds, and the movie writer skips a piece that starts before the previous one's end; replayed on the Mac, that timing put 104 pieces of 6000 (1.73%) a nanosecond early, and the sound after each skipped piece moved 10 ms earlier. Both times are whole-number arithmetic since (480 samples are exactly 10 ms), with a test of a minute of packets in which no piece starts early; the receipt of a kept recording now carries its sound, and an unconfirmed stop says whether the video or the sound went unnamed. Measured again at about 23:10 with the fix, the beeps and the flash, the human owner present: `record … 180 --backend coredevice --audio` gave rounds of 1.59990 s in the picture and 1.60014 s in the sound, so no drift, and the sound 15 to 87 ms after the picture (median 27 ms, 40 ms over the first ten pairs and 29 ms over the last ten). But the sound track held only 29.68 s of the 180 (2968 packets, none lost or refused): the device's sound stream ended about 30 s after it started, while the probe kept playing; the 60-second run before had beeps only in its first half too. The video stream gets an RTCP receiver report every 100 ms and the sound stream none, and a sender that hears nothing back for about 30 s ending its stream is ordinary RTP behaviour; that is the suspected cause, unconfirmed. It also explains the final stop: "video named: yes, sound named: no", the sound stream having ended already, with no stream left afterwards. The recordings with sound of 2026-11-20 were 8 to 60 s and were not checked for this. Both start requests ask for a 30-second timeout, and only the video was answered. The audio stream's start reply names its RTCP sender and receiver as the video's does; the tool now sends receiver reports for it too, on its own socket, on the video's 100 ms beat (best effort: a failure stops them, not the recording). Checked at about 23:35 with the beeps and the flash: `record … 75 --backend coredevice --audio` gave `status: recorded` with a confirmed stop, 75.11 s of sound (7511 packets, none lost) and 71 receiver reports sent for it; all 47 rounds paired, the sound 39 to 117 ms after the picture (median 53 ms; 63 ms over the first ten and 57 ms over the last ten), no drift. The probe was closed afterwards.
- **`settings`**, at the human owner's word: the read (`settings` without options, `devicectl device info appearance`) gave light, Extra Small, increase contrast off, reduce motion off; `settings --appearance dark --text-size small --increase-contrast on` read back as dark, Small, contrast on; `settings --appearance light --text-size extra-small --increase-contrast off` read back exactly as before.

### Phone session of 2026-11-20: a table row, a moving stream, open-url and logs

**2026-11-20, from about 22:05 local time, at `d0c6209`** (the `logs` changes below on top of it), on the human owner's word for the iPhone 13 mini: iOS 27.2.1, unlocked, no passcode asked, portrait, on its cable. macOS 27.2.1, Xcode 27.2 (27B52). The probe app was built and installed again with `build-run` before the session. Every accessibility command ran on the tool's own tunnel (`serviceDirectory: own-tunnel`, `ownTunnelLink: cable`) unless said otherwise. Only the probe app was used.

| Check | Observed |
| --- | --- |
| `press --id probe.list.row.5` on the probe's list screen (launched with `-ProbeList YES` through `devicectl device process launch … -- -ProbeList YES`) | Accepted, and the probe's label read "Last: row-5" in the next tree and on a screenshot. The first press of a plain `UITableViewCell` row on a phone; the guard of 2026-11-20 for a row's second object let it through |
| `frames` (60 pictures, 200 ms apart, `MANZANERO_KEEP_STREAM=1`) and `scroll --id probe.list.row.55 --search 40` in one MCP session | The scroll ran while the stream did (4 steps, `postcondition-verified`) and its answer came first. A second process could not do the same: the `frames` lease refused its scroll, as designed. 435 packets. The saved frames show the list on rows 13–24, 25–36 and 49–60, each picture whole |
| The kept stream, read on the Mac with `ffprobe` and decoded with `ffmpeg` | HEVC Main, 1136 × 2464, 283 pictures, one key frame at the start and no other picture near its size. Pictures 20, 120, 178 and 280 decoded by ffmpeg are whole, with nothing drawn on top of anything. So on this phone the stream does not use VideoToolbox's resolution adaptation, although the tool's offer still carries it for a phone's display: the iPhone's offer is left as it is |
| `open-url 'manzanero-probe://check?n=1'` with the probe in front | `probe.url` read "1 manzanero-probe://check?n=1". No prompt: iOS did not ask, the probe being the app in front. The prompt case (opening the probe from another app) was not run |
| `logs --seconds 15 --bundle <the probe> --level debug`, with `press --id probe.log.emit` twice from a second process | `--bundle` resolved to the probe's PID and executable. 180 records received (73 kB), 179 kept, all of that PID: 151 debug, 9 info, 15 default, 2 error, 3 fault. The probe's own subsystem had 12, six per press (default, info, debug, error, fault and a `<private>` line), with timestamps in UTC that matched the clock. One record did not parse; its cause was not kept, and the result now names the first failure (`firstParseFailure`). `devicectl`'s process table reached stderr; the queries now pass `--quiet` |
| `logs --seconds 10 --process ProbeApp --subsystem <the probe's> --level debug`, one press | 61 records received, 6 kept, 55 filtered out, none failed to parse, stderr empty |
| The same by `--bundle` with `MANZANERO_OWN_TUNNEL=0` | `serviceDirectory: opened`, Apple's tunnel: 61 received, the 6 lines of the press kept |
| SIGINT eight seconds into a 30-second `logs` | Exit 130 within a second, no result on stdout |
| `logs --seconds 30 --bundle <the probe>`, and `terminate` of the probe's PID six seconds in | The relay did **not** end the stream when the process ended: it stayed open and silent until the 30 seconds were up (`stopReason: duration`, no records). So ending a capture with its app needs a check of the tool's own |
| A mistake before that run | A first try took the PID from a `grep` of `processes` and got the process listed before the probe's, 7265: its stream received nothing, and `terminate` was sent to that PID with its output filtered away, so what 7265 was and whether it ended are not known. It was not in the process list afterwards. The phone stayed awake with the probe in front and reported no probe crash. Take a PID from a parsed result, never from neighbouring lines |

Later that night, with the processes chosen as one, a group or all (decision L) on `b9cc943` with the changes committed after it:

| Check | Observed |
| --- | --- |
| `logs --all --seconds 30 --level debug` keeping nothing (`--match` with text no message has), the phone idle | 16,838 records, 5.9 MB: about 560 records and 200 kB a second. 142 did not parse, all of one shape: a record that ends after its message while its subsystem-size field holds a value (`0x9ba40000` in one from `locationd`). Parsed as a record without subsystem, as the reference does; a second run read 21,240 records with none failing |
| `PidList` on the relay, read with a temporary test | On a fresh socket after the check-in: 433 PIDs. A second `PidList` on the same socket: the relay closed it. A fresh socket each time, while a stream ran on another: answered three times of three |
| One process: `logs --seconds 60 --bundle <the probe>`, the probe terminated six seconds in, its PID checked against its executable first | `stopReason: processEnded` three seconds after the terminate, `processWatch: relay`, on the tool's own tunnel |
| The same with `MANZANERO_OWN_TUNNEL=0` | `processEnded` one second after the terminate, `processWatch: devicectl`, `serviceDirectory: opened` |
| A group, `--bundle <the probe> --process locationd --seconds 15 --level debug`, the probe not running and launched four seconds in | `deviceStream: every process`; 3,026 kept of 12,291 received, none failing to parse: 1,332 from `locationd` and 1,694 from the probe, from its first lines at launch; stopped at the default 1 MiB (`byteLimit`) |
| On the project's simulator `manzanero-research-phone`, booted for it and shut down after | `--process SpringBoard --process backboardd`: the predicate joined them with `OR` and both processes' entries came back. `--all --match a`: `eventMessage CONTAINS "a"`, entries from many processes. Both stopped at 2,000 entries |

Not shown: what a relaunch does to a stream, a stream of minutes, records with unusual fields, a second phone.

### Phone session of 2026-11-17

**2026-11-17, at `01988bf`**, the same iPhone 13 mini (unlocked, portrait, reached over `apple-network-rsd`), macOS 27.2.1, Xcode 27.2 (27B52), `devicectl` 651.32.
**Recording and `frames` after the bridge became packet-only.**

| Command | Observed |
| --- | --- |
| `record <new>.mp4 5 --backend coredevice` | Exit 0, `status: recorded`: 1136×2464 `avc1`, 5 s, 78 source frames, `frameDecoded: true`; every cleanup field confirmed. `rtcp.negotiatedFeedback: disabled`, 5 receiver reports sent, 5 sender reports observed |
| `frames <dir> --count 10` | Exit 0: 10 JPEG files of 1125×2436, first frame after 549 ms, about 45 ms apart; the last frame showed the Home Screen as the screenshot did; cleanup acknowledged |

This is the first live reading of `rtcp.negotiatedFeedback`. It was `disabled` in this one session, so a keyframe request (PLI/FIR) has nothing negotiated to ride on. That reading alone did not say the phone refused: the negotiated value needs both sides, and the stock offer does not ask. The [experiment that asked](#an-offer-that-asks-for-rtcp-feedback) settled it the same night.

**A hold whose sender is killed.** Probe app in front, counters reset.

| Step | Observed |
| --- | --- |
| `long-press 0.5 0.5 8`; `tree` about 2 s in | `probe.touch.summary`: `began 1`, `active 1` |
| `kill -KILL` of that process, then `tree` at once (within about a second) and 10 s later | Exit 137. Both reads: `active 0`, `began 1`, `ended 1`, `cancelled 0`. The gesture lasted 2.29 s and ended as `ended`, with its end position reported as `[0,0]`, where an ordinary tap ends where it began |
| `tap 0.5 0.5` | Exit 1, `device-quarantined`, `inputSent: none`, naming `pid …, long-press`; the summary did not change. The `since` time in the message was the time of this refusal, about 20 s after the kill, not the time of the kill |
| `clear-quarantine`, then `tap 0.5 0.5` | `status: cleared` with the reason; the tap was recorded as gesture 2 |

So this phone ended the contact itself when the sending process died, as the simulator did. Not shown: a held key or button (the plan asked for them only if the contact stayed down), a lost cable or network path instead of a dead process, and an app's reaction to a release at `[0,0]`.

**`set-value` outside the probe app.**

| Field | Observed |
| --- | --- |
| Settings search field (a `UISearchBarTextField` inside SwiftUI's search bar host) | Not addressable: the node has neither label nor identifier, only the placeholder as its value. `--label Buscar` found no match; `--label Búsqueda` (the magnifier image) was refused with `precondition-changed`. Nothing was sent |
| A web form in Chrome (username and password inputs) | `tree` failed twice with `transport-failed`, "snapshot root identity mismatch", and `set-value --label Username` failed the same way at its first snapshot. `tree --pid <Chrome>` returned 115 nodes that stop at `WKContentView`, with no element of the page; `set-value --pid <Chrome>` was refused because the display-centre process is a different one. Nothing was sent. Safari was not tried |
| Settings › Wi‑Fi › Other network, `Nombre` (`UITextField`) | `set-value --id Nombre 'prueba ñ€ 日本 🙂'`: `acknowledged`, `valueMatches: true`, 24 bytes; a fresh tree and the screenshot showed the text |
| The same sheet, `Contraseña` (secure `UITextField`) | `acknowledged` with `valueMatches: false`: 17 bytes requested, 42 read back. The tree value was 14 bullets for the 14 characters sent, and the sheet's join button became enabled. The sheet was then cancelled; no network was joined |

A secure field takes the value but reads back as bullets, so `valueMatches` is false there even when the value arrived. No SwiftUI field with a label or identifier was tried. While navigating, one `press` whose selector had no match reported its subscription stop as unconfirmed: "Accessibility socket closed or reached EOF (stop exchange: 3 ms of 3000, 1 of 32 cleanup frames read)". That is the second such report and the first with the stop's timing. Chrome showed two first-run promotions, which were dismissed with "No, gracias" and "Saltar"; the test page was left open in a tab.

**MCP against the phone, calls sent without waiting.** One stdio `manzanero mcp` session; `initialize`, `notifications/initialized` and seven `tools/call` requests written at once: `press_element probe.touch.reset`, then `tap` and `set_element_value probe.text.field` alternating three times, with different points and values.

| Check | Observed |
| --- | --- |
| Answers | All seven `isError: false`, in the order sent |
| Taps | Gestures 1 to 3 in the probe at (0.3, 0.2), (0.5, 0.3), (0.7, 0.4), in that order, about 2.7 s apart |
| Values | `valueMatches: true` three times; `probe.text.value` ended as `tres 日本 🙂` (9 scalars, 16 bytes), the last value sent |

**`console` with debug lines and a small bound.**

| Command | Observed |
| --- | --- |
| `console <probe> --seconds 6 --os-log -- -probeLogToken S1` | The info, default, error and fault lines were mirrored; the debug line was not. The `.private` value arrived unredacted |
| `console <probe> --seconds 30 --os-log --max-bytes 1024`, with `press --id probe.log.emit` eight times from a second process | Nine sets written. `stderrBytes: 4660`, `stderrTail` the last 1024 bytes ending with set 9, `truncated: true`; stdout (598 bytes) whole, with every flushed and unflushed line |

Debug-level lines therefore do not come through physical `console`. An output above the 64 KiB default or the 1 MiB maximum was not produced: the probe has no bulk trigger.

### Handoff with a physical step

**2026-11-17**, same phone and host; the owner at an interactive terminal. The phone has no passcode and no Face ID, so the step was a physical one: rotating it.

| Step | Observed |
| --- | --- |
| Before: Safari in front, `tree` | `display.orientation: rot0`; screenshot 1125×2436 |
| `handoff '<message>' 5` from a non-interactive shell | Exit 1, `host-requirement`, "Handoff needs an interactive terminal, or an MCP host with form elicitation support", `inputSent: none` |
| `handoff 'Rotate the phone to landscape and leave it there' 300`, run by the owner in a terminal | The request on stderr with the three answers offered; the owner rotated the phone and typed `done`. Receipt: `status: acknowledged`, `mechanism: terminal`, `humanAcknowledged: true`, `verified: false`. The exit status was not noted |
| After: `screenshot` | 2436×1125, Safari laid out in landscape: the step had been done |
| After: `tree` | Exit 1, `transport-failed`: "native AX centre selection requires portrait geometry". The tree does not read a phone in landscape |

Not shown: a system prompt (permission, Face ID, passcode, purchase), which this phone cannot raise for a passcode and which was not set up for a permission; `decline`, `cancel` and a timeout on a device; the MCP form flow with a real host; the pause on mutations while a handoff is pending, which is per process and so not visible between a terminal handoff and commands from another process. Later: all of these ran the same day and the next, in the sections that follow.

### A passcode on the phone: pairing, handoff and the lock screen

**2026-11-17, evening**, same phone and host, after the owner set a passcode on the phone, which had had none.

**Pairing.** The first `readiness` after the passcode was set exited 1 with `connection: disconnected`, `pairing: unpaired`, Developer Mode unknown and the display and lock queries failing; Xcode's device window offered "Pair" for the phone. No prompt appeared on the phone by itself. Setting a passcode on a phone that was paired without one appears to have dropped the pairing; this is one observation.

| Step | Observed |
| --- | --- |
| `handoff 'Click Pair in Device Hub, then tap Trust on the phone and enter the passcode' 300`, run by the owner | The owner paired and typed `done`: `status: acknowledged`, `mechanism: terminal`, `humanAcknowledged: true`, `verified: false`, exit 0 |
| `readiness` afterwards | Exit 0: `connected`, `paired`, Developer Mode `enabled`, developer image services `available`, `passcodeRequired: false` while unlocked. `screenshot` and `tree` worked again |

This is the handoff's first run around a real system step (pairing, with the passcode entered on the phone). What the phone showed was not observed from the Mac.

**The lock screen with a passcode.**

| Command | Observed |
| --- | --- |
| `button lock`, then `readiness` | `displayPower: off`, `passcodeRequired: true`, `ui.status: needsUserAction`, with the action "Unlock the selected device directly; do not send its passcode to the tool"; prerequisites still present, exit 0 |
| `wake` | Exit 1, `status: awake-locked`: `sideButtonPressed: true`, `homePressed: false`, `displayPower: on`, and the action "The device requires a passcode. Unlock it directly; the tool does not enter passcodes" |
| `wake` again while awake | Exit 0, `already-awake`, no button pressed |
| `tree` and `tap` once the display had gone off again (within about 10 s) | Both exit 1, `display-off`, `inputSent: none`, `action: wake` |
| `screenshot` with the display off | Exit 0 and a black image |
| `tree` right after a `wake` | Exit 0: the lock screen's own tree, 176 nodes, with "Bloqueado", the date and time, "Linterna" and "Cámara" |
| `tap 0.5 0.5` right after a `wake` | Exit 0, `dispatched`: input is gated on the display being on, not on the lock. The receipt says nothing about the lock |
| `screenshot` right after | The lock screen |

So `wake` keeps its promise with a passcode (it wakes, does not press Home and enters nothing), and the failures on a sleeping phone are classified. Two things to know: a screenshot of a sleeping phone succeeds with a black image, and touch is sent to a lock screen without any note that the phone is locked.

Later the same evening input receipts gained `passcodeRequired` and a `lockNote` ([guide](native-input.md#receipts-and-partial-effects)). On the locked phone, right after a `wake`: `tap 0.5 0.5` and `key escape` both returned `dispatched` with `passcodeRequired: true` and the note. After the unlock below, `button home` returned `passcodeRequired: false` and no note.

**The other handoff answers, and an unlock**, run by the owner in a terminal with the phone locked:

| Command and answer | Observed |
| --- | --- |
| `handoff '<message>' 60`, answered `decline` | `status: declined`, `humanAcknowledged: false`, exit 1 |
| `handoff '<message>' 10`, left unanswered | `status: timedOut`, `humanAcknowledged: false`, exit 1 |
| `handoff 'Unlock the phone with the passcode' 300`; the owner unlocked it and answered `done` | `status: acknowledged`, exit 0. Afterwards `readiness` read `passcodeRequired: false` with the display on, and `tree` and the screenshot showed Settings, not the lock screen |
| `handoff '<message>' 60`, answered `cancel` | `status: cancelled`, `humanAcknowledged: false`, exit 1 |

End of input was not run on a device. Not shown: the passcode keypad, a phone restarted and not yet unlocked, Face ID, and a notification or call on the lock screen.

### Handoff with an app permission prompt

**2026-11-17, evening**, same phone and host, with the probe app rebuilt to include its [permission probe](probe-app.md#permission-probe) and installed by `build-run` (no provisioning options; the existing profile was reused).

| Step | Observed |
| --- | --- |
| `tree` after launch | `probe.permission.request` at 204,400 155×52 with value `{"requests":0,"status":"notDetermined","v":1}` |
| `press --id probe.permission.request` | `accepted`. The screenshot showed the system alert "Probe quiere enviarte notificaciones" over the probe; `tree` selected the alert's process (pid 39, 139 nodes) and read its title, its text and the buttons "No permitir" and "Permitir" |
| `handoff 'Answer the notification prompt on the phone: Permitir or No permitir, your choice' 300`, run by the owner | The owner decided the prompt and answered `done`: `status: acknowledged`, `humanAcknowledged: true`, `verified: false`, exit 0 |
| `tree` afterwards | The probe app again (16 nodes), no alert, and the element's value `{"requests":1,"status":"denied","v":1}` |

The decision was the person's; the tool pressed neither button. The receipt does not say which was chosen, and the probe's status shows it was "No permitir". Not shown: a biometric or purchase prompt, and a prompt raised by an app other than the probe.

### Handoff through an MCP host: the pause and the form

**2026-11-17, evening**, same phone and host. `manzanero mcp` ran as a stdio server of an interactive Claude Code session; the probe app had been uninstalled and installed again, so its notification status read `notDetermined`, and `press_element probe.permission.request` raised the prompt.

| Step | Observed |
| --- | --- |
| `request_handoff` and a `tap`, issued together by the host's model | The host ran them one after the other. `request_handoff` returned `status: notCompleted`, `mechanism: mcp-form`, `humanAcknowledged: false`, as an error result. The `tap` then ran, `dispatched`, and the probe recorded it, so no handoff was pending by then |
| `request_handoff` again, with a second agent of the same host sending one `tap` about 25 s later | The tap was refused: "Automation is paused for this device while human handoff is pending. Wait for the person's response." The probe's gesture count did not change. The handoff later returned `notCompleted` again |
| `tap` after that handoff had returned | `dispatched`, and recorded by the probe as its next gesture: the pause ended with the request |

The pause on a device's mutations while a handoff is pending is therefore shown on a phone, from a real host. An acknowledged form is not. `request_handoff` ran four times that evening and returned `notCompleted` each time. The host's own log shows it received each form request (`mode=form fields=["completed"]`) and answered `action=accept` with the `completed` field after 11, 48, 89 and 6 seconds. The owner at first reported seeing no form, then that they had typed their answer ("the action was done") at the host's prompt: the form is drawn inline where messages are normally typed, and submitting it with Enter leaves its checkbox at the default, unticked. The server did what it should with that, reporting `notCompleted` and no acknowledgement. The host has no hook that answers forms, and was Claude Code 2.1.326.

On the phone the step itself was done both times it was asked for: the owner chose "Permitir", and the probe read `authorized` afterwards. A check without any handoff, by screenshot at 2 and 22 seconds after `press --id probe.permission.request` on a fresh install, showed that the prompt appears and stays until someone answers it.

After these runs the tool result gained a line describing the form answer (its action, and each field's name and type, with the value only for Booleans and numbers), and the checkbox was replaced by one required choice, `done` or `not done`, with no default.

| Step, with that form and the server reconnected | Observed |
| --- | --- |
| Fresh install, `press --id probe.permission.request`, `tree` | The prompt on the phone, confirmed from the tree before asking |
| `request_handoff`; the owner chose "Permitir" on the phone and `done` in the form | `status: acknowledged`, `humanAcknowledged: true`, `mechanism: mcp-form`, after 62 s. The host log read `action=accept … fields=["outcome"]` |
| Screenshot and `tree` afterwards | The probe app, no prompt, `{"requests":1,"status":"authorized","v":1}` |

That is one MCP handoff acknowledged by a person and confirmed on the device. The describing line did not reach the model in this host, which showed only the structured result; it is now in the structured result as `formAnswer` as well.

The owner then showed how Claude Code had drawn that form: a paragraph of text, the field as "not set" with "This field is required" in red, and the host's own Accept and Decline underneath. They judged it unacceptable and very confusing, since it asks the same thing twice. The form now has no fields and three short lines, and the host's buttons are the answer ([handoff](handoff.md#mcp-flow)). With the server reconnected on that form:

| Step | Observed |
| --- | --- |
| Fresh install, `press --id probe.permission.request`, screenshot and `tree` | The prompt on the phone, confirmed by both before asking |
| `request_handoff 'Answer the notification prompt on the phone: Permitir or No permitir.'`; the owner chose "Permitir" on the phone and pressed Accept in the host | `status: acknowledged`, `humanAcknowledged: true`, after 86 s, with `formAnswer` "action accept; empty content". The host log read `mode=form fields=[]` for the request and the answer |
| Screenshot and `tree` afterwards | The probe app, no prompt, `{"requests":1,"status":"authorized","v":1}` |
| `request_handoff` with nothing to do on the phone; the owner pressed Decline | `status: declined`, `humanAcknowledged: false`, an error result, with "action decline; no content" |

So the form with no fields was answered by a person both ways, and the acknowledged one was confirmed on the device. Cancel (Esc) was not run from a host. Later: it was, on 2026-11-18 ([the last handoff runs](#the-last-handoff-runs-on-the-phone)).

The owner still found that form's wording wrong: what it says does not agree with the action. The phone asks one question, "Probe quiere enviarte notificaciones", answered "No permitir" or "Permitir"; the form asked another, whether the step was done, with the host's fixed buttons Accept and Decline, under a step that named both phone answers. Accept reads as "Permitir" and Decline as "No permitir", so someone who refused the permission would press Decline and report a finished step as not done. The text was rewritten to put the form's own question first and to say what each button means for it ([handoff](handoff.md#mcp-flow)). With that wording and the server reconnected, a fresh prompt (confirmed by screenshot and `tree`) and `request_handoff 'Answer the notification prompt on the phone.'`: the owner chose "Permitir" and pressed Accept; `status: acknowledged`, `formAnswer` "action accept; empty content"; afterwards the screenshot and `tree` showed the probe with no prompt and `status: authorized`. The owner's screenshot of that form showed what the host does with it: the title "MCP server "manzanero" requests your input", then only the first three lines of the message (the question, a blank line and the step) followed by "… (+4 more lines)", then Accept and Decline with "Esc to cancel · ↑/↓ to navigate". The lines saying what the buttons mean were folded away. The message was cut to three lines with no blank ones, button meanings first ([handoff](handoff.md#mcp-flow)). 

With the three-line message and the server reconnected, the case the wording is for was run: a fresh prompt (confirmed by screenshot and `tree`), `request_handoff 'Answer the notification prompt on the phone.'`, and the owner chose "No permitir" on the phone and Accept in the host. `status: acknowledged`, `formAnswer` "action accept; empty content"; afterwards the screenshot and `tree` showed the probe with no prompt and `{"requests":1,"status":"denied","v":1}`. A refusal on the device was reported as a finished step, as it should be. How the host drew the three-line message was not captured.

### Handoff that watches the device

**2026-11-17, night**, same phone and host, after the owner asked whether there was no other way than a form. `handoff --until` ([guide](handoff.md#watching-the-device---until)) was run from a non-interactive shell, which the form-based handoff refuses.

| Command | Observed |
| --- | --- |
| `handoff 'Unlock the phone' 20 --until unlocked`, phone already unlocked | Exit 0 at once: `status: observed`, `alreadyMet: true`, `polls: 1`, `verified: true`, observation `displayPower: on`, `passcodeRequired: false` |
| `handoff 'Answer the prompt' 20 --until gone --label Permitir`, no prompt on screen | Exit 0 at once: `observed`, `alreadyMet: true`, observation reason `absent` |
| Fresh install, `press --id probe.permission.request`, `tree` (prompt present), then `handoff 'Answer the notification prompt on the phone' 180 --until gone --label Permitir`; the owner answered on the phone and touched nothing on the Mac | The request was printed on stderr with "Watching the device for: the element with label 'Permitir' gone". Exit 0 after 21 s and 4 looks: `status: observed`, `mechanism: device-observation`, `alreadyMet: false`, `verified: true` |
| Screenshot and `tree` afterwards | The probe app, no prompt, `{"requests":1,"status":"denied","v":1}` |

Not run on the phone: a timeout, `unlocked` and `paired` from the locked or unpaired state, the typed answers while watching, a watch longer than 21 s, the MCP `until` field from a host, and a simulator. Unit tests cover the loop with injected device readings: a condition met on the third look, an already-met one, a timeout, a failed look, the pause refusing a tap, and cancellation. Later: every item of that list ran, in the two sections that follow.

### Handoff watch: a timeout on the phone and runs on a simulator

**2026-11-17, 23:08**, the same phone, asleep and locked (`displayPower: off`, `passcodeRequired: true`), and one iPhone 17e simulator (iOS 27.2) with the probe app, all from a non-interactive shell.

| Command | Observed |
| --- | --- |
| Phone: `handoff 'Unlock the phone' 180 --until unlocked`; nobody touched the phone | Exit 1 after 182 s and 63 looks: `status: timedOut`, `alreadyMet: false`, `verified: false`, last observation `displayPower: off`, `passcodeRequired: true`. This is the timeout and a three-minute watch; the unlock itself did not happen |
| Simulator, a notification prompt on screen (screenshot): `handoff 'Answer the notification prompt' 60 --until gone --label Allow`, and 9 s later a second process ran `press --label Allow` | The press was accepted (the pause is per process). Exit 0 after 11 s and 3 looks: `status: observed`, `verified: true`, observation reason `absent` |
| Simulator: `handoff … --until value --id probe.text.field --value hola`, the field already holding `hola` | Exit 0 at once: `alreadyMet: true`, `polls: 1` |
| Simulator: the same for `adios`, and 7 s later a second process ran `set-value --id probe.text.field adios` | Exit 0 after 8 s and 2 looks: `observed`, `verified: true` |
| Simulator: `handoff … 60 --until value --id probe.text.value --value hola` while the prompt covered the app | `timedOut` after 65 s and 13 looks, observation `no-match` in the prompt's process (SpringBoard): the watch reads the frontmost application, so an element of the app under a prompt is not seen. Also, `probe.text.value` holds JSON, not the text; the field itself is `probe.text.field` |

The request line printed for a `value` condition ended in a bare "value"; it now names the awaited value ("the element with identifier 'probe.text.field' value 'nunca'"), and the plan's `until` carries it.

The runs that needed the owner at the phone followed within the hour, below.

### The last handoff runs on the phone

**2026-11-17, 23:54 to 2026-11-18, 00:02**, the same phone with the owner at it, and Claude Code as the MCP host with the server reconnected after the rebuild. Each row was followed by a look at the phone (`readiness`, a screenshot or a tree).

| Step | Observed |
| --- | --- |
| Phone asleep and locked. `handoff 'Unlock the phone' 180 --until unlocked` from a non-interactive shell; the owner unlocked it | Exit 0 after 73 s and 26 looks: `status: observed`, `alreadyMet: false`, `verified: true`, observation `displayPower: on`, `passcodeRequired: false` |
| `press_button lock` (receipt `passcodeRequired: false`; `readiness` a moment later: display off, passcode required), then MCP `request_handoff` with `until: unlocked`, `timeout_seconds: 180`; the owner unlocked it | No form. `observed` after 24 s and 9 looks, `mechanism: device-observation` |
| MCP `request_handoff` without `until`, asking for Esc on the form | First try: the host returned `action accept; empty content` and the result was `acknowledged`, so Enter or Accept was pressed. Second try: `action cancel; no content`, `status: cancelled`, `humanAcknowledged: false`, returned as an error result |
| Settings › Face ID y código (`press --id com.apple.settings.passcodeAndBiometrics`): the passcode gate. `tree` | The gate is in the tree: `Passcode field` ("Campo del código"), the keypad's ten digits by identifier and label, `Delete`, `Cancel`. Nothing was pressed on it |
| MCP `request_handoff 'Enter your passcode on the phone'` with `until: gone`, `by: identifier`, `text: Passcode field`; the owner entered the passcode | `observed` after 14 s and 3 looks, observation reason `absent`; the tree then showed the page behind the gate ("Configurar Face ID", "Desbloquear el iPhone") |
| In the owner's own terminal: `handoff 'Type decline here' 120 --until visible --id no.such.element`, and `decline` typed | `status: declined` after 17 s and 3 looks, `mechanism: terminal`, `verified: false`, last observation `no-match` |
| With the owner's permission, `devicectl manage unpair`; `readiness`: `disconnected`, `unpaired`. Then `handoff 'Pair the phone: tap Trust and enter the passcode' 300 --until paired`; the owner paired it again | Exit 0 after 50 s and 23 looks: `observed`, observation `connected`, `paired`. A `tree` right after read Settings |

So every way a handoff ends has now run on the phone with a person: the device observed (`unlocked`, `paired`, an element gone), a timeout, a typed decline while watching, and from the host Accept, Decline and Cancel. The passcode gate stands in for a biometric prompt, which this phone cannot raise without Face ID set up.

Not run, and not planned on this setup: a second MCP host (only Claude Code is configured here) and a real Face ID or purchase prompt. Still untested: whether a host removes a form the server withdraws, which is why a watching handoff shows none.

### Selector by value, detect-layout index, masked read-back and the display note

**2026-11-17, night.** Built that evening and run on the same iPhone 17e simulator with the probe app, except the last row.

| Command | Observed |
| --- | --- |
| `wait --with-value adios --timeout 3` | `condition-met`, selector `by: value`, one match |
| `set-value --with-value adios 'por valor'` | `acknowledged`, `valueMatches: true`; the target was `probe.text.field` |
| `press --with-value 'por valor'` | `accepted` |
| `detect-layout --id probe.text.field --index 1` | Ran as without the index; the plan's selector carries `index: 1`, restore confirmed |
| `detect-layout --id probe.text.field --index 2` | Refused, nothing sent: "The tree has 1 elements with identifier 'probe.text.field'; --index 2 is beyond them" |
| Phone, asleep: `screenshot` | Succeeded as before, and the receipt now carries `displayPower: off` and a `displayNote` saying the image is probably black |

Run on the iPhone 13 mini on 2026-11-22, with the human owner's word: the Settings search field, which has neither label nor identifier and only the placeholder "Buscar" as its value, was pressed with `press --with-value Buscar` (selector `by: value`) and `wait --with-value Buscar --until focused` met its condition; a screenshot showed the field focused with the keyboard up. The search was closed by a tap on its unlabelled close button (Escape did not close it). In Settings › Wi‑Fi › Otra…, `set-value --id Contraseña` with a 10-character dummy value was `acknowledged` with `valueMatches: null`, `readBack: masked`, `maskedLengthMatches: true` (30 UTF-8 bytes of bullets read back); the sheet was cancelled and the phone stayed on its network. Later that day, `press` on an element wider than the display ran too, with the probe's zooming web page (`-ProbeWebZoom YES`): the field, 271 points wide before, was focused by a press and iOS zoomed in until it was 361.2 points wide from x 56.0, its right edge 42 points past the 375-point display and its centre on it; a second `press --label "Web field" --index 2` in that state was `accepted` with that frame, and `type zoom` then put "zoom" in the field (screenshot, and the native label `Last: web-field:zoom`). Still unit tests only: a selector action with the PID of the process hosting the display-centre one, and the categories of errors that are not this tool's own.

### An offer that asks for RTCP feedback

**2026-11-17, about 23:50**, the same phone, woken to its lock screen (`wake`: `awake-locked`), macOS 27.2.1, AVConference 2260.15.1. The one experiment the owner approved, to decide whether keyframe requests are worth building.

What was found first, on the Mac only: Apple's `AVCMediaStreamNegotiator` builds the whole offer and has no option for feedback. The request is a flag on its local configuration (`-[VCMediaNegotiatorLocalConfiguration setAllowRTCPFB:]`, reached as `mediaNegotiator.localSettings`), off by default for screen sharing, and it is field 5.2 of the offer's media blob. The blob is cached when the negotiator is created, so it has to be regenerated (`negotiationData`, `setMediaBlobCompressed:`) for the flag to reach the offer. In a loopback between two negotiators on the Mac the negotiated value was the AND of the two sides, and a stock answerer declined an asking offer. The offers that AXe and idevice reproduce from Apple's own client also leave the flag off.

A scratch build set the flag and regenerated the blob before `createOffer` when an environment variable was given. Two recordings, one after the other:

| Command | Observed |
| --- | --- |
| `record <new>.mp4 5 --backend coredevice`, stock offer | `recorded`, `frameDecoded: true`, 89 source frames, 5 receiver reports sent, 5 sender reports observed, `rtcp.negotiatedFeedback: disabled`. This is the second reading of the stock offer |
| The same with the asking offer | `recorded`, `frameDecoded: true`, 87 source frames, 5 and 5 reports, cleanup as before, `rtcp.negotiatedFeedback: disabled` |

So the phone was asked and did not agree, and asking did no harm to the stream. The offer's bytes were not dumped in that run; that it carried the flag rests on the loopback with the same calls and on every interface guard passing. One phone, one iOS version.

Decision that follows, as the owner set it beforehand: keyframe requests over negotiated feedback (PLI/FIR) are dropped, and recovery is to be a restart of the stream. The scratch change was not kept: it added four private interfaces for a result that is now known.

### Safari on a simulator, by selector

2026-11-21, evening, `manzanero-research-phone` (iPhone 17, iOS 27.2), Xcode 27.2. A test page typed into Safari's address bar as a `data:` URL (no website): a heading "Ready", a field labelled Email and a Send button whose click writes "Clicked " and the field's text into the heading. `simctl openurl` refuses a `data:` URL (LSApplicationWorkspaceErrorDomain error 115). The page's process was 85695 (`WebViewProcessID` in Safari's tree), Safari's 85662.

Before the change:

| Command | Result |
| --- | --- |
| `tree` | Safari only: no page element |
| `tree --pid 85695` | The page: Ready, Email, Send. Send's frame 8, 188, 97 × 69, where the screenshot draws it |
| `wait --label Send --pid 85695` | `condition-met` |
| `press --label Send`, `set-value --label Email …` | Refused before input: no match in the snapshot |
| the same with `--pid 85695` | Refused before input: "requested PID differs from foreground application process and does not host it" |
| `tap` on the field, `type 'tap ok'`, `tap` on Send | The heading read "Clicked tap ok": the page could be used by points all along |

After it (`acceptsShownProcess` on the simulator platform):

| Command | Result |
| --- | --- |
| `set-value --label Email web-1 --pid 85695` | `acknowledged`, `valueMatches: false`, the field unchanged, as with a web input on the phone |
| the field changed to "zz" by taps and keys, then `press --label Send --pid 85695` | `accepted`, `selection: explicit-pid-shown-by-frontmost-or-centre-hit`, `hostPid: 85662`; the heading went from "Clicked tap ok" to "Clicked zz" |

No offset was needed for the hit: Safari's remote element spans the whole screen from 0, 0. Not run: a web view that does not start at the screen's corner (an app's `WKWebView` under a bar), `scroll` on a page, and Safari on the phone, which has only been seen in Chrome.

### Web content on the phone

**2026-11-17, later the same day**, same phone and host, Chrome with public test pages. This follows the web form failure in the session above.

**Cause.** With the failure made to say what it found, three reads in a row reported: asked for application pid 4802, and the snapshot's root was pid 3919 (Chrome), not an application element, class `AXRemoteElement`, with one child. The first read after the page loaded had selected Chrome itself and succeeded with 135 nodes ending at `WKContentView`; from the second read on, the display centre belonged to the content process. So the page's tree was arriving all along, under the browser's remote element, and the normalizer refused its root. It now accepts that shape ([web content](direct-accessibility.md#web-content)).

| Command, after the change | Observed |
| --- | --- |
| `tree` on the login form page | Exit 0, `application.pid` the content process, 32 nodes: the remote element, `WKAccessibilityWebPageObject`, then the page's headings, text, both fields and the button, with frames |
| `set-value --label Username tomsmith` | Refused as ambiguous, listing three matches (the HTML label, the field and the label's text); no web node carries an identifier. Nothing sent |
| `wait --label '<icon> Login' --until visible`, then `press` with the same label | `condition-met`; press `accepted`, and the page reloaded with its "Your username is invalid!" banner. The label begins with a private-use icon character (U+F090), so `' Login'` alone has no match |
| `tree` right after that reload | Chrome's own tree again (135 nodes): the first read after a page load selected the browser |
| A search page: `tree` twice | Both selected the content process, 131 nodes; almost every link's label appears twice, on the link and on its text |
| `set-value --label 'Buscar con DuckDuckGo' 'prueba ñ€ 日本'` on its search input | `acknowledged`, `valueMatches: false`: the input kept its placeholder. Web inputs report themselves settable but did not take the value |
| `press` with that label, then `type --layout spanish-iso 'prueba ñ'` | The field took focus with the keyboard up; the tree read the input's value as `prueba ñ` and the screenshot showed it |

**`--index`, added the same afternoon** ([guide](direct-accessibility.md#current-guarded-native-press)), on the login form again:

| Command | Observed |
| --- | --- |
| `wait --label 'Login Page' --index 1` | `condition-met`; the receipt's selector carries `index: 1` |
| `press --label Username` | Refused as before, the message now ending "or by its position in this list with --index" |
| `press --label Username --index 2`, then `type --layout spanish-iso tomsmith` | `accepted` on the 343×33 field, the second of the three matches; the tree read the field's value as `tomsmith` |
| `press --label Password --index 2` with the keyboard up | Refused, nothing sent: "target is not wholly inside the primary display". Focusing the first field had zoomed the page, and the Password field was 392 points wide on a 375-point display |
| `scroll --label Password --index 2` | `nativeResult: true`, `postcondition-failed` (the target's visible state did not hold); the page moved |
| `tap` at the Password field's frame from a fresh tree, `type` the page's published test password, `press` the Login button | The tree read 20 bullets in the field; the site answered "You logged into a secure area!" |

Two earlier attempts in this run failed through the operator's own script, not the tool: one went on typing after the refused press, and one tapped at a frame read before the scroll had moved the page. Chrome's password manager showed a breach notice for the published test password, dismissed with "Entendido". `--index` has not been run on a simulator or through MCP on a device; unit tests cover both parsers. Later: `detect-layout --index` ran on a simulator, on a field without a duplicate ([record](#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note)).

Not shown: Safari, an app's own `WKWebView`, a page with frames, and whether the first read after a load always selects the browser. One of the two presses reported its subscription stop unconfirmed (3 ms, one cleanup frame), the third such report of the day among about thirty selector commands; the others, including failures, were acknowledged.

### First look at a physical Apple TV

On 2026-11-18, one Apple TV 4K (3rd generation, `AppleTV14,1`), paired over the network and asleep at the start, with the build from `main`, macOS 27.2.1, Xcode 27.2 (27B52), `devicectl` 651.32. The tvOS version was not recorded. Only commands meant to observe were run; no input was sent.
**The session switched the Apple TV on, and the television connected to it.** The owner saw both come on. Which command did it is not known: `readiness`, `apps` and `media-status` ran first, then `screenshot`, which returned a black image, then a refused `tree`, then `screen ocr`, whose capture seconds later showed the Home Screen. So on an Apple TV these commands are not free of effect, and a television may follow the Apple TV over HDMI.

| Command | Result |
| --- | --- |
| `readiness` | Paired, developer mode enabled, services available. `displayPower: off`, before the Home Screen was captured and again after it |
| `apps`, `reports list`, `media-status` | Answered (`media-status`: not running, no session) |
| `screenshot` | 3840 × 2160. The first image was black; the receipt's note that the display was off was right for it |
| `screen ocr` | Captured the Home Screen and read the app names on it |
| `tree` | Refused twice as display off, the second time with the Home Screen showing; no point query sent |
| `remote`, `displays` | Refused before any contact: simulators only |
| `wake`, `button home`, `key up`, `tap` with `--dry-run` | Each printed a plan for a physical device; none was sent |

Found: the display state the tool reads says `off` on this Apple TV while it is drawing its Home Screen, so `tree` is refused, the screenshot note would be wrong for a second capture, and touch, which is gated on the same reading, is expected to be refused too. `wake`'s plan presses the side button, which an Apple TV does not have; it was not run.

Later the same day, with the owner's word and the Apple TV still on, showing a screen saver:

| Command | Result, each read from a screenshot afterwards |
| --- | --- |
| `key right` over the screen saver | `dispatched`; the screen saver stayed. Whether the key arrived is not known |
| `button home` | `dispatched`; the screen saver gave way to the Home Screen |
| `key right` | Focus moved one app to the right |
| `key left` | Focus moved back to the app it started on |
| `tree` | Still refused as display off |

Keys and buttons are not gated on the display reading, so they were sent while `readiness` still said `displayPower: off`. The receipts say `verified: false`; the effects above are from the screenshots.

Then the cause was read and changed: the Apple TV's one display is `type: external` (`TVOut`, 3840 × 2160, point scale 1) and reports `backlightState: off` while it draws. With the display check changed to accept an external display, and `remote` opened to a physical Apple TV ([guide](other-families.md#a-physical-apple-tv)), on the same device:

| Command | Result |
| --- | --- |
| `readiness`, `screenshot` | `displayPower: external`, status `observed`, no note about a black image |
| `tree` with the centre hit test | Refused by the device (error 8) |
| `tree` asking for the frontmost application | The screen saver's process (`PineBoard`), then the Home Screen (`HeadBoard`, 233 nodes) with frames in 1920 × 1080 points and the focused app marked |
| `screen` | Method `accessibility` |
| `remote right`, `remote left`, each followed by `wait --until focused` | Focus on the next app and back; both waits met |
| `press --label Settings` | Settings opened; its tree marked the focused row |
| `remote menu` as consumer usage 0x46, and `remote play-pause` as 0xCD | The transport failed after the press was attempted, each time; the device was quarantined, inspected by tree, and cleared |
| `key escape` | Settings went back to the Home Screen |
| `remote menu` as Escape | In Music, opened the sidebar |
| `remote down`, `remote select` | Opened Music's Sing page, the app under focus |
| `remote home`, `remote up` twice | Home Screen, and focus back on the app it started on, read from the tree |
| `tap` | Refused: no touch screen |
| `wake` | `external-display`, nothing pressed, exit 1 |

One of these was the operator's mistake, not the tool's: `remote select` was sent without a fresh read of the focus, which was on Sing and not on Settings as assumed, so an app the owner had not named was opened. It was left with `remote home`.

Later, with the external display let through for capture once: `frames --count 3` saved three images (first frame after 6.4 s) and `record --backend coredevice` a 5-second H.264 movie, each 3168 × 1792 and each a black rectangle on grey, while `screen ocr` read the Home Screen. Both commands refuse an Apple TV since. That rectangle was the screen, dark, in the top-left of a larger frame ([record of 2026-11-20](#the-apple-tvs-video-stream-read-packet-by-packet)). The [tvOS probe](probe-app.md#tvos-probe) was written and run on a simulator the same day; it is not on the device.

In the afternoon the owner ran the tvOS probe onto the device from Xcode. Six seconds after that run's connection was released (14:05:25), `remotepairingd`'s heartbeat to the Apple TV began to fail at once (`failed after 0ms`) and every query timed out, for twenty minutes, while the network tunnel still carried packets and the Mac listed the device as connected. With the owner's word both services were restarted and the first query answered. Then, against the probe:

| Command | The probe's record afterwards |
| --- | --- |
| `remote play-pause` (Space) | `play-pause` |
| `remote select` with focus on the text field | Nothing recorded: tvOS opened its keyboard, and the arrows and Menu that followed went to it |
| `remote up` | `up`; focus on Button B |
| `remote select` | `select:b` |
| `remote left`, twice | `left` each time; focus on Button A |
| `remote right` | `right`; focus on Button B |
| `remote menu` (Escape) | `menu`, on the second try: the first call timed out before anything was sent |
| `set-value --id probe.tv.text.field 'héllo tv'` | `acknowledged`; the field and the app's bound text both read `héllo tv` |
| `remote home` | The Home Screen |

Later: `type ' abc'` with the probe's field focused and the keyboard closed made the app's text `héllo tv abc`. In Settings › Accessibility, opened by `press --label`, the tree held only the rows on screen (each as a visible cell plus inner texts marked not visible), so there was nothing off screen to scroll to; `scroll --label Motion` on a row already shown answered `postcondition-verified`, `nativeResult: false`, and the screenshot was unchanged. No setting was pressed.

Power, from 15:13: `button lock` with the screen saver in front brought the Home Screen; again, with the Home Screen in front, it opened Control Centre with Power Off in focus (read from a screenshot and seen by the human owner in Device Hub; the tree gave `PineBoard` and no nodes). At 16:17:16 `remote select` there put the device to sleep: from 16:17:22 `screenshot` failed with "Display reports zero-sized native size", while `readiness` (16:17:19) and the display query (16:17:38) answered as if awake and did not wake it.

The connection went stale twice more: at 15:14:06, as a `tree` started with Control Centre open, and at 16:17:39, as a `tree` started on the sleeping device. Each time `remoted` logged "Device connection interrupted" with no "Handshake complete" after it, then "Heartbeat failed: not connected" every 30 seconds. The same interruption, followed by a handshake, was logged for the iPhone 13 mini during two of five `tree` runs, one of them with a random peer identity in manzanero's directory handshake (a scratch change, not kept), and in the second before one of them only `devicectl` had been active.
On the tvOS 27.2 simulator the same afternoon, with a forty-row list added to the probe: the tree held rows 1 to 13; `scroll --id probe.tv.row.13` returned `nativeResult: true`, the row moved from y 1020 to 954 and row 14 joined the tree, but the status was `postcondition-failed` ("target centre hit is another native element"), five checks 250 ms apart included. The element that answered the hit test belonged to `PineBoard`, not to the probe. With the hit test left out on an Apple TV, rows 18, 19 and 20 each scrolled into view as `postcondition-verified`, and `press --id probe.tv.row.20` was recorded as `select:row-20`. `button lock` on the simulator did not open Control Centre, so the power sequence is a hardware matter.

`scroll --search`, built that evening, on the same simulator with the probe relaunched and its list at the top (rows 1 to 13 in the tree): `scroll --id probe.tv.row.35` alone failed with no match; with `--search 40` it took 22 steps in about 8 seconds and ended `postcondition-verified` with row 35 at y 954, and `press --id probe.tv.row.35` was recorded as `select:row-35`. `scroll --id probe.tv.row.99 --search 60` stopped after 30 steps with "the list stopped moving". Two faults were found and fixed on the way: with a 40-step limit the first version reached only row 17, because every few steps the lowest element was the list's own container, 3200 points tall, and scrolling to it put the list back at the top; and a search started straight after launch found no rows, because the list was not in the tree yet (`wait --id probe.tv.row.1` first).

More simulator runs that evening, against the probe. On the 1080p simulator, after the hit test was left out: `set-value --id probe.tv.text.field 'héllo sim'` was `acknowledged` with `valueMatches: true` and the app's bound text agreed, but it left tvOS's full-screen keyboard in front, so `wait` answered `not-visible` and `press` was refused until `remote menu` closed it; then `type ' abc'`, `wait --until value`, `wait --until focused` (correctly `not-focused` for an element without focus), `press --id probe.tv.button.c` (recorded `select:c`), `screen` (method `accessibility`) and a 3-second `record` all worked. A real stdio MCP session answered `press_remote` twice, once without `platform` and once with `platform: simulator`, and `scroll_to_element` with `search: 20` (7 steps, `postcondition-verified`); the probe recorded `select:b`. Calls written to the server just before its input closed got no answer: only `initialize` did.

A new simulator, `manzanero-research-tv-4k` (`Apple TV 4K (3rd generation)`, tvOS 27.2), reported its display as the device had: `TVOut`, external, 3840 × 2160 pixels, point scale 1, with a tree 1920 × 1080 points. `displays` listed 3840 × 2160 points there, now corrected to 1920 × 1080 at scale 2. On it `press`, `scroll --search 30` (17 steps to row 30), `press` on that row (recorded `select:row-30`) and `remote` worked. `handoff --until focused --id probe.tv.button.b` ended as `observed` 5 seconds in, when a second process sent `remote right`; with the condition already true it returned at once, and with a 4-second limit and no change it ended `timedOut` with exit 1.

A held remote button, on the 1080p simulator: with the hold raised to 1.5 s in a scratch build, `home` opened Control Centre (OCR read Power Off, Audio, Ethernet, Do Not Disturb, Sleep Timer), while `menu` and `play-pause` held as long showed Settings unchanged. Built as `remote --hold`: `remote home --hold 1.5` returned `holdMilliseconds: 1500` and opened Control Centre again; the tree then gave `PineBoard` with 24 nodes and no item; `remote menu` closed it. `--hold` on `select`, a hold of 9 seconds, and a hold with `--device` were each refused before anything was sent.

`--index` among real duplicates, on the same simulator, with two buttons labelled `Twin` added to the probe: `press --label Twin` was refused as ambiguous and listed both, with their identifiers and frames; `--index 2` and `--index 1` were recorded as `select:twin-2` and `select:twin-1`; `--index 3` was refused as beyond the two matches; `wait --label Twin --index 2` and `scroll --label Twin --index 2` both succeeded. Through a real MCP session, `press_element` by label answered `ambiguous-or-missing-target` without `index` and pressed the second with `index: 2`.

`batch`, built that evening, on the same simulator against the probe. `batch '[["remote","right"],["wait","--id","probe.tv.button.b","--until","focused","--timeout","3"],["remote","select"],["scroll","--id","probe.tv.row.20","--search","20"],["press","--id","probe.tv.row.20"]]'` completed all five steps in about six seconds, exit 0, and the probe's last record was `select:row-20`. A batch of `press` on Button A, a `wait` for an identifier that does not exist (1-second limit) and `press` on Button C exited 1 with `failedStep: 2`, the wait's `no-match`, and the third step in `notRun`; the probe's last record stayed `select:a`. Refused before anything ran: an unknown remote button in the second step, a step carrying `--simulator`, `keyboard-layouts` as a step, and a batch inside a batch. With `--dry-run` three steps returned their plans and `status: planned`. Through a real MCP session `run_batch` completed a press by label with `--index 2` followed by a value wait, and answered a batch whose first step named a missing element with `status: failed`, `failedStep: 1`.

Not shown: a scroll that moves a list on the physical device, which command wakes the device, whether the television also switches off with it, and the Mac's second Apple TV.

### The Apple TV 4K: what wakes it, and why its connection goes stale

On the night of 2026-11-18, the Apple TV 4K (3rd generation, tvOS 27.2) over the network, macOS 27.2.1, Xcode 27.2, the build from `main`. The human owner watched the television.

**What wakes it.** At the start `readiness` answered `prerequisitesPresent` with `displayPower: external`, and `screenshot` failed with "Display reports zero-sized native size" (error 25005): asleep. One `remote home`, alone, at 22:03:22 was `dispatched`; screenshots at 22:03:26, :32, :39 and :45 all succeeded and showed the Home Screen. The human owner saw the television come on with the Apple TV. So a Home press wakes the device, and the television follows it; `readiness` and a failed `screenshot` before it did not.

**The probe.** `xcodebuild build -scheme ProbeTV -destination 'generic/platform=tvOS'` signed with what was already on the Mac, with no `-allowProvisioningUpdates`; `install` and `launch` succeeded. `wait --until visible --id probe.tv.row.1` met its condition, and the tree held the probe's rows 1 to 13, columns 1 to 12 and the Hold element. `scroll --id probe.tv.row.13` answered `nativeResult: true`, `postcondition-verified`.

**Then the connection went stale**, as it had three times earlier that day. The next command, `scroll --id probe.tv.row.35 --search 80`, and every command after it for six minutes failed at its first display query ("Command timeout of 10.0 seconds exceeded"); `readiness` said `connected`, `paired`, and "displaysUnavailable: the Apple query failed"; `devicectl list devices` said `connected`. Meanwhile the television showed the Snoopy screen saver, so the Apple TV itself was running normally.

What the logs of `remoted`, `remotepairingd` and `CoreDeviceService` show for 22:06:30 to 22:09:00, read before anything was restarted:

| Time | Line |
| --- | --- |
| 22:06:45.807 | `remoted`: `device_get_service` for a `manzanero` process |
| 22:06:45.950 | `remoted`: `coredevice-1255> Device connection interrupted` |
| 22:06:46.012 | `remoted`: `Handshake complete.` (62 ms later) |
| 22:06:49.105 | `Device connection interrupted`, again just after a `manzanero` process asked for a service |
| 22:06:50.220 | `Handshake complete.` (1.115 s later) |
| 22:07:02.357 | `remotepairingd`: `tunnel-6: Canceling connection, errorMessage: 'No active usage assertions'`; a new tunnel and `coredevice-1256` follow at 22:07:05, `Handshake complete.` at 22:07:05.842 |
| 22:07:06.833 | `remotepairingd`: `Fulfilling assertion … for process … ("manzanero")` (the plain `scroll`) |
| 22:07:07.025 | `Device connection interrupted`, then `client connecting to remote remoted` |
| 22:07:08.140 | `Handshake complete.` (1.115 s later) |
| 22:07:11.809 | `Fulfilling assertion … ("manzanero")` (the `scroll --search`) |
| 22:07:11.993 | `Device connection interrupted`, then `client connecting to remote remoted` |
| after that | No `Handshake complete.` at all. `RSD Heartbeat … failed after 1ms` at 22:07:36, and after 0 ms every 30 s from then on. The tunnel's own counters kept rising (`tunnel-7 … packets in/out=1192/571`, then `1506/727`) |

So each command of the tool that opens its own connection to the device's service directory (the accessibility route: `tree`, `wait`, `press`, `scroll`, `set-value`) is followed within 0.2 s by `remoted` losing its connection to the device. `remoted` reconnects at once; three times its handshake finished, once at the first try and twice 1.115 s later, which reads as one retry a second after a failed first try. The fourth time, with the tool's connection held open for a search, no handshake ever finished and `remoted` did not try again. The tunnel was alive throughout. Read together with the phone's log relay run, where the tool's directory connection "was no longer active 5 s after its handshake", the device appears to keep one service-directory peer per tunnel: the tool's connection displaces `remoted`'s, and `remoted`'s reconnect displaces the tool's. That the device allows only one peer is an inference from these timings, not something the device said.

**It cleared by itself, with no restart.** The human owner said that Device Hub could still send keys to the Apple TV, that this was a fault of the tool and not of the services, and that nothing was to be restarted. In the stale state the tool's own `remote up`, `key down` and `button home` were each `dispatched` in 1 to 2 s: input does not use the service directory. The log then showed how the state ends: `Heartbeat failed: not connected` every 30 s until 22:16:06; at 22:16:28 `tunnel-7: Canceling connection, errorMessage: 'No active usage assertions'`, about two and a half minutes after the tool's last command; and at 22:19:03, on the next command, a new connection (`coredevice-1257`) with `Handshake complete.` and a heartbeat answered in 9 ms. From then `readiness`, `screenshot` (the probe on screen) and `apps` (35 applications) answered. So the stale connection lasts as long as its tunnel, the tunnel lasts while any process holds a usage assertion on it, and every failed retry of the tool takes one: retrying kept it stale, and leaving the device alone for a few minutes cleared it. Apple's `remotectl dumpstate` shows the state without touching the device: the stale connection reads `State: attached` with `No connect() results`, a healthy one `State: connected (connectable)`.

**Closing the tool's directory connection early did not prevent it.** With the directory closed as soon as the accessibility socket was connected, at 22:21 to 22:22: `scroll --id probe.tv.row.13` verified; `scroll --id probe.tv.row.35 --search 80` verified after 8 steps, the first search on the device; `press --id probe.tv.row.35` was `accepted`; then the next command timed out as before. The log had the detail the first pass lacked: each time, `remoted` logs `Receive failed with error "Connection reset by peer"` and `Connection Disconnected (… error [54: Connection reset by peer])` on its two connections to the device's directory port, 0.18 to 0.28 s after `Fulfilling assertion … ("manzanero")`. The device resets `remoted`'s connections when the tool's handshake arrives. Three reconnects finished (0.07 s, 1.08 s and 1.23 s later); the one at 22:21:59.549 did not, and `Heartbeat failed: not connected` followed at 22:22:04.

**A restart, and the rest of the runs.** This time the state did not clear: at 22:57, eighteen minutes after the last command, `remotectl dumpstate` still read `State: attached`. `remotepairingd` listed one standing assertion from `CoreDeviceService` on the tunnel; Device Hub and Xcode were open. At 23:05:23, on the human owner's word, `killall remotepairingd CoreDeviceService`; eight seconds later `readiness` answered and both connections read `connected (connectable)`.

An identity of the tool's own in the directory handshake (a fresh UUID in place of the Mac's), together with the early close, was then tried for eleven accessibility commands: the log showed two resets per command instead of one, twenty `Device connection interrupted` in forty seconds, and five of the tool's commands failed with "Accessibility socket send: Broken pipe (32)". Both changes were reverted. `docs/other-families.md` already recorded that another identity had not helped on the phone.

With the committed route again, checking `remotectl dumpstate` before each command:

| Command | Result |
| --- | --- |
| `scroll --id probe.tv.row.35 --search 80` | `postcondition-verified`, 8 steps (and 0 steps when the row was already in the tree) |
| `scroll --id probe.tv.col.28 --search 80 --toward right` | verified, 16 steps |
| `scroll --id probe.tv.col.1 --search 80 --toward left` | verified, 18 steps |
| `scroll --id probe.tv.row.30 --search 80` | verified, 8 steps |
| `scroll --id probe.tv.row.1 --search 80 --toward up` | 23 steps, then `postcondition-failed`; the failure text was not captured |
| `press --label Twin --index 2`, then `--index 1` | `accepted`; the probe read `select:twin-2`, then `select:twin-1` |
| `press --id probe.tv.row.11`, the last row in the tree, at y 860 | `accepted`; `select:row-11` |
| `batch` of `remote up`, `remote right`, `wait --until visible`, `press --id probe.tv.button.c` | `completed`, four steps; `select:c` |
| `set-value --id probe.tv.text.field 'hola tv'` | `acknowledged`, 7 bytes read back; the screenshot showed tvOS's keyboard in front with "hola tv"; `remote menu` closed it |

The connection went stale a third time during these, about 25 accessibility commands after the restart, and was healthy again within about a minute without anything being done.

**Asking `remoted` instead.** `remotectl netcat <name> com.apple.accessibility.axAuditDaemon.remoteAXService`, with the tunnel up: `remoted` logged `device_get_service: Returning service "com.apple.accessibility.axAuditDaemon.remoteAXService"` and the tool printed "Unable to connect". The same lookup from a test process of this project, holding a tunnel assertion, through `remote_device_copy_device_with_name` and `remote_device_copy_service` of Apple's RemoteServiceDiscovery framework: the device was found, in state 2; the service came back nil; `remoted` logged `Client lacks privilege to find service with name com.apple.accessibility.axAuditDaemon.remoteAXService`. Neither attempt was followed by `Device connection interrupted`. The process `remoted` does hand that service to is `CoreDeviceService`, which asks for every service of the device. The scratch code for this was removed.

Not shown: `remote --hold` on the device; recording and `frames` (the opt-in media probe sends a tap, which is refused on an Apple TV, so it did not run); the named error for the stale state against a live stale connection (unit-tested only); why the search up failed its last check.

### Asking CoreDeviceService for the accessibility socket

Late on 2026-11-18, the Apple TV 4K (tvOS 27.2), macOS 27.2.1, Xcode 27.2, with a scratch test (removed afterwards) that sends `com.apple.coredevice.action.createservicesocket` to `com.apple.CoreDevice.CoreDeviceService`, the request the input path already uses, with a chosen `featureIdentifier` and `serviceName`. The connection was healthy throughout and `remoted` logged no `Device connection interrupted` during any of it.

The device's details list, among its capabilities, `com.apple.dt.servicesocket.create`, `com.apple.dt.serviceconnection.create`, `com.apple.coredevice.feature.servicexpcpeerconnection`, `com.apple.coredevice.feature.voiceover` and `com.apple.coredevice.feature.viewdevicescreen`.

| `serviceName` | `featureIdentifier` | Answer |
| --- | --- | --- |
| `com.apple.accessibility.axAuditDaemon.remoteAXService` | none; `com.apple.dt.servicesocket.create`; `com.apple.dt.serviceconnection.create`; `com.apple.coredevice.feature.voiceover` | Each: CoreDevice error 4000, "A connection to this device could not be established", underlying POSIX 83 |
| the same four, while the test held a tunnel assertion | | The same |
| `com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote` (`UsesRemoteXPC: false`) | none; `com.apple.dt.servicesocket.create` | 4000 / 83 |
| `com.apple.os_trace_relay.shim.remote` | none | 4000 / 83 |
| `com.apple.coredevice.hid.indigo` | none | A file descriptor, with five feature identifiers |
| none | `com.apple.coredevice.feature.remote.hid.button` | A file descriptor |
| `com.apple.coredevice.openstdiosocket` | none | A file descriptor |
| `com.apple.coredevice.deviceinfo` | none | A file descriptor |

For each refusal `CoreDeviceService` logged `[createservicesocket] remote_service_connect_socket failed for '<service>' (errno=83)`, one to two milliseconds after `Invoking action (type=CreateServiceSocketActionImplementation …)`, and `remoted` had answered `device_get_service: Returning service` for the name. In `remotectl dumpstate` the services that opened carry a `Features` property (empty for `openstdiosocket`) and the ones that did not carry only `UsesRemoteXPC`, `EncryptSocketData` and a version. Every descriptor was closed at once; nothing was sent on any of them.

**Why, read from Apple's code and from the device.** `remote_service_connect_socket`, in the RemoteServiceDiscovery library (read in Hopper), sends `remoted` a connect request and returns error 83 for any reply whose `result` is not `OK`: the decision is `remoted`'s. For each refusal above `remoted` had logged `service_handler: Client lacks privilege to interact with service with name <service> (client="pid/…")`, the client being `CoreDeviceService`. The test behind that message, read in `/usr/libexec/remoted` (disassembled with `otool`), takes the entitlement name the service carries and allows the client when:

- the name is `None-AppleInternal`; or
- the name is `AppleInternal` and the Mac is an Apple-internal build (`os_variant_has_internal_content`); or
- the client holds `com.apple.private.network.intcoproc.restricted`; or
- the client holds the entitlement of that name.

`com.apple.private.RemoteServiceDiscovery.device-admin`, which `CoreDeviceService` and `remotectl` hold, passes the other test, the one for finding a service, and is not part of this one: that is why both were given the service and then could not connect. The name comes from the device: `remoted` reads `EntitlementOverride` and `Entitlement` from each entry of the device's service directory. In the directory the Apple TV sent this project's own handshake:

| Service | `Entitlement` |
| --- | --- |
| `com.apple.accessibility.axAuditDaemon.remoteAXService` | `AppleInternal` |
| `com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote` | `com.apple.mobile.lockdown.remote.trusted` |
| `com.apple.os_trace_relay.shim.remote` | `com.apple.mobile.lockdown.remote.trusted` |
| `com.apple.coredevice.hid.indigo` | `com.apple.private.CoreDevice.hid`, which `CoreDeviceService` is signed with |

So on a customer Mac no process can reach `remoteAXService` through `remoted`, Apple's own included; the shims need an entitlement only Apple's lockdown clients hold. The device does not enforce any of it: it answers this project's direct connection to the same port. The scratch print that read the directory was removed.

Not shown: any other action of `CoreDeviceService`; the same on the phone; how Apple's Accessibility Inspector reaches a device (the `remoteserver` shim is the likely way).

### One directory connection per tunnel

Just before midnight on 2026-11-18, the Apple TV 4K (tvOS 27.2), macOS 27.2.1, Xcode 27.2, with the tvOS probe in front and the build that remembers the accessibility port per tunnel.

| Run | `serviceDirectory` in the step results | `Device connection interrupted` in `remoted`'s log for the run | Outcome |
| --- | --- | --- | --- |
| One `batch` of 8 accessibility steps (`wait`, `tree`, `press`, `wait --until value`, `scroll`, `press`, `tree`, `wait --until value`) | `opened` once, `reused-port` seven times | 1 | `completed`; the waits saw `select:b` and then `select:a` in the probe |
| One `batch` of 30 accessibility steps (five rounds of `tree`, two presses each followed by a wait for the probe's value, and a `scroll`), 97 seconds | `opened` once, `reused-port` 29 times | 1 | `completedSteps: 30`, `failedStep: null` |

`remotectl dumpstate` read `connected (connectable)` before and after both. Earlier the same night each accessibility command had been followed by one interruption, and the connection went stale about 25 commands after a restart.

**Across processes.** Shortly after midnight, with the port also saved in `~/Library/Application Support/manzanero/service-ports.json` (86 bytes, mode 600), each command below its own CLI process:

| Run | `serviceDirectory` | Interruptions | Outcome |
| --- | --- | --- | --- |
| Three `tree` commands two seconds apart | `opened`, then `reused-saved-port` twice | 1 | Each answered |
| Ten commands with the Home Screen in front, begun ten seconds after the run above | `opened` for the first (the tunnel had been replaced, so the saved entry did not match), `reused-saved-port` for the rest | 1 | The waits timed out and the presses found no match, correctly: the probe was not in front |
| Ten commands with the probe launched, begun on the same tunnel: `wait`, `press` on Button C, `wait --until value` for `select:c`, `scroll`, `press` on Button A, `tree`, a wait for `select:a`, `press --label Twin --index 2`, a wait for `select:twin-2`, `tree` | `reused-saved-port` for all ten | 0 | Every press `accepted`, the scroll verified, every wait met its value |

Not shown: an MCP session, which shares the process in the same way; a reused port after its tunnel was replaced inside one process; an entry refused for its age; the refusal of a command on a connection that is already stale, which is unit-tested only.

### A tunnel of the tool's own, tried again

In the first hours of 2026-11-19, macOS 27.2.1, Xcode 27.2. The retired bridge was exported from git history (`Backends/IDevice` as it stood before the commit that removed it), built unchanged with its pinned Rust toolchain, and run by hand as an experiment; it is not part of the tool and nothing of it was restored. Its route: ask Apple's `usbmuxd` for the device, start the device's CoreDevice proxy service with the trust the Mac already has, run a software tunnel over that, and read the service directory on that tunnel.

| Device | Command | Result | `Device connection interrupted` in `remoted`'s log |
| --- | --- | --- | --- |
| Apple TV 4K (network only) | `tree` | Refused before any contact: "Device not available through usbmuxd" | 0 |
| iPhone 13 mini (iOS 27.2.1), locked | `tree` | "CoreDevice proxy: unknown error `PasswordProtected` returned from device" | 0 |
| iPhone 13 mini, unlocked by the human owner (`handoff --until unlocked` answered `observed`) | `tree`, three times, six seconds apart | Each exited 0 with a tree of 78,943 bytes: the Home Screen's labels ("Wi-Fi", "Mapas", "Watch" among them) | 0 |
| The same phone, the current route, as a control | `tree` | 242 nodes, `serviceDirectory: opened` | 1 |

No pairing prompt appeared on the phone at any point. `remotectl dumpstate` listed every connection as `connected (connectable)` before and after.

So on a tunnel of its own the tool does not disturb `remoted`, and for a device the Mac reaches through `usbmuxd` it needs no pairing of its own. For a device it does not reach that way, the Apple TV here, the old bridge's only other route was its own Wi-Fi pairing with a PIN shown on the device, which was not run.

**The same tunnel service through Apple's own framework.** A scratch test (removed afterwards) loaded `/System/Library/PrivateFrameworks/MobileDevice.framework` and called it directly, with no third-party code:

| Step | Result |
| --- | --- |
| `AMDCreateDeviceList` | Five entries: the phone twice, with interface type 2 (network) and type 1 (cable), and three other network entries, not identified |
| `AMDeviceConnect` on the phone's network entry | `0xe8000065`; nothing further was tried on it |
| `AMDeviceConnect` on the cable entry | 0 |
| `AMDeviceIsPaired`, `AMDeviceValidatePairing`, `AMDeviceStartSession` | 1, 0, 0 |
| `AMDeviceSecureStartService` for `com.apple.internal.devicecompute.CoreDeviceProxy` | 0, with a service connection |
| The tunnel greeting sent on it (`CDTunnel`, a two-byte length, `{"type":"clientHandshakeRequest","mtu":1280}`) | 54 bytes sent; the reply began `CDTunnel` and carried `type: serverHandshakeResponse` with `clientParameters` (mtu 1280), `serverAddress`, `serverRSDPort` (55210) and `flags` |

The phone was unlocked, showed no prompt, and `remoted` logged no interruption. The connection was closed after the reply; no packet was exchanged on the tunnel.

**Without the cable.** The human owner then unplugged the phone; `devicectl` listed it as `connected`.

| Route | Result | Interruptions of `remoted` |
| --- | --- | --- |
| The retired bridge, `tree`, twice | Each exited 0 with a tree of 40,922 bytes | 0 |
| Apple's framework: `AMDCreateDeviceList` gave the phone one entry, interface type 2; `AMDeviceConnect` | `0xe8000065` | 0 |
| Apple's framework again, with the devices taken from `AMDeviceNotificationSubscribe` after three seconds of run loop (four attached, the phone among them, type 2) | `AMDeviceConnect`: `0xe8000065` again | 0 |

So over the network the retired bridge reaches the phone and Apple's framework, as called here, does not: it lists the device and fails to connect. Why was found that afternoon: the framework connects to a network device directly, which macOS's Local Network privacy refuses, while the bridge's library went through `usbmuxd` ([record](#the-tools-own-tunnel-without-the-cable)).

So over the cable Apple's framework finds the device, uses the Mac's existing trust and starts the tunnel service. What it does not do is carry the tunnel: after the greeting the service exchanges raw IPv6 packets, and turning those into connections is still to be supplied.

Not shown: an accessibility action, input or a long session on that route; anything sent through the tunnel opened with Apple's framework; which devices the three other network entries are; the Apple TV with its own pairing; how the route behaves while the phone locks again.

### The tool's own tunnel, built in

On the morning of 2026-11-19, the iPhone 13 mini (iOS 27.2.1) on its cable and unlocked, macOS 27.2.1, Xcode 27.2, with the tunnel as built into the tool: Apple's MobileDevice framework to open it, lwIP to carry it, a loopback relay, and the existing directory and accessibility code.

**Before the cable was in**, `mise run test:device-tunnel` failed as it should: "The device is not connected by cable; a tunnel of the tool's own needs the cable. Nothing was contacted."

**The opt-in check**, with the cable in:

| Run | Result | `Device connection interrupted` in `remoted`'s log |
| --- | --- | --- |
| Open the tunnel, relay to the device's directory port, read the directory with `RSDDirectoryConnection` | Passed in 0.33 s: MTU 1280, the accessibility service found | 0 |
| The same, then a second relay to the accessibility port and one tree of the app in front | Passed in 6.6 s: 244 nodes, 78,574 bytes | 0 |

**The accessibility commands**, with `MANZANERO_OWN_TUNNEL=1` and the probe app in front, each its own CLI process:

| Command | Result | Seconds |
| --- | --- | --- |
| `wait --until visible --id probe.text.field` | `condition-met`, `serviceDirectory: own-tunnel` | 2 |
| `tree` | 13 nodes, `own-tunnel` | 4 |
| `set-value --id probe.text.field tunel-propio` | `acknowledged`, `own-tunnel` | 4 |
| `press --id probe.touch.reset` | `accepted`, `own-tunnel` | 4 |
| `tree` | 16 nodes, `own-tunnel` | 4 |
| `wait --until visible --id probe.touch.summary` | `condition-met`, `own-tunnel` | 4 |

`remoted` logged no interruption during the seven commands, and every connection read `connected (connectable)` afterwards. A tree read through the tunnel and one read through the current route, one after the other, agreed: 16 nodes, the text field's value `tunel-propio`, and the probe's own record of it (`"text":"tunel-propio"`, `"edits":1`). A seventh command, a wait for the probe's value to equal the bare text, timed out on both counts correctly: that element's value is a JSON record, not the text.

**The fallback.** Later the same morning the phone was off its cable again. With the opt-in still set, `wait`, two `scroll` commands, `detect-layout --id probe.text.field` (`detected`) and `handoff … --until visible` (`observed`) all ran, on the route over Apple's tunnel (`serviceDirectory: reused-saved-port`). Nothing in their results said why the tunnel had not been used, so a reason was added: a `tree` then answered `ownTunnelUnavailable: "The device is not connected by cable; a tunnel of the tool's own needs the cable. Nothing was contacted."` beside `serviceDirectory: reused-saved-port`. `doctor` listed the new `device-tunnel` entry with nothing missing.

**With the cable back in**, the opt-in set and the probe app in front:

| Command | Result |
| --- | --- |
| `wait --until visible --id probe.text.field` | `condition-met`, `serviceDirectory: own-tunnel` |
| `scroll --id probe.touch.summary` | `nativeResult: false` (already in view), `postcondition-verified`, `own-tunnel` |
| `tree` | `own-tunnel` |
| `detect-layout --id probe.text.field`, twice | `detected` both times; its result does not carry `serviceDirectory`, so the route is known only from the code path it shares |
| `handoff "…" 20 --until visible --id probe.touch.summary`, twice | `observed` both times; the same remark |
| One `batch` of 30 accessibility steps (five rounds of `tree`, `set-value`, `wait`, `press`, `scroll`, `wait`), 89 seconds | `completedSteps: 30`, `failedStep: null`, `serviceDirectory: own-tunnel` in all thirty: one tunnel kept by the process for the whole batch |

`remoted` logged no interruption during any of it, and no connection was stale afterwards. About three seconds a step is what the same commands take on the other route; the time is in the `devicectl` queries each command makes, not in the tunnel.

Not shown: an MCP session; `detect-layout` and `handoff` reporting which route they used; a long run; a device that locks during a command; why a command takes about four seconds; another device.

### The tool's own tunnel without the cable

On the afternoon of 2026-11-19, the iPhone 13 mini (iOS 27.2.1) off its cable, on the same network, display on and no passcode required (`transportType: localNetwork` in `devicectl`), macOS 27.2.1, Xcode 27.2. Only trees and the service directory were read; no input was sent.

**Why Apple's framework failed there.** A scratch program, since removed, asked `usbmuxd` and the framework about the phone's network entry:

| Step | Result |
| --- | --- |
| `usbmuxd`'s own `Connect` to the entry's lockdown port (62078) | `Result 0`: `usbmuxd` relays to a network device |
| `AMDeviceConnect` on the framework's entry (interface type 2) | `0xe8000065` within a hundredth of a second |
| The process's log at that moment | `connect() failed: 65.` and "Could not connect to lockdown port (62078) … `kAMDMuxConnectError`" |
| The kernel's log at that moment | `tcp drop outgoing … process: swift-frontend … reason: NECP`, then `UserEventAgent`: "Got local network blocked notification … bundle_id: (null)" and "LocalNetwork: did not find bundle ID" |

So the framework connects to a network device directly, macOS's Local Network privacy drops that connection, and there is no application for a grant to be given to. In the framework's code (`otool`), `_connect_to_port` calls `USBMuxConnectByPort` for a device whose link was read as USB and `connect()` otherwise, and `AMDeviceCreateFromProperties` reads the link from the entry's `ConnectionType`.

**Through `usbmuxd` instead.** A device object made with `AMDeviceCreateFromProperties` from the network entry's `DeviceID` and serial number, with `ConnectionType` given as `USB`, connected (`AMDeviceConnect` 0), validated the pairing, started a session and the tunnel service, and received the service's greeting with its `serverRSDPort`. No prompt appeared on the phone.

**Built into the tool**, with `MANZANERO_OWN_TUNNEL=1`:

| Run | Result | `Device connection interrupted` in `remoted`'s log |
| --- | --- | --- |
| `tree`, six separate processes | Each exited 0 with `serviceDirectory: own-tunnel` and `ownTunnelLink: network`; about 10 s each | 0 |
| `mise run test:device-tunnel`: the directory, then one tree | Passed in 10.1 s | 0 |
| One `batch` of ten `tree` steps, 86 s | Every step exit 0, `own-tunnel` and `network` in all ten: one tunnel for the whole batch | 0 |
| `tree` without the opt-in, for comparison | 8.0 s | not counted |

Opening the tunnel took about 1.4 s of each command (eight relayed connections through `usbmuxd` for the session and the service); the rest is the tree itself, which took as long on the other route with that screen in front.

**The cable again, with the same build.** The human owner plugged the phone in (`transportType: wired`). `tree` and `mise run test:device-tunnel` (6.6 s) answered on the tunnel with `ownTunnelLink: cable`. Then, with the probe app launched and each command its own process: `wait --until visible --id probe.text.field` (`condition-met`), `set-value --id probe.text.field cable-otra-vez` (`acknowledged`), `press --id probe.touch.reset` (`accepted`), `scroll --id probe.touch.summary` (`postcondition-verified`), `detect-layout --id probe.text.field` (`detected`) and `tree`, every one that reports its route saying `own-tunnel` and `cable`. `remoted` logged no interruption.

**Actions without the cable.** The human owner unplugged the phone again (`transportType: localNetwork`), the probe app still in front, each command its own process:

| Command | Result |
| --- | --- |
| `wait --until visible --id probe.text.field`, the first command after the unplugging | Exit 1 after 0.88 s: "Accessibility socket closed or reached EOF. AX wait stage=start, polls=0". A failure carries no `serviceDirectory`, so which route it ran on is not known |
| `set-value --id probe.text.field sin-cable` | `acknowledged`, `own-tunnel`, `network` |
| `press --id probe.touch.reset` | `accepted`, `own-tunnel`, `network` |
| `scroll --id probe.touch.summary` | `postcondition-verified`, `own-tunnel`, `network` |
| `detect-layout --id probe.text.field` | `detected` |
| `handoff "…" 20 --until visible --id probe.touch.summary` | `observed` |
| `tree` | 9 labels, the field's value `sin-cable`, `own-tunnel`, `network` |
| The same `wait`, twelve more times | `condition-met`, `network`, all twelve |

`remoted` logged no interruption during the twenty commands. The one failure was not reproduced and its cause is not known; it was the first command after the link changed.

**A failure now names its route**, since that one could not be placed: the message of a failed accessibility command carries `Route: serviceDirectory=…`, with `ownTunnelLink` on the tunnel and the reason when the tunnel was asked for and not used. With that build and the phone still off its cable, four rounds of `wait`, `set-value`, `press`, `scroll` and `tree`, twenty separate processes, all exited 0 with `own-tunnel` and `network`, the last tree showing the last value set; `remoted` logged no interruption. No command failed, so the new sentence was not seen on a live failure.

**The default.** On the human owner's word the tunnel then became the default. With the phone still off its cable and no variable set, `tree` and `wait` answered `own-tunnel` and `network`; with `MANZANERO_OWN_TUNNEL=0`, `tree` answered `serviceDirectory: reused-saved-port` with no tunnel field.

**Changes of link.** With the default build, `wait --until visible --id probe.text.field` ran in a loop, each its own process, one every three to six seconds, while the human owner pulled the cable and put it back four times:

| Moment | Result |
| --- | --- |
| The cable plugged in, before the loop | The first four commands (`wait`, `tree`, `press`, `wait`) answered on the tunnel with `ownTunnelLink: cable` |
| Each of the four unpluggings | Exactly one command failed, the one in flight: "Accessibility socket deadline exceeded" after 6 to 8.5 s, with "No input was sent" and the new sentence `Route: serviceDirectory=own-tunnel, ownTunnelLink=cable.` |
| The command after each failure | `condition-met` on the tunnel with `ownTunnelLink: network` |
| Each of the four pluggings | No failure; the next command, some seconds later, answered with `ownTunnelLink: cable` |

So a tunnel on the cable ends when the cable is pulled, and the command that was using it fails once and is not retried; the next one opens a tunnel over the network. A tunnel over the network is not disturbed by the cable arriving. The failed `wait` of the earlier run fits this, as the command straight after an unplugging, though it failed sooner. `remoted` logged no interruption, only its own handshake with the phone at each plugging.

**One more attempt for `tree` and the waits.** Built after that run, on the human owner's word: such a command whose own tunnel ends under it runs once more on a new connection and reports the first failure in `retriedAfter`. A first loop of 60 rounds of `wait` and `tree` with that build ran entirely on the cable, 120 results of 120 on the tunnel with no failure and no interruption of `remoted`; the cable was not pulled during it, so no retry happened.

A second loop, stopped after 93 commands, ran while the human owner pulled the cable and put it back several times:

| What | Count |
| --- | --- |
| Commands that failed | 0 of 93 |
| Results on the cable, and over the network | 84 and 9 |
| Results with `retriedAfter` | 3: a `tree` at 17:10:21 and at 17:10:55, a `wait` at 17:11:22, each answering `ownTunnelLink: network` and quoting its first attempt, "Accessibility socket deadline exceeded … Route: serviceDirectory=own-tunnel, ownTunnelLink=cable" |
| `Device connection interrupted` in `remoted`'s log | 1, at 17:11:51 on its `coredevice` connection, with "Handshake complete" two seconds later and nothing stale afterwards |

So a `tree` or a `wait` in flight when the cable is pulled now answers, over the network, where it failed four times of four before. The one interruption came at a fourth change of link, during a `wait` that took thirteen seconds and answered on the cable without a retry; every command around it was on the tool's own tunnel, and the eight earlier changes of link of that afternoon logged none. Whether the change of link or the tool caused it is not known.

**An MCP session.** After the human owner reconnected the server in the host, so that it ran this build, with the phone on its cable and the probe app in front: `wait_for_element`, `set_element_value` (`sesion-mcp`, `valueMatches: true`), `press_element`, `scroll_to_element`, a `wait_for_element` for that value, and one `run_batch` of six steps (`wait`, `set-value`, `press`, `scroll`, `wait` for the new value, `tree` of 16 nodes). All eleven results said `serviceDirectory: own-tunnel` and `ownTunnelLink: cable`, the batch completed 6 of 6, and `remoted` logged no interruption. The server is one process, so these ran on the tunnel it keeps between calls.

**The route in `detect-layout` and `handoff`, and the archive.** Both commands now carry the route fields of the accessibility requests they make. On the phone on its cable, `detect-layout --id probe.text.field` answered `detected` with `route: {serviceDirectory: own-tunnel, ownTunnelLink: cable}`, and `handoff "…" 20 --until visible --id probe.touch.summary` answered `observed` with the same under `observation.route`. `mise run package` and `mise run test:package` passed with lwIP as a dependency: the archive holds `ThirdParty/lwip-LICENSE.txt`.

Not shown: an MCP session over the network or across a change of link; what caused that interruption; an Apple TV, or any device `usbmuxd` does not list, since the default changed; an action, not a `wait`, in flight when the cable is pulled; a tunnel kept by one process (a `batch`, an MCP session) across a change of link; an MCP session; a phone that leaves the network during a command; whether the phone's "connect over the network" setting must be on for `usbmuxd` to list it; the cable pulled while a tunnel is open; another device. The Apple TV is still out of reach: `usbmuxd` does not list it.

### Apple TV 4K with the tunnel as the default, and the search up

On the evening of 2026-11-19, the Apple TV 4K (3rd generation, tvOS 27.2) over the network, macOS 27.2.1, Xcode 27.2, with the human owner's word. `remotectl dumpstate` was read before each run and never showed a stale connection.

**The tunnel cannot reach it, and says so.** `tree` exited 0 with `ownTunnelUnavailable: "Apple's MobileDevice framework does not list the device; nothing was contacted."` and `serviceDirectory: opened`, then `reused-saved-port` in later commands and `reused-port` inside a `batch`: the route over Apple's tunnel, as before the default changed. That first `tree` cost one `Device connection interrupted` in `remoted`'s log, followed by "Handshake complete"; the later runs logged none.

**Asleep at the start.** The first `tree` showed only `PineBoard` (29 nodes, no labels), `launch` of the tvOS probe answered success without bringing it in front, and `screenshot` failed with "Display reports zero-sized native size". One `remote home` woke it: a screenshot then showed the Home Screen with the focus on another app. No select was sent there; the probe was started with `launch`.

**The search up.** In the probe, each run one `batch`:

| Run | Result |
| --- | --- |
| `scroll --id probe.tv.row.30 --search 40`, then `--id probe.tv.row.1 --search 40 --toward up` | Both `postcondition-verified`, in 8 and 21 steps |
| `--id probe.tv.row.40 --search 60`, then `--id probe.tv.row.1 --search 60 --toward up` | Down in 12 steps; up failed: "Accessibility session: frame budget exceeded. AX scroll-to-visible state=search-submitted, stage=search", `input-outcome-unknown` |
| The same after the change below, twice in one batch | Down in 12 steps and up in 28, both times `postcondition-verified` |

So the search up that failed on 2026-11-18 was a long search, not a search upward: one accessibility session serves the whole search, and the standard allowance of 256 frames ends it somewhere past twenty steps on this device. A search now gets an allowance that grows with its steps (`DirectAccessibilityAction.sessionLimits`: 32 frames, three seconds and 2 MB for each).

Not shown: `remote --hold` on the device, which the tool still refuses there; the error for the stale state, as no connection went stale; recording and `frames`; a search to the right or left of more than twenty steps. The probe was left in front.

### Held remote buttons on the Apple TV 4K

Later the same evening, the same device and versions, on the human owner's word; `remote --hold` had been refused on a device until then. The device had gone back to sleep: one `remote home` woke it and `launch` brought the tvOS probe in front. The focus was read from a tree before any select.

| Run | Result |
| --- | --- |
| One `batch`: `remote down` twice, `wait --until focused --id probe.tv.hold`, `remote select --hold 1.5`, a wait for `probe.tv.last` to read `select-long`, `remote select`, `remote select --hold 1.2`, `tree` | 8 of 8 steps; the probe's summary went from `select=20 select-long=0` to `select=20 select-long=2`: both holds recorded as long presses, the plain press on that element as nothing, as on the simulator |
| `remote home --hold 1.5`, first | Exit 1 before any contact, "Invalid direct button request.": the bridge allows a button 0.4 s at most |
| The same with that limit raised for Home | Exit 1 after about the hold: "Input stopped after cancellation or transport failure; release was attempted …". Two screenshots and a tree afterwards showed the probe unchanged, with no Control Centre and no Home Screen. The device was marked quarantined, as built; `clear-quarantine` after the look |
| One `batch`: `remote right`, `remote down --hold 1.5`, `tree`, `remote menu --hold 1`, `remote play-pause --hold 1`, `tree` | 6 of 6 steps. The first tree had the focus on `probe.tv.row.14`: the held arrow repeated. The second tree was the Home Screen's: the held Menu had left the probe, and its counts did not change. The held Play/Pause therefore went to the Home Screen, where a screenshot showed nothing changed |

So on a device the keys hold as on a simulator, and the button service does not hold Home. The limit in the bridge was put back and `remote home --hold` is refused on a device with that reason. The held Play/Pause was sent outside the probe by mistake: the step before it had left the app, and the batch was written without allowing for that.

**Apple's Device Hub, for comparison.** The human owner pressed Home in Device Hub (Xcode 27.2) on the same Apple TV while the Mac's log was captured for that process, once briefly and then nine more times, some of them held with the pointer. Control Centre did not open for the human owner either. Each press reads the same in the log: "Returning cached implementation (CoreDevice.IndigoHIDButton) for HID Button (com.apple.coredevice.feature.remote.hid.button)", then two messages of 224 bytes written to that one connection within a millisecond of each other, and nothing else. So Device Hub uses the same button service, on a connection it keeps open, and sends the press and the release together however long its button is held: it has no long press of Home on a device. The messages' content is not logged.

Not shown: what a held Play/Pause does inside an app; why the button service fails during a hold, and whether a shorter one, between 0.4 s and 1.5 s, would pass; whether a hold would pass on a connection kept open, as Device Hub keeps its own, and without the readiness request this tool sends first; Control Centre on a device.

### Device Hub's screen view of the Apple TV

Late on 2026-11-19 the human owner opened the Apple TV 4K's screen view in Apple's Device Hub (Xcode 27.2) for about twenty seconds while the Mac's log was captured for Device Hub, `CoreDeviceService` and `remoted`. This tool sent the device nothing. The human owner saw the correct picture, live.

| What Device Hub did, from the log | Compared with this tool |
| --- | --- |
| Asked for the media support information (`com.apple.coredevice.action.mediastreamgetsupportinfo`), several times; supported features "Primary video display mirrored output stream, System audio output stream, Display information" (140) | The same action and the same value |
| Started an **audio** output stream first (`MediaStreamStartParameters … type: audio`), then the **video** one, both with one `avcMediaStreamOptionClientSessionID` and each with a `sessionEventChannel` | The video alone, with no event channel |
| Video options `CoreDeviceVideoDisplayMode: "DisplayByID"`, `VideoStreamForDisplayID: 1`, transport TCP, access network LAN, the receiver on the Mac's end of Apple's tunnel | The same options |
| Received with Apple's AVConference (`AVCVideoStream`, client name `CoreDeviceScreenSharing`): 3168 × 1792, 60 frames a second, receive codec type 102, pixel format `420v`, not protected (`vcMediaStreamIsVideoProtected = 0`), bit rate 333 kb/s to 6 Mb/s | The same size; packets taken from the socket and decoded in process |
| Stream started 23:20:49 and stopped 23:21:08; status and stop through `MediaStreamStatus` and `MediaStreamStop` | The same actions |

So the request is the same and the stream is not marked protected. The differences are the audio stream started beside the video, the event channel, and who decodes.

Not shown: how much data Device Hub received. Starting the audio stream too was tried on 2026-11-20 and changed nothing ([record](#the-apple-tvs-video-stream-read-packet-by-packet)).

### Accessibility Inspector on the Apple TV

Late on 2026-11-19 the human owner opened Xcode 27.2's Accessibility Inspector while the Mac's log was captured for device connections in every process; this tool sent the Apple TV nothing. A first capture, of the Inspector's own process only, showed no device connection: the work is done by two helpers, `axAuditService` inside the Inspector and MobileDevice's `MDRemoteServiceSupport`. What the human owner saw and browsed in the Inspector was not reported.

| Time | From `remoted`'s log, for the Apple TV 4K (`AppleTV14,1`, tvOS 27.2) |
| --- | --- |
| 23:44:51 | `MDRemoteServiceSupport` browses the devices `remoted` knows and lists this one's 81 services, three times |
| 23:44:54 | "Fetching service `com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote` … (client pid of `MDRemoteServiceSupport`)", then "Returning service", "Accepting service connection" and "Got CONNECT command" |
| The whole session, to 23:46:19 | No "Connection reset by peer" and no interruption of that device's connection. Two other connections, made at 23:45:03 and 23:45:50, were ended at 23:46:16 with "Peer connection canceled", when the Inspector quit |

So Apple's Inspector reaches the device's accessibility daemon through `remoted`, by the shim of its older service name, asked for by MobileDevice's helper, which holds the entitlement the shims name (`com.apple.mobile.lockdown.remote.trusted`). It opens no service directory connection of its own, and the device did not reset the Mac's. This tool asks for another service of the same daemon, `…axAuditDaemon.remoteAXService`, which `remoted` refuses it, and therefore reads the directory itself, which is what makes the device reset `remoted`.

Not shown: whether this process can get the same connection by calling the MobileDevice framework (`AMDeviceCreateWithRemoteDevice` and a service start are exported; nothing was tried); whether the service behind the shim speaks what this tool's accessibility code speaks (the log names `com.apple.accessibility.axAuditDaemon.protocolVersion` over DTX, which is the family this tool uses); what the Inspector showed.

### The accessibility shim, opened by this tool

In the first hour of 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network with the tvOS probe in front, macOS 27.2.1, Xcode 27.2, on the human owner's word. Read-only: no element was acted on.

| Step | Result |
| --- | --- |
| `remote_device_copy_device_with_uuid` for the device's identifier in `remoted`, then `AMDeviceCreateWithRemoteDeviceWithError`, `AMDeviceConnect`, `AMDeviceStartSession` | All succeeded from this process |
| `AMDeviceSecureStartService` for `com.apple.accessibility.axAuditDaemon.remoteserver` | Success and a service connection. `remoted` logged "Returning service `…remoteserver.shim.remote`" for this process's MobileDevice helper, with no "lacks privilege" |
| The connection's first bytes | `79 5b 3d 1f`, a DTX header: the daemon speaks first, and its socket is a plain stream that the tool's accessibility transport takes as it is |
| The tool's tree code on that stream | Stopped at once. The daemon calls `hostApiVersion` where the tool expected `hostAPIVersion` (now both are accepted), and refuses the tool's own requests: "Unable to invoke -[XADAuditServer deviceAPIVersion]" and the same for `clientNeedsAccessibility:` |
| Read-only requests in that daemon's own words | `deviceApiVersion` answered 26; `deviceAccessibilitySettings` answered a dictionary; `deviceCapabilities` answered 43 request names |
| `remoted`'s log over the six runs | No interruption, no reset, and no stale connection afterwards |

So the route is open to this tool: no service directory connection of its own, no pairing of its own, and no reset of the Mac's connection. What answers on it is the audit server Apple's Accessibility Inspector talks to (`XADAuditServer`), not the service this tool's trees are read from, so nothing the tool has can be pointed at it unchanged. Its capabilities include `deviceRunningApplications`, `deviceFetchElementAtNormalizedDeviceCoordinate:`, `deviceFetchSpecialElement:`, `deviceElement:valueForAttribute:`, `deviceElement:valueForParameterizedAttribute:withObject:`, `deviceElement:performAction:withValue:`, `deviceElement:setValue:attribute:`, `deviceInspectorMoveWithOptions:` and `deviceCaptureScreenshot`: enough, by their names, to read elements and act on them, one request an element.

Kept from the experiment: `ADCOpenAccessibilityShim` in the bridge, `AccessibilityShim`, `doctor`'s `accessibility-shim` entry, and two opt-in checks (`MANZANERO_SHIM_SELECTORS=<UDID>` or `MANZANERO_SHIM_DEVICE=<UDID>` with `swift test --filter AccessibilityShim`). No command uses them.

Not shown: any element read through it; what an element looks like on the wire; how fast a tree built one request an element would be; an iPhone.

### An element read through the shim

On 2026-11-20, the Apple TV 4K (tvOS 27.2) with the tvOS probe in front, on the human owner's word. Requests in the audit server's own words, through `AccessibilityShim`.

| Request | Answer |
| --- | --- |
| `deviceCurrentState` | 0 |
| `deviceRunningApplications` | An empty array |
| `deviceInspectorSupportedEventTypes` | 2 |
| `deviceFetchSpecialElement:` with 0 | A dictionary: `ObjectType: AXAuditElement_v1`, and under `Value` a `PlatformElementValue_v1` of 20 bytes |
| `deviceFetchSpecialElement:` with 1 | The same shape with `AccessibilityIdentifier_v1: probe.tv.col.12`: an element of the probe, by its identifier |
| `deviceFetchElementAtNormalizedDeviceCoordinate:` with a point archived as an `NSValue` | An empty acknowledgement: not the form it wants |
| `deviceElement:valueForAttribute:` with that element as received and the attribute's name as a plain string (`_AXIOSMACLabel`, a constant read from Apple's AccessibilityAudit framework on the Mac) | **The connection closed, and the Apple TV's `axauditd` left a crash report: `EXC_CRASH`, `SIGABRT`.** It happened twice, because the check ran a second time before the cause was understood |

After each crash the daemon was running again within seconds: a `tree` on the other route read 112 nodes, and the shim answered its version and an element again. No connection went stale.

So elements can be fetched, and they carry the identifier the tool's selectors use. Reading an attribute needs the argument in a form that was guessed wrong, and a wrong guess aborts a system daemon on the device. The request has been taken out of the opt-in check. The attribute names the framework exports are `_AXIOSMACLabel`, `_AXIOSMACValue`, `_AXIOSMACTraits`, `_AXIOSMACHint`, `_AXClassName`, `_AXHumanReadableDescription`, `_AXAncestorChain`, `_AXSiblingElements` and `_AXHierarchyElementsAttribute`; how one is wrapped for the wire has to be read from that framework's code (its classes `AXAuditElement` and `AXAuditElementAttribute`) before another request is sent.

**The form, read from Apple's own encoder.** The AccessibilityAudit framework loads on the Mac, and its `AXAuditObjectTransportManager` was asked there, with nothing sent to a device, how it writes an attribute: a dictionary `ObjectType: AXAuditElementAttribute_v1` whose `Value` holds `AttributeNameValue_v1` and six flags, each wrapped as `{ObjectType: passthrough, Value: …}`. An element and a point are written the same way (`AXAuditElement_v1`, `AXAuditPoint_v1`). No disassembler was needed.

With the attribute in that form, on the same Apple TV, each new request run once and the daemon's last crash report read after it:

| Request | Answer |
| --- | --- |
| `deviceElement:valueForAttribute:` for `_AXClassName` on the probe's element | `SwiftUI.AccessibilityNode` |
| The same for `_AXHumanReadableDescription` | `Col 12 Button` |
| The same for `_AXHumanReadableRoleDescription` | `Button` |
| The same for `_AXIOSMACLabel`, `_AXIOSMACValue`, `_AXIOSMACTraits` | Empty: those names answer nothing on tvOS |
| The same for `_AXHierarchyElementsAttribute` on special element 0 | An `AXAuditNode_v1`: the element, two descriptions and `IsIgnoredValue_v1` |
| `deviceFetchElementAtNormalizedDeviceCoordinate:` with the typed point dictionary | An error, not a crash: "-[__NSDictionaryI CGPointValue]: unrecognized selector". It takes a plain point value |
| The same with a plain point value, at three points | Empty each time |
| Seven requests on one connection | Half a second |

No request in that form crashed the daemon: its last crash report stayed the one of 00:03:05 UTC. `deviceFetchSpecialElement:` with 1 answered the probe's element while the probe was in front and nothing while the Apple TV slept, where every attribute came back empty too; a sleeping device explains one run of empty answers.

So attributes are readable through the shim, quickly, in a form that is now known and not guessed. Not shown here, and run later the same day ([record](#the-inspectors-cursor-the-whole-hierarchy-and-a-press-through-the-shim)): the names that answer a label, a value and the children on tvOS, a way from one element to the whole screen, and an action. Still not shown: why no element is found at a point.

### A search on an iPhone simulator, and a table row's two objects

On 2026-11-20, a new simulator of this project's own, `manzanero-research-phone` (iPhone 17, iOS 27.2), macOS 27.2.1, Xcode 27.2, with the iOS probe built by `build-run` and launched with `-ProbeList YES` ([list probe](probe-app.md#list-probe)). The tree held 18 of the lists' 100 elements at launch: rows 1 to 13 and the first columns.

| Command | Result |
| --- | --- |
| `scroll --id probe.list.col.35 --search 80 --toward right`, then `--id probe.list.col.3 --toward left` | `postcondition-verified` in 16 and 15 steps |
| `scroll --id probe.list.row.55 --search 80`, then `--id probe.list.row.2 --toward up` | The rows were found and brought on screen in 4 and 16 steps, and the check afterwards failed: "target centre hit is another native element" |
| `press --id probe.list.row.31` and `press --label "Row 32"`, rows on screen | Refused before any input with the same sentence |
| What the hit test at a row's centre answered | An element with the row's identifier, label and frame, visible, and another object than the tree's: the tree holds the `UITableViewCell`, and UIKit answers a hit with its own element for that row |

The guard compared objects only. It now also accepts a hit in the same process that has the target's frame and its identifier, or its label when the target has no identifier (`DirectAccessibilityAction.sameElement`; the live label is attribute 3). A view that merely covers the target has neither, and a row with another identifier or label is still refused. After the change, on the same simulator:

| Command | Result |
| --- | --- |
| `press --id probe.list.row.31`, `press --label "Row 32"` | `accepted`, and `wait --id probe.list.last --until value` met `row-31` and `row-32` |
| `scroll --search 80` to row 58 down, row 2 up, column 38 right, column 2 left | `postcondition-verified` each: 2, 16, 16 and 17 steps |

So `scroll --search` works in four directions on an iPhone simulator, and plain table rows can be pressed there. The collection view's cells answered a hit with the tree's own object and needed no change.

Not shown: a plain table row on a physical iPhone, where the same guard runs and nothing was tried; an iPad; a list whose rows do not share an edge; a table row hidden under another view with the same frame and no identifier or label, which the rule refuses by construction and no app showed.

### The Apple TV's still screen, and a restart it did not need

2026-11-21, about 20:30, the Apple TV 4K (tvOS 27.2) at the human owner's word, the room kept quiet: video only, the tvOS probe in front (its still screen, Button A focused), nothing pressed. Its display reported `external`; the television was on.

- **Pictures on a still screen.** `frames … --count 1000 --seconds 60` (no `--interval`, so every picture that arrived) saved 69 pictures, all in the first 4.7 s, a median of 61 ms apart and at most 165 ms; then none for the rest of the minute. A second run of 30 s with `MANZANERO_KEEP_STREAM=1` did the same (68 pictures, the last at 4.84 s) and kept 1002 packets: the video's up to about 5 s, and then one 48-byte packet with sequence number 12 and an unchanged timestamp, 30 times, once a second, a series of its own beside the video's (sequence numbers near 53606). So unlike the phone, whose still screen delivered a picture at least every 119 ms, a still Apple TV screen stops sending video after about five seconds.
- **A restart it did not need.** `record … 15 --backend coredevice`, the first Apple TV recording since recovery was built, restarted its session once: `recovery.gaps` held one `no-pictures` gap at 4.9 s. Recovery counted every datagram as traffic, so the repeated packet made "packets and no picture for 3 s" a stall. Counting only new video packets (the negotiated payload type, a new sequence number and timestamp) still left one restart in a 30-second recording: the repeat's first arrival is new, and one packet within the 3 s was enough. With the stall also needing a new video packet within the last second (`RecordingRecovery.flowNanoseconds`; a stream that fails to decode sends tens a second), a 30-second recording of the same screen had `restarts: 0` and no gap, 73 source pictures, the last one held to the end, and a confirmed stop.

So silence cannot be a sign of a lost stream on an Apple TV: its still screen is silent, apart from that repeat, for as long as nothing moves.

### The press order on the Apple TV 4K, and a stale connection

On 2026-11-21 from 15:49, the Apple TV 4K (3rd generation, tvOS 27.2) with the tvOS probe in front, at the human owner's word; the room kept quiet. `readiness` and a screenshot read `displayPower: external`, and the probe's tree came over the tool's paired tunnel (`serviceDirectory: own-tunnel`, `ownTunnelLink: paired`).

- `press --id probe.tv.button.b` went by the paired tunnel (no `route` field, `serviceDirectory: own-tunnel`) and the probe read `select:b`, count 1.
- `MANZANERO_OWN_TUNNEL=0 press --id probe.tv.button.c` went by the Inspector's cursor (`route: inspector`, `ownTunnelUnavailable: "the tool's own tunnel is switched off (MANZANERO_OWN_TUNNEL=0)"`) and the probe read `select:c`, count 2. The press order of 2026-11-20 is so confirmed on the device for its first two routes.
- `MANZANERO_OWN_TUNNEL=0 press --id probe.tv.row.3`, a row the Inspector cannot press, was refused before anything was sent: the Mac's connection to the device had gone stale (`remotectl dumpstate`: `State: attached`, `No connect() results`). Nothing more was sent to the device.
- The logs (`mise run diagnose:device-services --minutes 25`, nothing restarted): `remotepairingd` answered the device's RSD heartbeat until 15:50:47 and logged "RSD Heartbeat … failed after 0ms" (or 2 ms) for it every 30 s from 15:51:16, 34 times by 16:07, the same line as the stale periods of 2026-11-18. The first failure falls just after the Inspector press, which was documented as leaving the Mac's connection alone; which step started it is not established. It had not cleared after 15 minutes with no command.
- At 16:27:41, on the human owner's word, `killall remotepairingd CoreDeviceService`; ten seconds later `remotectl dumpstate` no longer listed the device as stale. The human owner then decided that the route over Apple's tunnel is not to be used for an Apple TV. Since then an Apple TV's accessibility runs only on the tool's own tunnel (a press may still go by the Inspector's cursor): `MANZANERO_OWN_TUNNEL=0 tree` was refused with nothing sent ("An Apple TV's accessibility commands run only on the tool's own tunnel…"), the connection stayed healthy, and a plain `tree` came over the paired tunnel with 240 nodes.
- **`logs` on the Apple TV**, for the first time: `logs --seconds 12 --bundle com.lemambo.manzanero.probetv` ran on the paired tunnel (`serviceDirectory: own-tunnel`, `ownTunnelLink: paired`) on the probe's process and ended at its duration with 4 entries, all the system's own lines from that process (the probe logs nothing of its own on a button press); the connection stayed healthy.
- **The dead pairing removed.** Settings › Remotes and Devices › Remote App and Devices listed two hosts named `manzanero` with nothing to tell them apart, and each one's page offers only Forget This Device. One was forgotten (Forget This Device, then Remove) and a fresh command then opened the paired tunnel again, which verifies the pairing anew: so the one removed was the dead pairing of 2026-11-20, and one `manzanero` remains. `remote home` left Settings.
- **Does the Inspector's cursor leave the connection stale?** Checked at the human owner's request from 16:42, the connection healthy beforehand (no stale entry in `remotectl dumpstate`, no failed heartbeat in the last 3 minutes): three presses with `MANZANERO_OWN_TUNNEL=0` went by the cursor (`route: inspector`), the probe counted them (`select:a`, `b`, `c`, count 3), and after each, 90 to 120 s of watching `remotectl dumpstate` and `remotepairingd`'s heartbeat lines found nothing wrong, through 16:48. So the stale state at 15:51 was not reproduced by the cursor's route; what started it is still not known, and that route stays in the press order.

### Press by the Inspector's cursor on the Apple TV 4K

On 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network with the tvOS probe in front, macOS 27.2.1, Xcode 27.2, after the human owner chose to have `press` built on this route. The focus was on Button B throughout, on a screenshot before and after.

| Command | Result |
| --- | --- |
| `press --id probe.tv.button.c` | `route: inspector`, `status: accepted`, `elementsWalked: 12`, `transport: apple-mobiledevice-shim`. The probe showed "Last: select:c" and its count went from 8 to 9 |
| `press --label "Button A"` | The same route, the target's caption "Button A, Button"; the count went to 10 |
| `press --id probe.tv.row.35`, a row of the list, visible on screen | The cursor did not reach it, so nothing was pressed there and the command went on by the route over Apple's tunnel: `status: accepted`, `serviceDirectory: opened`, and `inspectorUnavailable: "the Inspector's cursor reached 12 elements and none with that identifier"`. The probe showed "Last: select:row-35", count 11 |
| The device's crash reports and the Mac's connection afterwards | No `axauditd` report; `remoted` showed the device connected |

So a press of an element outside a list goes by the cursor with no connection of the tool's own to the device's service directory, and a row inside a list still costs the other route's reset, said in the result.

Not shown: `remoted`'s log during these presses (the absence of a reset on this route was read on 2026-11-20 for the same requests, not again here); a press on a screen other than the probe's; a walk that enters a list and scrolls it; two elements with one label, which the unit tests cover and the device did not see.

### The remote's swipes on the Apple TV 4K

On 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network with the tvOS probe in front, macOS 27.2.1, Xcode 27.2, on the human owner's word. The device had gone to sleep; one `remote home` woke it, and a screenshot taken at once was black, a second one some seconds later showed the probe. The focus was read from a screenshot before each run.

The lead was the `universalhidservice` Apple's Device Hub used with this Apple TV. The device lists that service, the one multi-touch goes through on a phone, and it took the request a simulator's takes: `createService` with a touch-pad description (usage page 13, usage 5, service ID 0x700), then one finger's reports sent to that service.

| Step | Result |
| --- | --- |
| The opt-in check: `createService`, then the reports of one swipe to the right | Created and sent at the first try. The probe showed "Last: right", its count went from 4 to 5, and the focus went from Button B to Row 33, in the list on the right: several items, as on a simulator |
| `remote swipe-left`, `remote swipe-down`, `remote swipe-up`, one after another | `dispatched` each time. The probe's summary went to `up=1 down=1 left=1 right=2` and its count to 8; the focus ended on Button B |

So the four swipes work on a physical Apple TV by the route built for simulators, and `remote` no longer refuses them there.

Afterwards, some minutes after the last swipe, `button lock` was sent to open Control Centre and put the device back to sleep; the screenshot that followed was refused with a zero-sized display, so the Apple TV was already asleep or went to sleep on that press alone, and no select was sent. Which of the two is not known. On the Mac's side the simulator's swipes, whose request is now shared with the device's, were run again on a tvOS 27.2 simulator: `remote swipe-down` and `remote swipe-up`, both `dispatched`.

Not shown: a swipe on the Home Screen or in another app; a swipe of another length or speed; a click of the surface; what happens to the created service when the connection closes (a second and a third swipe created it again without complaint); whether a sleeping Apple TV wakes on a swipe.

### The Apple TV's video stream, read packet by packet

On 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network, macOS 27.2.1, Xcode 27.2, on the human owner's word. The Apple TV had gone to its screen saver, a drawn scene that moves and zooms slowly; `frames` was let through its refusal by an experiment switch (`MANZANERO_TV_CAPTURE=1`), and each packet's header and first bytes were written out during the runs. This sends the device no input.

| Step | Result |
| --- | --- |
| `frames`, the video stream alone, seven runs of up to 8 seconds | The stream is not blank: 707 packets in the first second and a half of one run, 1462 packets and 251 pictures in 8 seconds of another, 0.4 to 0.9 MB for each saved image |
| The first saved frame of each run | A clean, whole picture of the screen, as a screenshot showed it, in the top-left 2400 × 1350 of the 3168 × 1792 frame, with a black line under it and grey to the right and below |
| A frame 0.27 s after the first | Clean too, and the scene had moved: the pictures that follow the key frame decode |
| Frames from about 0.4 s on, to 8 s | Damaged wherever the picture moves, and never repaired. Outlines of the scene appear in the grey area, at a larger scale than the first frame: the house and the pumpkins drawn about a third bigger, reaching the frame's edges |
| The packets | No gap in the sequence numbers in any run. One key frame (30 to 53 packets), then one slice for each picture, numbered 1, 2, 3 and so on without a jump. Pictures 1 to 7 are small (0.3 to 2.4 kB); from the eighth they are 7 to 29 kB, and their slice headers change from a reference set named in the stream's parameters to one written in the slice |
| The stream's parameters | 3168 × 1792 coded, 8 bits, no tiles, wavefront rows, one layer, no extension in the picture parameters or the slice headers. Nothing there announces a change |
| Each packet's RTP header extension | Four bytes: the number of packets of its picture, and a picture counter. Its profile word is `9011` on the key frame and again on one later picture, the first large one, and `9001` on the rest |
| The same with the device's system audio stream started first, in the same client session, as Apple's Device Hub does | The audio stream started, both stopped and were confirmed stopped, and the picture was damaged in the same way |

So the earlier reading was wrong: the picture does not leave the Apple TV blank. The "black rectangle on grey" of 2026-11-18 was a dark screen in the top-left of the frame, and its few packets were a picture that did not move. The device starts by sending the screen at 2400 × 1350 inside the larger frame and, some pictures later, sends it larger without a new key frame; this tool's decoder (VideoToolbox, fed the stream as it comes) predicts the larger pictures from the smaller ones and shows damage. Apple's Device Hub, which receives the same stream through AVConference, shows it right, so AVConference knows of the change. The picture marked `9011` in the header extension was taken for the signal; a longer capture showed that mark recurring on a period ([below](#the-same-stream-from-a-still-screen-kept-and-read-again)). The audio stream is not the cause, and its code was taken out again.

Not shown: what AVConference does at that picture (a new decoder, a rescaled reference, a request for a key frame); whether the device can be kept at the first scale; a still screen for more than the 2026-11-18 run; `record`; whether an iPhone's stream ever changes scale the same way.

#### The same stream from a still screen, kept and read again

Later on 2026-11-20, once the human owner allowed the device again, with the room to stay quiet: no audio stream, no volume key. The Apple TV had been asleep for some hours. The first `remote home` was refused before any input ("Apple HID service did not become ready; no input sent."), a screenshot timed out after 60 seconds, and `launch` answered; the Mac's log showed the sleeping device answering `remotepairingd`'s heartbeats after 1.4 to 34 seconds. A second `remote home` four minutes later was dispatched and a screenshot showed the tvOS probe, now in the light appearance. So a sleeping Apple TV can be slow enough to fail the 3-second readiness wait, and the press is then not sent.

One `frames` capture of the probe's still screen with `MANZANERO_TV_CAPTURE=1`: 6 seconds, 1318 packets, 302 pictures, cleanup confirmed, and the stream kept as it arrived (1.4 MB).

| Read from the kept stream | Result |
| --- | --- |
| The NAL unit types | 20 once (the key frame), 1 for every other picture, and the three parameter sets once. No second key frame, no new parameter set, no SEI |
| Picture sizes | The key frame 41 kB; pictures 1 to 7 from 0.4 to 1.5 kB; **picture 8, 32.6 kB, and picture 10, 30.5 kB**; then 1 to 2 kB each, with one of 12 kB and one of 16 kB, on a screen where nothing moves |
| The mark in the RTP header extension (`9011`) | On the key frame and then on one picture in about 25 (pictures 23, 48, 74, 99, …), each about 4.2 kB. It recurs on a period, so it is not the signal of the change of scale, as was guessed in the first run |
| The last saved frame | The probe's screen three times over, at three sizes: sharp at the smallest, in the top-left 2400 × 1350, and as outlines at a middle size and at the full frame's size, where "Row 30" to "Row 40" and "Col 21" to "Col 30" stand at the places they have on a screenshot |

So the device steps the picture's size up twice, at pictures 8 and 10, about a third of a second in, each time as an ordinary predicted picture as large as a key frame. A decoder that predicts them from the smaller picture it holds adds the larger picture's edges on top of it, which is what this tool's frames show. The sender must be predicting from its own picture scaled up, and nothing in the stream says so: the receiver that shows it right, Apple's AVConference, has to know by another way.

Not shown: that way. The leads are AVConference's receiver on the Mac, and the session event channel Apple's Device Hub gives each stream and this tool does not ([record](#device-hubs-screen-view-of-the-apple-tv)).

#### A second decoder, and VideoToolbox's resolution adaptation

On 2026-11-20, on the Mac only, from the stream kept in the capture above; nothing was sent to the device. The human owner asked whether the stream has an identifiable format.

| Step | Result |
| --- | --- |
| The stream identified by `ffprobe` (ffmpeg 's own software decoder, used here to read a file and for nothing else) | HEVC, Main profile, level 5.1, 3168 × 1792, 4:2:0, 8 bits; 301 pictures |
| The same stream decoded by ffmpeg, pictures 5, 12 and 200 | No warning or error, and picture 200 is the picture this tool saved: the probe's screen at three sizes on top of each other |
| VideoToolbox's exported names, read from the SDK | A resolution adaptation of its own: `kVTCompressionPropertyKey_VideoResolutionAdaptation` on the encoder, and on the decoder `kVTDecompressionPropertyKey_VideoResolutionAdaptationType`, `kVTDecompressionPropertyKey_ActiveVideoResolution` and `kVTDecodeFrameOptionKey_ActiveVideoResolution`, with the keys `kVTDecompressionResolutionKey_Width` and `…_Height` |
| What a decoder session for this stream says it supports | `ActiveVideoResolution`, a width and a height, readable and writable and allowed among a frame's own options; `VideoResolutionAdaptationType`, with no description of its values |
| The stream decoded with `VideoResolutionAdaptationType` set to 1 or 2 and `ActiveVideoResolution` set on the session before pictures 0, 8 and 10 | Accepted each time, and the picture is unchanged |
| The same with the active resolution among each frame's options (`VTDecompressionSessionDecodeFrameWithOptionsAndOutputHandler`), as 2400 × 1350, 2880 × 1620 and 3168 × 1782 | Every picture refused, error -12911 |
| The same as 2400 × 1344, 2880 × 1632 and 3168 × 1792 | Every picture decoded, and the picture is unchanged |

So the format is identified and standard, and a standard decoder gives the damaged picture: this tool's decoding is not at fault, and the stream is not complete by itself. The missing part has a name: the sender uses VideoToolbox's resolution adaptation, in which the encoder changes the picture's size between key frames and the decoder is told the active size of each frame. The decoder on this Mac takes that option for each frame and checks its sizes, since some are refused, but the three sizes tried, which were measured from the saved frame, did not change what it decodes.

Not shown: the values Apple's receiver passes (the sizes, the adaptation type, and whether something else has to be set when the session is made), which are in AVConference's code; and how the receiver learns each frame's size, which is not in the packets' header extension and not in the stream.

#### The Apple TV's video, fixed: an offer without resolution adaptation

On 2026-11-20, first on the Mac only, then on the Apple TV 4K (tvOS 27.2) with the tvOS probe in front, woken with one `remote home` and put back to sleep afterwards; no audio stream and no volume key.

On the Mac: the texts around VideoToolbox's resolution adaptation in the system libraries name it in the feature lists AVConference negotiates (`RVRA1`, `VRAE`, "Unknown vra reference scaling method", `vra_width`, `vra_height`). The screen-sharing settings this tool's offer is made from carry, for the HEVC payload, the feature list `FLS;VRAE:0;SW:1;`: the tool, through Apple's negotiator, was offering the adaptation to the device. With `VRAE` taken out of the negotiator's local video configuration (`mediaNegotiator.localSettings`, `mediaConfigurationForMediaType:` 2 and 3, `videoFeatureStrings`), the negotiator's blob shrank from 205 to 193 bytes, and the offer made again from it (`setMediaBlobCompressed:`, `createOffer`) from 495 to 483.

| On the Apple TV 4K | Result |
| --- | --- |
| `frames`, 6 seconds, with that offer | 1296 packets, 301 pictures, cleanup confirmed. The saved frames are the probe's screen as the screenshot before showed it, whole, across the frame |
| The kept stream | One key frame of 43 kB, then pictures that grow from 0.4 to 8 kB over the first second: no picture of key-frame size at the 8th or the 10th, so no step in size |
| `frames` with no switch set, after the change was made the behaviour for an external display | `captured`, 223 pictures in 5 seconds, frames saved at 3168 × 1782: the display's shape in the stream's width, without the ten black rows the frame ends with |
| `record tv.mp4 5 --backend coredevice` | `recorded`, 77 source frames, `frameDecoded: true`, `audio: false`; an H.264 movie of 3168 × 1792 and 78 frames whose picture at 3 seconds is the probe's screen. The movie keeps the ten black rows at the bottom |

So recording and `frames` work on the Apple TV: its pictures were damaged because this tool offered a feature its decoder cannot follow, and without the offer the device sends a stream any decoder shows right. The refusal is gone. The change applies to an external display only; a phone's offer is as it was.

Not shown: a screen that moves (the earlier, damaged runs were of the screen saver; these were of a still screen); a longer recording; the same offer to an iPhone, whose recordings have not shown this damage; whether the device now holds one picture size or changes it with key frames, over more than six seconds.

### The Apple TV's small ones: a moving recording, chosen swipes, sleep and wake

Later on 2026-11-20, the Apple TV 4K (3rd generation, tvOS 27.2, in English) over the network, macOS 27.2.1, Xcode 27.2, on the human owner's word, with the tvOS probe in front except where said. The device was asleep (a screenshot failed with the zero-sized display); one `remote home` woke it. The Mac's connection read `connected` before and after every run of accessibility commands.

| Run | Result |
| --- | --- |
| `record tv.mp4 5 --backend coredevice`, after `record` learned to drop the rows below the screen as `frames` does | `recorded`, 71 source frames; an H.264 movie of 3168 × 1782 and 72 frames, whose picture at 3 seconds is the probe's screen as a screenshot shows it, to the bottom edge |
| One MCP session: `record_screen` for 60 seconds with `recording_backend: coredevice`, and 36 `press_remote` arrows about a second apart during it | `recorded`, 950 source frames, a movie of 60 seconds, 3168 × 1782 and 951 frames. A picture every five seconds shows the focus in a different place and the probe's count rising from 12 to 39, each picture whole. The arrows were answered while the recording ran |
| `record_screen` for 3 seconds from Claude Code, after the human owner reconnected the server | `recorded`, 47 source frames, 3168 × 1782. Before the reconnection the host's server, an older build, still refused recording on an Apple TV |
| Seven swipes of nine tenths of the surface in 2 seconds each, sent together through that older server | Dispatched in order; the probe's count rose by one |
| Two `batch` runs of swipes down and up in the probe's list, a `tree` after each for the row in focus | See the table below. `serviceDirectory: reused-port` for every tree but the first (`reused-saved-port`), and `ownTunnelUnavailable` saying the framework does not list the device |

Rows the focus moved, by the swipe's `--travel` and `--seconds`, one swipe each, in the order run:

| Travel | Seconds | Rows moved |
| --- | --- | --- |
| 0.5 | 0.2 | 1, then 1 |
| 0.9 | 0.1 | 0, then 0, then 2 |
| 0.2 | 0.2 | 1 |
| 0.9 | 1.0 | 4, then 4, then at least 2 (it left the list at its last row) |
| 0.9 | 0.04 | 0 |
| 0.9 | 2.0 | 3 |
| 0.9 | 0.5 | 4 |
| 0.9 | 0.2 | 5 (to the list's last row) |
| 0.5 | 1.0 | 2 (to the list's last row) |
| 0.5 | 0.5 | 2 |

So on the device a longer swipe moves the focus further, as on a simulator, and a quick one does not: at a tenth of a second or less a swipe of nine tenths moved nothing twice in three, where a simulator moved furthest for the quickest. Before these, twelve single swipes read by OCR alone showed the probe counting one move for most swipes however far the focus went, so the count does not measure a swipe.

**Sleep and wake.** `button lock` with the probe in front opened Control Centre with Power Off in focus, seen on a screenshot and read by OCR (`Power Off`, `Audio`, `Do Not Disturb`, `Sleep Timer`). Control Centre is in no tree, and `press --label "Power Off"` found it by neither route: the Inspector's cursor does not reach it.

| Run | Result |
| --- | --- |
| `remote select`, sent by hand about a minute after the screenshot that showed Power Off in focus | The probe recorded `select:a`: the select pressed its Button A. The device stayed awake |
| The first build of `remote sleep` with the probe in front: `button lock`, a screenshot, Power Off found by OCR on a white tile with dark text (`background` 1, `darkest` 0.11), then the select at once | `not-asleep`: the probe recorded a second `select:a`. With an app in front the select, a keyboard usage, goes to the app although Control Centre is on the screen |
| The same build with the Home Screen in front and the focus moved to the Probe TV icon first, as the human owner chose | `asleep`, `pressed: lock, select`; a screenshot then failed with the zero-sized display |
| `remote sleep` again, on the sleeping device | `already-asleep`, nothing pressed |
| `remote wake` | `awake`, `pressed: home`; the Home Screen with the focus still on the Probe TV icon |
| `remote wake` again | `already-awake`, nothing pressed |
| `launch` of the probe, then `remote home` | The Home Screen with the focus on the Probe TV icon. Earlier the same press had left the focus on the first icon, which had last had it |
| The final `remote sleep`, which presses Home first, with the probe in front | `asleep`, `pressed: home, lock, select`. The device was left asleep |

The probe registers no URL scheme, so `open-url` did not run; the human owner chose to open nothing else.

Not shown: `remote sleep` in another language (it looks for the words `Power Off` and stops before the select without them); a select that misses with the Home Screen in front, which would open the icon in focus; sleep from a screen saver; a `remote wake` of a device asleep for hours; a recording longer than a minute, or of video; why a quick swipe moves nothing on the device.

### An accessibility tag for Power Off, a URL for the probes and a recording with music

The same day and setup, on three questions from the human owner, who asked for the Music app and its sound for the last one. The Apple TV 4K was asleep; `remote wake` woke it.

**Where Control Centre is in accessibility.** With Control Centre open over the tvOS probe:

| Run | Result |
| --- | --- |
| `tree` | The frontmost application is PineBoard, 24 nodes. One has the identifier `PBControlCenterWindow`, marked not visible; nothing names Power Off |
| `tree --pid` with the PID of `TVSystemUIService`, from `processes` | 44 nodes: the status items, and Control Centre's tiles by identifier: `sleep` (label `Power Off`, a 218-point square, visible), `wifi`, `dnd`, `airplay`, `sleep-timer`, `game-controllers`, `ax`, `restrictions`, `search`. No node is marked as focused |
| The same tree with Control Centre closed | 9 nodes, no `sleep` |
| `press --id sleep --pid` with that PID | Refused before any input: "requested PID differs from display-centre process and does not host it" |
| `remote sleep`, changed to read that tree for `sleep` and the screenshot at the element's frame for the focus, with the Music app in front | `asleep`, `pressed: home, lock, select`, `powerOffTile` background 1.0 and darkest 0.11 |

So the sleep command no longer reads words off a picture and no longer depends on the device's language; the picture is kept for the one thing the tree does not say, which tile has the focus.

**A URL for the probes.** Both probes got a URL scheme and an element that shows the URL they were opened with.

| Run | Result |
| --- | --- |
| `build-run` of the iOS probe on the project's iPhone simulator (iOS 27.2), then `open-url manzanero-probe://hello?n=1` | The system asked "Open in “Probe”?"; the tree read the prompt and `press --label Open` answered it |
| A second `open-url manzanero-probe://again` there | No prompt; `probe.url` read `2 manzanero-probe://again` |
| `build-run` of the tvOS probe on the Apple TV 4K, signed with what the Mac had, then `open-url manzanero-probe-tv://hello?n=1` | `outcome: success`, no prompt; the screen read `URL: 1 manzanero-probe-tv://hello?n=1` |

`open-url` is Apple's own `devicectl device process openURL` (and `simctl openurl` on a simulator); the tool adds the dry-run plan, the MCP tool, the handoff pause and the error categories around it, nothing to the opening itself.

**A recording with music playing.** `launch com.apple.TVMusic`, then one `remote play-pause`, started a song with its lyrics on the screen. `record music.mp4 20 --backend coredevice`: `recorded`, 302 source frames, an H.264 movie of 20 seconds, 3168 × 1782 and 303 frames. A picture every 2.5 seconds shows the lyrics advancing over a moving background, each picture whole. The movie has one stream, the video: `audio: false`, and no sound. A second `play-pause` paused the song, confirmed by the elapsed time standing still in two readings.

Not shown: the URL probe on a phone; `remote sleep` on a device in another language; sound, which the tool does not record.

### Sleep by an accessibility press of Power Off

The same day and device, after the human owner said the command shall work. The guard that lets a selector action name only the frontmost process or its host was opened for one case: `remote sleep`, for the system UI process. `--pid` on the command line is as narrow as before.

| Run | Result |
| --- | --- |
| `remote wake`, `launch` of the tvOS probe, then `remote sleep` | `asleep`, `pressed: lock, power-off`: the power button, then Power Off activated by accessibility in `TVSystemUIService`. No Home press and no select |
| The same again, with the probe's counters read before (`Last: up`, `Count: 2`) | `asleep`, `pressed: lock, power-off` |
| `remote wake` a few seconds after that sleep | `not-awake`: Home was pressed once and four screenshots over about twelve seconds were all refused. The next `remote sleep` said `already-asleep` |
| `remote wake` about a minute later | `awake`, `pressed: home` |
| `launch` of the probe and its counters read again | `Last: up`, `Count: 2`: the probe received nothing from either sleep |
| A third `remote sleep` | `asleep`, `pressed: lock, power-off`; a screenshot then failed with the zero-sized display. The device was left asleep |

Not shown: sleep with the Home Screen or a screen saver in front; a device in another language; why a Home press seconds after a sleep does not wake the device.

### A pairing of the tool's own, and the Apple TV on the tool's tunnel

Still 2026-11-20, the Apple TV 4K (tvOS 27.2) on the network, macOS 27.2.1, Xcode 27.2, on the human owner's word to try the pairing. Nothing but the pairing conversation and accessibility commands was sent.

| Run | Result |
| --- | --- |
| `dns-sd -B _remotepairing._tcp` | Six devices, each resolving to its host name on port 49152, the Apple TV 4K among them. `_remotepairing-manual-pairing._tcp` advertised by nobody |
| A plain TCP connection to the Apple TV's port 49152, at its network name and at its address in Apple's tunnel | Both connect |
| The handshake and a pair-verify with a new identity, to port 49152 over Apple's tunnel address | The handshake is answered; pair-verify is refused, as it should be for an unknown host |
| Pair-setup's first message on that same connection, twice, the second time with Settings › Remotes and Devices › Remote App and Devices open on the television | The device ends the connection both times; nothing appears on the television |
| `dns-sd` again with that screen open | `_remotepairing-manual-pairing._tcp`, one instance named as the device is, on another port, with the device's name and model in its TXT record. That port also answers on the address in Apple's tunnel |
| Pair-setup to that port | The television shows "Authenticate. Your authentication code is:" and six digits. With the code, the device's SRP proof matched, it took the host's record and returned its own identifier and a 32-byte key |
| Pair-verify with that identity on a new connection to the same port, then the request for a listener | Verify accepted, the device's signature valid against the key it gave; the listener refused: "Unsupported operation: Tunnel listener creator not set" |
| The same on port 49152 | Verify accepted, signature valid, a listener port given |
| `tree`, with the pairing stored | `serviceDirectory: own-tunnel`, `ownTunnelLink: paired`, 114 nodes: TLS with the pre-shared key through the Network framework, the greeting, the tool's network stack and the service directory read on the tool's own tunnel |
| In `batch`es on that tunnel: `tree`, `scroll --search 30` to row 20, `wait --until value`, `set-value`, `press --id probe.tv.row.20 --index 1` | All `own-tunnel` and `paired`; the probe showed `Text: paired` and `Last: select:row-20`. A press of a row inside a list no longer needs Apple's tunnel |
| The Mac's `remoted` log for the Apple TV's own entry, the whole day, and `remotectl dumpstate` | No "Device connection interrupted" and no new handshake for that device, during these runs or before them; `connected`. The log has such lines every half minute for other devices on the network, so it has to be read for the one device. The first reading of it was worthless: `log` is a builtin of the shell the commands ran in, the call failed with its error hidden, and "0 lines" was taken for an answer; this row is from `/usr/bin/log` |
| `pair`, then `pair --forget`, then `pair --pin-file` with the pairing screen closed, then `tree` | `already-paired`; `forgotten`; refused with the hint to open the pairing screen, nothing changed; the tree back on Apple's tunnel (`reused-saved-port`), saying the framework does not list the device |
| `pair --pin-file` with the pairing screen open, the code read from a screenshot and written to the file | `paired`; the next `tree` `own-tunnel` and `paired` |
| Two swipes on the Home Screen, `--travel 0.9 --seconds 0.5`, up then right | The name under the icon in focus changed each time: a swipe works outside the probe |
| `remote sleep` with the Home Screen in front | `asleep`, `pressed: lock, power-off` |

Three runs failed for reasons of their own, and say nothing against the route: a `scroll` to a row the list had not loaded (it needs `--search`), a batch run while the Apple TV showed its screen saver, and a `wait` written with a wrong option.

The device now lists the host `manzanero` twice, once for each pairing made; the first one's identity was deleted from the Mac by `--forget`.

Not shown: the comparison that would prove the gain on the same day, a directory read on Apple's tunnel with its interruption in the log beside one on the tool's tunnel without (the day's commands on Apple's tunnel all reused a saved port and read no directory); a phone paired this way; the tunnel after the Apple TV restarts or after days; two processes pairing at once; a long session on the paired tunnel; the device unpaired from its own settings while the Mac keeps the identity (pair-verify should then be refused and the command fall back to Apple's tunnel).

### Sound in a recording

On 2026-11-20, the iPhone 13 mini (iOS 27.2.1) on its cable and the Apple TV 4K (tvOS 27.2), macOS 27.2.1, Xcode 27.2, the human owner at the phone for part of it.

| Run | Result |
| --- | --- |
| The audio stream started beside the video on the phone, nothing playing | Both streams start, both stop and are confirmed gone. RTP payload type 101, 48 kHz; a packet every 10 ms, each with the same four-byte payload (`00 68 34 00`); a sender report about every second |
| The same with the iOS probe's first tone (a sine wave from `AVAudioEngine`) | The same silent packets. The human owner heard no tone: the player was broken |
| The human owner opened Device Hub's screen view of the phone and played a film in Apple's TV app | Sound came from the phone and from the Mac. The player had started muted. Device Hub's two start requests, read from the Mac's log: audio first, then video, one client session, no sender port named, an event channel with each |
| The tool's recording while the TV app played, twice | The first 8 packets carry sound (about 380 bytes each), every later one is the silent four bytes. The human owner saw the player mute itself when the recording started |
| The sender port left out of the tool's audio request, as Device Hub leaves it out | No difference |
| The probe's second tone (four beeps from `AVAudioPlayer`), which the human owner heard | 394 of 656 packets carry sound, from the first to the last; the others fall in the gaps between beeps |
| Those packets decoded on the Mac with AudioToolbox, as AAC-ELD at 48 kHz, stereo, 480 samples a packet, each payload taken whole | All 656 decoded, none refused; the peak is half of full scale, the level the probe plays at. The human owner was sent the sound |
| `record sound.mp4 8 --backend coredevice --audio` on the phone with the beeps | `recorded`, `audio: true`, 811 packets, none lost or refused; a movie with an H.264 picture of 8 seconds and an AAC track of 7.79 seconds at 48 kHz stereo, peak −4.5 dB |
| The same for 5 seconds on the Apple TV 4K, the silent tvOS probe in front | `recorded`, `audio: true`, 512 packets, none lost; an AAC track of 4.82 seconds beside the 3168 × 1782 picture. The device was woken for it and put back to sleep |
| A recording attempted while Device Hub's screen view of the phone was open | Refused: "Another media session is active"; the phone's status showed two sessions that were not the tool's |

So the stream works as Apple's own client uses it; the event channel is not needed for sound; and an app can mute its own player when the screen is captured, which no request of the tool's causes or can undo.

Not shown: sound on the Apple TV with something playing; picture and sound in step; a long recording and its drift; an iPad; whether the phone's volume at zero empties the capture (four volume steps up made no difference to a silent capture, which says little).

### The Inspector's cursor, the whole hierarchy and a press through the shim

On 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network with the tvOS probe in front, macOS 27.2.1, Xcode 27.2, on the human owner's word. It was asleep; one `remote home` woke it. Every request was first read from Apple's own client, the Inspector's device manager (`XDMDeviceTransportBased` in `AccessibilityAuditDeviceManager.framework`, read with `otool`), and the tvOS simulator runtime's copy of `axauditd` gave the attribute names. After each new request the device's crash reports were listed: none for `axauditd` in the whole session. Nothing made the Mac's connection go stale.

How Apple's client writes each request: `deviceInspectorMoveWithOptions:` takes a dictionary `direction`, `includeContainers`, `allowNonAX` written by the framework's encoder (each value wrapped as `passthrough`); `deviceInspectorFocusOnElement:` and `deviceInspectorPreviewOnElement:` an encoded element; `deviceInspectorSetMonitoredEventType:`, `deviceInspectorShowVisuals:`, `deviceInspectorShowIgnoredElements:` and `deviceFetchSpecialElement:` a plain number; `deviceFetchElementAtNormalizedDeviceCoordinate:` a plain point value; `deviceElement:valueForAttribute:` the encoded element and attribute; `deviceElement:performAction:withValue:` the encoded element, the encoded attribute and a null; `deviceElement:setValue:attribute:` the encoded element, value and attribute. Directions, from the reference project: 3 previous, 4 next, 5 first, 6 last.

| Step | Result |
| --- | --- |
| One move (direction 4) with nothing sent before it | No answer in four seconds |
| The same after `deviceSetAppMonitoringEnabled:` true and `deviceInspectorSetMonitoredEventType:` 0 | The device sent `hostInspectorCurrentElementChanged:` with a focus object: the element (`probe.tv.button.a` by its identifier), the caption "Button A, Button", and four sections naming the attributes it has: `Label`, `Value`, `Header`, `TraitsHumanReadable`, `Identifier`; the action `AXAction-2010` (Activate); `ElementClassName`, `ElementMemoryAddress`, `ElementViewControllerClassName`; `_AXHierarchyElementsAttribute` |
| Each listed attribute asked for, given back as the device wrote it, on three elements in turn | `Label` "Button B", `Identifier` `probe.tv.button.b`, `TraitsHumanReadable` "Button", the class `SwiftUI.AccessibilityNode`; `Value` and `Header` empty. Three moves and 27 reads in 1.6 seconds |
| `_AXHierarchyElementsAttribute` on the element under the cursor | The whole hierarchy in one answer, about 14 KB in a tenth of a second: 20 nodes (22 another time), each with its element, a description ("Button B Button"), a role and, for 11 of them, the identifier. It stops at the two lists: the table and the scroll view are leaves, and no row or column is in it. The tool's own `tree` reads 112 nodes on this screen |
| The same four attributes on an element taken from that hierarchy, not under the cursor | Empty, all four: values are answered for the cursor's element only, as the reference project notes say |
| `deviceFetchSpecialElement:` 0 and 1 | 0 an element with no identifier; 1 `probe.tv.col.12` each time, whatever had the focus |
| The cursor moved until it met an element again, 83 moves | Once: every element, 82 of them, in 7.2 seconds, with all 40 rows and 30 columns of the two lists, and both lists were left scrolled to their ends. In every other run, nine of them, two after the probe was terminated and launched again (it came back with its lists still at their ends): 12 elements in about a second, the lists skipped. What made the one run enter the lists was looked for (the hierarchy request and the special elements were sent again before a walk) and not found |
| The focus on screen, on screenshots before and after every run | Unmoved, on Button B. The cursor is not the focus: it also stayed where it was between one connection and the next |
| The cursor moved to `probe.tv.button.a`, then `deviceElement:performAction:withValue:` with the Activate attribute as listed and a null | An acknowledgement. The probe showed "Last: select:a", its count went from 3 to 4, and the focus stayed on Button B |
| What the probe's text field lists | The same attributes as a button, none of them settable |

So, for the decision this was run for:

- **Works on this route, with no reset:** a press of an element found by the cursor, by identifier or label, without moving the focus; the labels, identifiers and traits of the elements the cursor reaches; the hierarchy's outline in one request.
- **Does not:** a tree like the tool's own. Values are read one element at a time and only under the cursor; the hierarchy has no label, value, frame or focus mark and stops at lists; no request seen gives a frame or says which element has the focus.
- **Not dependable:** the cursor's reach into lists, and when it does go in it scrolls them, so reading the screen changes it.
- **`set-value`:** the field offers nothing settable; no way seen.

Not shown: why one walk entered the lists; `deviceInspectorFocusOnElement:` to put the cursor on an element from the hierarchy without walking; ignored elements and the autodrill setting; a press of a row inside a list; any screen other than the probe's; an iPhone.

### The commands that had not run on the Apple TV

On 2026-11-20, the Apple TV 4K (tvOS 27.2) over the network, macOS 27.2.1, Xcode 27.2, on the human owner's word. It was asleep; one `remote home` woke it. The connection never went stale.

| Command | Result |
| --- | --- |
| `details` | Exit 0, tvOS 27.2 |
| `processes` | Exit 0, 356 processes |
| `files list <probe> .` | `Documents`, `Library`, `SystemData`, `tmp`. A path of `/` is refused as a usage error, as on a phone |
| `files push`, then `files pull` | A small text file pushed to `Documents` and pulled back byte-identical |
| `reports list` | 7 entries |
| `console <probe> --seconds 4 --terminate` | Exit 0, 151 bytes of standard output |
| `last-crash --bundle <probe>` | Exit 0, `found: false` |
| `terminate <pid>` | Success, with the probe's PID from `processes` |
| `build-run … ProbeTV` | Refused at first: the command gave xcodebuild `platform=iOS`. With the destination given by identifier alone and the platform checks widened to the device families, it built, installed and launched the tvOS probe |
| `uninstall <probe>`, then `install <built app>` and `launch` | Each succeeded; `apps` did not list the probe in between |
| `handoff "…" 20 --until visible --id probe.tv.last` | `observed`, `verified: true` |
| A session through MCP: `wait_for_element` (focused, on Button A), `press_remote right`, a wait for the focus on Button B, `press_remote select`, a wait for the probe's last command to read `select:b` | Every step as asked. The focus was read before the select |

Later the same night, one `batch` in the probe: `scroll --id probe.tv.col.30 --search 80 --toward right` (`postcondition-verified` in 18 steps), `scroll --id probe.tv.col.1 --search 80 --toward left` (19 steps), and `remote play-pause --hold 1`, which the probe recorded as one `play-pause` and which did not leave the app. Those two searches cross the probe's whole strip of thirty columns, so a sideways search of more than twenty steps cannot be made with this probe.

Not run: `open-url`, which needs an address the human owner chooses; `build-run` on the iPhone since its destination changed. `reports get` ran later the same day: `reports get ota_patch.txt <file>` downloaded the 29,606-byte file, and `reports list Retired` listed 199 reports.

A caveat found with it: the device moves crash reports from the top directory into `Retired` within the hour, and `last-crash --process axauditd` reads the top directory only, so it answers `found: false` once they have moved. During the shim runs of that day it was asked after every new request and answered `found: false` each time; `reports list Retired` afterwards showed no `axauditd` report later than the two of 00:02 and 00:03 UTC, so the answer was true, but `last-crash` alone does not prove it an hour later.

### Apple TV simulator: Power Off, held keys, searches in four directions and swipes

On the evening of 2026-11-18, on one Apple TV simulator at 1080p (tvOS 27.2), macOS 27.2.1, Xcode 27.2, with the build from `main` plus the changes named here. No device was used.

**Power Off.** `remote home --hold 1.5` opened Control Centre with the focus on its icon in the top bar; `remote down` moved it to Power Off, read from a screenshot; `remote select` put the simulator to sleep. PineBoard logged `Sleep requested by com.apple.TVSystemUIService` and `'Sleep:UserSystemMenu'`. Afterwards `simctl` still listed it `Booted`, three screenshots were black, and the tree showed `PineBoard` with a `PBHotBlackWindow` node (29 nodes), which the awake Home Screen's tree does not have. `displays` said `active: false`, `backlightState: off`, as it does awake. Control Centre, left alone, had closed by itself within a minute on the first try.

**Nothing woke it.** Sent one at a time, each dispatched and each followed by a black screenshot or an unchanged tree: `tree`, `apps`, `remote up`, `select`, `menu`, `play-pause`, `home`, `button lock`, `button home`, `remote home --hold 1.5`, `key space`. For a Home press `backboardd` logged `Home page:0xC usage:0x40 downEvent:1`, then `destinations:<none>`. `launch` of the probe failed with "System is asleeping - foreground app launch forbidden". `shutdown` then `boot` brought the Home Screen back, both times it was tried.

**Held keys.** `remote --hold` now takes `select` and the arrows, sent as a key down and a key up the hold apart. The tvOS probe gained a focusable `Hold` element that records `select-long` after a one-second press. With the focus on it: a plain `remote select` and `--hold 0.5` recorded nothing; `--hold 1.5` and `--hold 1.2` recorded `select-long` each (summary `select-long=2`). `remote down --hold 2`, with the focus on row 1 of the list, left it on row 18, read from a screenshot: a held arrow repeats.

**Searches.** The probe gained a strip of thirty columns along the bottom. With it on screen the existing search downward failed ("the list stopped moving after 3 search step(s)"): the lowest element was a column of the strip, the strip itself (as wide as the display) was the rightmost element, hidden unnamed backdrops the size of the display were candidates, and the tree was read while the list was still moving. After the changes described in the [guide](direct-accessibility.md#searching-a-list-that-loads-its-rows---search): `scroll --id probe.tv.row.35 --search 80` verified in 10 steps; `--id probe.tv.row.1 --search 80 --toward up` in 28 and 27; `--id probe.tv.col.28 --search 80 --toward right` in 14 and 16; `--id probe.tv.col.1 --search 80 --toward left` in 18, twice; `--id probe.tv.row.99` stopped at row 40 as `target-unresolved`. After the searches up and down the strip still began at column 1.

**The remote's touch surface.** Later the same evening, with a scratch probe sending raw XPC to the simulator's `dtuhidd` (removed afterwards). On `com.apple.coredevice.feature.remote.universalhid`, `supportedDevices` answered `trackpad`, `digitizer`, `touchSensitiveButton`, `appleTVRemote`, `mouse`, `keyboard`; `connect` with usages as int64 was refused ("Expected to decode UInt16 but found a OS_xpc_int64") and the connection interrupted; with unsigned usages it answered `errorContainer` code 4866 and `connectedServices` on the other service still listed four products. The daemon's log held `UniversalHIDServiceDDIPayload.Request {removeService serviceID = mainPointer(0x300)}`. On `universalhidservice`: `addService` and an unknown key were refused as "Invalid number of keys found"; `removeService {}` and `createService {}` as "Key '_0' not found"; `removeService {_0: {}}` as "Expected to decode UInt64"; `createService {_0: {}}` answered CoreDevice error 15001, "A HID Service description requires a primary usage". `createService` with `_ServiceID` 1792, `PrimaryUsagePage` 13, `PrimaryUsage` 5, a product name and one usage pair answered `{"serviceID":1792}`; `connectedServices` then listed it, and `backboardd` logged `Services added: … eventSource: externalAccessory; primaryUsagePage: 0xD; primaryUsage: 0x5; name: CD-Manzanero touchpad`. Nine 58-byte reports to that ID, a contact moving down, were delivered to the probe ("destinations for Pointer event: (… ProbeTV …)", and `5 Digitizer 15 Pointer 5 GameController` in the attention log): focus went from Button A to the text field and the probe recorded `down` once.

Built as `remote swipe-up`, `swipe-down`, `swipe-left`, `swipe-right` and run from the CLI after a restart of the simulator, the focus read from the tree after each of eleven swipes, starting on Button A: down to the text field; up to Button B; down to the text field; up to Button B; right to row 3; down to row 7; down to row 11; up to row 7; left to the first Twin button; right to row 7; left to the first Twin button. The probe's summary afterwards: `up=3 down=4 left=2 right=2`. On the sleeping simulator a swipe and a button event on usage page 1, usage 0x83 changed nothing.

Not shown: any of this on a physical Apple TV, a search on an iPhone or iPad, a list whose rows do not share an edge, a held arrow's repeat rate, and a click of the touch surface.

#### A swipe of a chosen length and duration

On 2026-11-20, `manzanero-research-tv` (Apple TV 4K (4th generation) at 1080p, tvOS 27.2), the tvOS probe in front, macOS 27.2.1, Xcode 27.2. `remote` gained `--travel` (the swipe's length as a share of the touch surface, 0.05 to 0.9, default 0.5) and `--seconds` (its duration, 0.04 to 2, default 0.2). With the focus in the probe's forty-row list, one `remote swipe-down` after another, the focus read from a tree after each:

| Travel | Seconds | Rows the focus moved |
| --- | --- | --- |
| 0.1 | 0.2 | 1 |
| 0.3 | 0.2 | 2 |
| 0.5 (the default) | 0.2 (the default) | 4 |
| 0.9 | 0.2 | 9 |
| 0.5 | 0.05 | 10 |
| 0.5 | 0.6 | 3 |
| 0.5 | 1.5 | 2 |
| 0.05 | 0.04 | 0, six rows from the list's end |

So both count: a longer swipe goes further, and the same length goes further fast than slow. From Button B, outside a list, travel 0.1 and 0.3 each moved one item down, 0.5 three, and 0.9 went to the strip at the bottom.

Not shown: the same on a physical Apple TV, which is not to be sent anything for now; other directions; a second run of each, so the numbers are one sample; the shortest swipe away from a list's end.

Later: the physical Apple TV ran swipes on 2026-11-20 and 2026-11-22, and the other directions ran on a simulator on 2026-11-23, below.

#### Swipes upward and sideways on a simulator

On 2026-11-23, `manzanero-research-tv-4k` (Apple TV 4K (4th generation), tvOS 27.2), the tvOS probe in front, each swipe sent with `--report-focus` so its own receipt named where the focus went (the default duration is 0.4 s since 2026-11-22). Upward through the forty-row list, from row 16, one after another:

| Travel | Seconds | Focus after | Rows |
| --- | --- | --- | --- |
| 0.9 | 0.4 | row 10 | 6 |
| 0.3 | 0.4 | row 8 | 2 |
| 0.6 | 1 | row 5 | 3 |
| 0.9 | 2 | row 1 | 4, the list's top |

Sideways along the thirty-column strip, from column 10, one after another:

| Swipe | Travel | Seconds | Focus after | Columns |
| --- | --- | --- | --- | --- |
| right | 0.9 | 0.4 | column 14 | +4 |
| left | 0.3 | 0.4 | column 13 | −1 |
| right | 0.6 | 1 | column 16 | +3 |
| left | 0.9 | 2 | column 12 | −4 |
| left | 0.9 | 0.4 | column 7 | −5 |

So upward and sideways behave as downward did: a longer swipe goes further, and the same length goes further fast than slow. One sample each. On the way, `remote left` from row 1 kept the focus in the list, and a held `remote down --hold 3` ran from row 30 past the list's end into the strip.

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

### Quarantine after an uncertain release

**2026-11-17**, `manzanero-research-duo-fold` (iPhone Duo, iOS 27.2, folded), headless; host macOS 27.2.1, Xcode 27.2. Settings in front, then the [probe app](probe-app.md). No physical device was contacted. Behaviour: [quarantine](native-input.md#quarantine-after-an-uncertain-release).

| Command | Observed |
| --- | --- |
| `long-press 0.5 0.5 8`, SIGINT after 2 s; then `tap 0.5 0.5` | Exit 130 with the interruption diagnostic; the tap was `dispatched`: an interrupted input releases and leaves no mark |
| `long-press 0.5 0.5 8`, SIGKILL after 2 s; then `tap`, `key escape` | Exit 137; both refused: `code: device-quarantined`, `inputSent: none`, `retry: after-action`, `action: clear-quarantine`, naming `the previous owner (pid …, long-press) exited without releasing the device` and the time |
| `tree`, `screenshot` while quarantined | 103 labels; exit 0: observations and captures still run |
| `clear-quarantine`, then `tap`, then `clear-quarantine` again | `status: cleared` with the reason; `dispatched`; `status: not-quarantined`, `reason: null` |
| Probe app in front: `long-press 0.5 0.5 8`, SIGKILL after 2 s, then `tree` about 10 s later | `probe.touch.summary`: `began 1`, `ended 1`, `cancelled 0`, `active 0`: the simulator ended the contact itself after the sending process died |
| `clear-quarantine` as the first command after a kill, in the first version | `not-quarantined`, because only a new owner looked for the dead owner's note; the next input would then have been refused. `clear-quarantine` now looks for it too (unit-tested; in the live repeat the mark had already been written by a refused input) |

Not shown: anything on a phone, including whether it keeps a contact down after its connection closes; a failure that the bridge reports as an unknown outcome (only injected in tests); an MCP server killed mid-input.

### MCP calls sent without waiting

**2026-11-16**, `iPhone 17e` simulator (iOS 27.2) with Settings in front; macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2, MCP Swift SDK 0.12.1. Each session was a fresh `manzanero mcp` process driven by a script that wrote JSON-RPC lines to its stdin and read its stdout; the same script ran against the binary before and after the change ([contract](mcp.md#calls-sent-without-waiting)).

| Sessions | Before | After |
| --- | --- | --- |
| `initialize`, `notifications/initialized` and one `tools/call` written at once, without waiting for the `initialize` answer: `list_keyboard_layouts` ×10, `list_displays` ×15, `doctor` ×10 | 7 of 35 answered (0, 5 and 2); the rest got no response at all within 5–20 s | 35 of 35 answered |
| The same with the `initialize` answer awaited first (`list_keyboard_layouts` ×10, `list_displays` ×15 and ×5, `doctor` ×1) | 26 of 26 answered | 5 of 5 answered |
| `long_press` (1.5 s), `tap`, `get_ui_tree`, `tap` written at once to the simulator; correct when every call succeeded, the three mutations were answered in the order sent and the tree after the tap sent before it | 19 of 30 correct; in 11 a later call finished first, such as the second `tap` before the first (`[1, 3, 4, 2]`) or the first `tap` before the long press (`[2, 1, 3, 4]`) | 30 of 30 correct |

Cause of the missing answers: the SDK starts each request in a task of its own, so a call could reach its strict initialization check before the `initialize` handler had recorded the session; the SDK discards that rejection instead of answering it. Clients that await the `initialize` answer never met it, which is why a pause after initialization hid it; the earlier session [fed from a file](#the-new-tools-over-mcp) did not wait. Cause of the order: the same per-request tasks. Local tests now cover both through a raw in-memory client: requests written behind a held `initialize` are answered, and with a fake command service, per-device order, observations that wait for earlier mutations, an earlier wait that does not hold up a later tap, cancellation of a waiting and of a running call, a capture that lets later input run, a pending handoff that releases its device, and shutdown of waiting calls. With the ordering disabled, four of those tests failed. Pipelined `fold_device` on the Duo and pipelined calls to a physical device were not run.

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

### Frames on the phone

**2026-11-16**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), CoreDevice 651.32, AVConference 2260.15.1, debug build run from this checkout (the firewall rule covers it; `doctor` reported `allowed`). The probe app was in front unless noted.

| Check | Observed |
| --- | --- |
| `frames` against the bridge's decoded-JPEG mode (the first version) | Refused at once: `Installed AVCStreamOutput denies access to this process; no stream started`, tunnel release acknowledged. The installed `AVCStreamOutputAccess.plist` admits only named processes; `manzanero` is not one. `frames` was then built on the standard-RTP stream |
| `frames <dir> --count 10`, twice | 10 frames of 1125×2436, about 381 kB each (3.8 MB in all), stop reason `count`; setup 752–758 ms, first frame 506–526 ms after the stream request, 67 ms between frames on average; 2.4 s for the whole command. Owned stop, stream absence and tunnel release acknowledged |
| `frames <dir> --seconds 5 --interval 500` | 10 frames at 0, 567, 1037, 1560, 2029, 2562, 3028, 3527, 4037 and 4531 ms (mean 503.5 ms), stop reason `duration`, 7.3 s for the command. Before the interval grid, frames drifted to a 530–536 ms mean |
| `--seconds 30 --interval 200`, SIGINT after 4 s | Exit 130; 10 frames kept, `frames.json` `interrupted`, stderr summary with cleanup acknowledged; `media-status` afterwards: not running, 0 sessions |
| `--seconds 60 --interval 100`, SIGTERM after 4 s | Exit 143; 18 frames kept, `interrupted`, cleanup acknowledged, 0 sessions afterwards |
| Content | Frames opened as images: the probe app upright and readable (text-field caret visible in some, not others), then the Home screen after `button home`, then the probe app again after `launch`. The first Home frame showed a black 11-pixel strip on the right and 12 rows at the bottom: the stream is 1136×2448 for a 1125×2436 screen. After cropping to the display's bounds the frame matched a `screenshot` taken just after it in size and icon positions |
| Status bar | The first frame of a run showed the clock; later frames and a `screenshot` taken right after a run showed the screen-sharing indicator in its place. The home indicator and rounded corners are not in the stream |
| One image | `frames --count 1`: 1.78–1.86 s over three runs; `screenshot`: 0.69–0.72 s over three runs |
| MCP `capture_frames`, 5 frames at 200 ms, `image_max_edge: 400` | `isError: false`, 5 frames, inline 185×400 JPEG of 23 kB, scale 6.08. The same call sent right after `notifications/initialized` got no response (the known [open question](live-check-plan.md#questions-still-open)); sent a second later it answered. Later: fixed ([MCP calls sent without waiting](#mcp-calls-sent-without-waiting)) |
| MCP cancellation (`notifications/cancelled`) 4 s into a 30-second capture | No response for the request, as MCP requires; 10 frames kept, `frames.json` `interrupted`, cleanup acknowledged, 0 sessions afterwards |

Not covered: landscape or upside-down displays, another device, runs longer than five seconds, the 1 GiB budget and the first-frame timeout on hardware, and two processes competing for the stream.

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

**2026-11-16, at `8d0ec20`**, iPhone 13 mini (iOS 27.2.1, wired), macOS 27.2.1, Xcode 27.2 (27B52), the probe app's text field. No hardware keyboard has been attached to this phone and its hardware-keyboard setting was not changed or looked at; its interface language is Spanish. Before each run the field was emptied with `set-value … x` and `key backspace`; the result is the probe's own readout.

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

**2026-11-16**, the build committed as `76a322d`; the German row and the first Latin American row ran on the same code before its keyboard type changed from ANSI to ISO (German's table is the same in both), one iPhone 17e simulator, iOS 27.2 runtime (24B8117), headless (no Simulator or DeviceHub window opened). Host macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2; host input source Spanish – ISO. The simulator was booted for the run with `manzanero boot` and shut down afterwards; no other simulator was touched. No physical device was contacted. Research and design: [keyboard layouts](keyboard-layouts.md).

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

### Layout detection

**2026-11-16**, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), 262 keyboard layouts on the Mac; the probe was 12 keys in 215 groups. Each run used the probe app's `probe.text.field`; the result was checked against the app's own readout `probe.text.value`. Guide: [finding the layout](physical-typing.md#finding-the-layout-detect-layout).

**Simulator**: one iPhone 17e, iOS 27.2 runtime (24B8117), booted for the run and shut down afterwards. The hardware layout was set as for the [typing checks](#keyboard-layouts-on-the-simulator) (input mode written with `defaults write`, app relaunched) and restored afterwards to the earlier preferences (`en_US@sw=QWERTY;hw=Automatic`, no `AppleKeyboards`; iOS had changed `DictationLanguagesEnabled` on its own and that was put back too).

| Simulator input mode | Arrived | Result | `deviceSetting` | Restore |
| --- | --- | --- | --- | --- |
| `en_US@sw=QWERTY;hw=Automatic` (the default) | `` [`o\'#q=z^;5 `` | `ambiguous`: the ten US-like layouts | `automatic` | `cleared-to-original`, confirmed; readout empty |
| `es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO` | `` `<oç´·q¡z&ñ5 `` | `detected`, `--layout spanish-iso` | `explicit`, agrees | `cleared-to-original`, confirmed |
| `de_DE@sw=QWERTZ-German;hw=German` | `ü<o#ä§q´y&ö5` | `ambiguous`: `abc-qwertz`, `austrian`, `german` | `explicit`, agrees | `cleared-to-original`, confirmed |
| `fr_FR@sw=AZERTY-French;hw=French` | `` ^<o`ù3a-w6m( `` | `ambiguous`: `abc-azerty`, `belgian`, `french`, `french-numerical` | `explicit`, agrees | `cleared-to-original`, confirmed |
| French, field holding `hola señor ✓`, through MCP `detect_keyboard_layout` over a real stdio session | as above | `ambiguous`, `isError: false` | `explicit` | `set-value`, confirmed; readout `hola señor ✓` |
| SIGINT 3 s into a run | — | Exit 130, during the first set-value (not sent) | — | `unchanged`, confirmed |
| SIGINT 4.6 s into a run, after the probe was typed | — | Exit 130 | — | `set-value`, confirmed; readout `hola señor ✓` |

Each run took about 7 seconds. The two dead keys in the Spanish probe that do not compose (grave before `<`, acute before `·`) arrived as `UCKeyTranslate` predicts. After the setting was put back to `hw=Automatic` without relaunching the app, one more run still came back with the French group (`deviceSetting: automatic`): detection reports what the running app applies, which is what `type` will meet, not what the setting says.

**Phone**: iPhone 13 mini (iOS 27.2.1, wired), the probe app in front, the field holding `<>≤ ºª\` from earlier checks.

| Command | Observed |
| --- | --- |
| `detect-layout --id probe.text.field` | 8.7 s. Arrived `` `<oç´·q¡z&ñ5 ``; `detected`, `--layout spanish-iso`; restore `set-value` after 13 backspaces, confirmed; the readout showed `<>≤ ºª\` again |
| `set-value … x`, `key backspace`, then `type --layout spanish-iso` with `` ¿Qué? ¡Sí! "x" (p) [a] {b} <c> #1 $2 %3 &4 /5 =6 +7 *8 ^9 ~0 @€ºª\\|;:,._-'¨ç `` (76 characters, 226 events) | The readout's text equalled the requested string: 76 scalars, 86 UTF-8 bytes |
| `set-value … '<>≤ ºª\'` | The field's earlier text put back; `valueMatches: true` |

Not covered: other phones and phone layouts (only Spanish – ISO, which this phone uses), fields other than the probe's (autocorrecting, SwiftUI, web), MCP against the phone, input-method layouts, and a phone whose iOS ships a different table from the Mac's.

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

**Above the default bound, 2026-11-22.** The probe's `-probeBulk <KiB>` ([log probe](probe-app.md#log-probe)) on the `manzanero-research-phone` simulator (iOS 27.2), Xcode 27.2, three runs with `--terminate`:

| Run | Result |
| --- | --- |
| `-probeBulk 128`, default `--max-bytes` | `stdoutBytes` 131,146, `stderrBytes` 131,868; each tail exactly 65,536 bytes, starting inside line 1026 and ending with `end lines=2048`; `truncated: true`, `stopReason: duration` |
| `-probeBulk 2048`, `--max-bytes 1048576` | About 2 MiB per stream; each tail exactly 1,048,576 bytes; `truncated: true`, `stopReason: duration` |
| `-probeBulk 4096`, 10 s | `stopReason: byteLimit` once the two files passed 8 MiB together (4,194,379 and 4,194,348 bytes), `truncated: true`, the app terminated by the tool; the stdout tail ended with `end lines=65536` |

**Probe trigger.** A `manzanero-probe://` URL opened with `open-url` showed "Open in “Probe”?" and needed a touch, so the trigger became the accessibility element `probe.log.emit`, which `press-id` activated (`status: accepted`).

Not established: anything on a physical device (physical `console` and `last-crash` have only unit tests and dry runs), `log show` over long windows, extensions, other runtimes or Xcode versions, and MCP calls against a live simulator (the tools' routing and schemas are unit-tested).

## Apps, files, reports and development

Physical Settings launch and app inventory succeeded. The launch option-order fix (`4c47998`) ensures devicectl options precede the bundle operand. One Safari URL preflight failed; broad physical URL/lifecycle claims are not made.

App-data command plans and an Apple-tool-owned temporary-domain synthetic copy round trip were checked. This is not actual app-container access/round-trip evidence. Physical saved-report listing passed. Download is implemented but hardware-unverified. Filtering and parsing now exist as [`last-crash`](#app-logs-console-and-crashes), verified on a simulator only; symbolication and deletion are missing. See [feature status](feature-status.md). Later: a report was downloaded on the phone ([wider command run](#wider-command-run-on-the-phone-and-a-simulator)), physical `last-crash` found and downloaded a crash ([console and last crash](#app-console-and-last-crash-on-the-phone)), and the probe app's container was listed, pushed and pulled ([remaining phone checks](#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session)).

The [probe app](probe-app.md) fixture and its touch probe passed its core unit tests, a warning-free simulator build, a simulator launch, XCUITest recording checks and a simulator `build-run` (2026-11-15, iPhone 17e simulator, iOS 27.2). It has not been run on hardware, so it has produced no delivery evidence yet. Its [touch measurement runner](probe-touch-runner.md) passed offline tests against canned tree output, receipts and logs, and its dry run's commands were accepted by `manzanero --dry-run`; it has not been run against a device. Later: both ran on the phone ([touch delivery](#touch-delivery-measured-with-the-probe-app)).

Simulator screenshot and finite H.264/HEVC movie checks passed. Build & Run passed simulator project/Debug and workspace/Release flows with product validation/install/launch; complete physical signing/deployment remains unverified. Later: physical signing, install and launch of the probe app passed ([touch delivery](#touch-delivery-measured-with-the-probe-app), [remaining phone checks](#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session)).

Human handoff has synthetic terminal/form completion and per-device mutation-pause coverage. No actual biometric/passcode/purchase action, automatic prompt detection or native notification is claimed.

### Launch options and terminate by bundle

2026-11-21, `manzanero-research-phone` (iPhone simulator, iOS 27.2), Xcode 27.2. `launch com.lemambo.manzanero.probeapp --relaunch --env PROBE_X=1 --language es -- -ProbeList YES` started the probe on its list screen: the next `tree` held `probe.list.row.1` and the rows after it, which only that argument shows. `terminate com.lemambo.manzanero.probeapp` then ended it with exit 0. Whether the variable and the language reached the app was not read: the probe shows neither. Physical `terminate <bundle>`, which finds the app's one running process in `devicectl`'s app and process lists before it terminates, is unit-tested only; so is a physical launch with options, whose plan passes the environment as `--environment-variables` and the rest after the bundle, as `console` already did on the phone.

### Selectors that are not exact

2026-11-21, `manzanero-research-phone`, the probe's list screen. `press --label 'row 1' --match contains` was refused before anything was sent, listing ten matches (Row 1, Row 10 to Row 13 and five more), as an ambiguous exact selector is. `press --label '^Row 12$' --match regex` was accepted and the probe's `Last:` label read `row-12`. `wait --id list.row.3 --match contains --timeout 2` met `visible`. `scroll --id 'probe\.list\.row\.5[0-9]$' --match regex --index 1 --search 10` found `probe.list.row.50` in four steps and verified its postcondition. `press --label '(' --match regex` exited 64 with "not a valid regular expression". Not run on a device; the physical commands share the selector code with the simulator's.

## Other simulator families

### Simulator completeness run: iPad, iPhone Duo and Apple Watch

2026-11-21, at the human owner's request: every command family on an iPad mini (A20 Pro), briefly an iPad Pro 13-inch (M5), the iPhone Duo (`manzanero-research-duo`), an Apple Watch Series 12 (`manzanero-research-watch`) and an Apple Watch Ultra 4 (`manzanero-research-watch-ultra`). Runtimes iOS 27.2 (24B8117) and watchOS 27.2 (24S118), Xcode 27.2, macOS 27.2.1, the build of that afternoon (with `launch` options and `--match`, before the settings commands). Run by a delegated agent of laia-LLM. The iOS probe was installed on the iPads and the Duo, a text-field app on the Ultra, and both were removed afterwards. No sound, volume key or `--audio`.

| Commands | iPad mini | iPhone Duo | Watch Series 12 | Watch Ultra 4 |
| --- | --- | --- | --- | --- |
| Find and check | works | works | works | works |
| Touch | partly: a four-path `multi-drag` was cancelled by iPadOS after 0.09 s (also 0.13 s for a one-second one, and on the iPad Pro); two, three and five paths arrived whole at the probe | works, folded and unfolded, against the probe | works (`tap`, `swipe`, `long-press` effects seen); the multi-contact commands moved the interface, with no way to count contacts | as the Series |
| Buttons and keys | works (`home`, `lock`, `key`); `side`, `action`, `wake` refused | works; `wake` refused | partly: `home` works, `side` opens Control Center, `action` and `lock` do nothing, `key` and `wake` refused | partly: `home`, `side` work, `action` opened "Choose Action", `lock` does nothing |
| Text | works (`type`, `detect-layout`, `set-value`); `paste` refused | works, folded and unfolded | partly: `type` refused, `set-value` changes only the reported value; `detect-layout` was not refused and left `x` in the field (refused since, below) | as the Series |
| Accessibility read | works, the Home Screen too; `wait` visible, gone, value, a timeout's exit 124, `--match contains` and `regex` | partly: Home Screen tree empty, as recorded; one error 17 two seconds after a launch on a fresh boot, gone three seconds later | works | works |
| Accessibility act | works: `press --label 'row 1' --match contains --index 1`, and a regex with `--index 3` pressed Row 3 | partly: `press` in the letterboxed probe failed with error 8, as recorded (built since, below) | works (`press`, `scroll --id`, `set-value`) | works |
| `scroll --search` | works, four directions | works, four directions, unfolded | works, up and down (Website Data in 4 steps) | fails: "the list stopped moving after 1 search step(s)", in Settings and Settings › General |
| Pictures, `record` | works | works, with and without `--display` | works | works; `screen ocr` reads nothing of the large-digit face |
| Apps | works; `--relaunch -- -ProbeList YES`, `--language es` and `--env A=1` were seen in the process's arguments and environment | works; the first `open-url` after its prompt looked lost, because `wait --until value` on `probe.url` timed out; rechecked the same day, the URL had arrived (the tree read `1 manzanero-probe://first`) while the wait answered `not-visible`: on the folded Duo's 466 × 678 screen the probe's `probe.url` reports itself not visible at y 460, and a value wait needs a visible element. Read the value from `tree` there | install, uninstall and `open-url` not run | works; `open-url` of a scheme nothing handles fails (error 115) |
| `console`, `last-crash`, `logs`, `handoff --until`, `batch` | works (`build-run` too, 13 s) | works | works | works |

Other observations: on the Duo a `tap` after `button lock` was dispatched where the iPad refused it as display off, and it took three `button home` presses to leave the lock screen; on the watch a Maps location prompt stayed up after `terminate` and caught later touches; simulator `screenshot`, `boot`, `shutdown`, `install` and `uninstall` print no JSON; `unfold` was seen after four display reads and `fold` after eighteen.

Changed after the run, the same day: `detect-layout` is refused on a watch with the keyboard refusal, and was checked so on `manzanero-research-watch`. A letterboxed app on the Duo is pressed by moving the hit check by the window's centred offset ([guide](other-families.md#the-inner-display-unfolded)): `press --id probe.log.emit` was accepted and `set-value --id probe.text.field` wrote "duo ok". The Ultra's search was reproduced in Settings (`com.apple.NanoSettings`), and the guess first written here (every row already on screen) was wrong: General's row sat at y 255 of 257, mostly below the edge. The search anchors on elements without children, here the rows' texts, and a watch shrinks rows towards the list's edges, so the texts started at x 42.5, 43.8 and 85 and only two shared a line; that pair's lowest text was on screen, so its scroll moved nothing and the search stopped. The rows themselves, which all start at x 2, are now candidates too (before the texts when no texts form a list, after them otherwise). Afterwards `scroll --label Bluetooth --search 15` found Bluetooth in 5 steps on the Ultra and in 4 on the Series 12, and Website Data was found in Settings › General on the Ultra.

**The four-path drag on the iPad, looked at again** the same evening, on the iPad mini (A20 Pro) simulator (iOS 27.2) with the iOS probe installed by `build-run`, each drag after `press --id probe.touch.reset`, the probe's summary read from `tree`:

| Paths, iPadOS's gesture settings | What the probe received |
| --- | --- |
| Four, upward, both switches on (the default) | Nothing: the iPad went to its Home Screen, iPadOS's four-finger gesture |
| Two, three and five, upward, both switches off | Every contact began, moved 27 to 30 times and ended |
| Four, upward, with Settings › Multitasking & Gestures › Four & Five Finger App Switching off | 4 began, 4 cancelled after one move each |
| Four, with Productivity Gestures off as well: upward, downward, sideways, close together, over 0.6 s and over 3 s | The same each time, cancelled after one move |
| Four contacts that do not move (start and end alike) | 4 began, 4 ended, none cancelled |
| The same four paths on `manzanero-research-phone` (iPhone, iOS 27.2) | 4 began, 120 moves, 4 ended |

So iPadOS cancels four moving contacts whatever their direction, with both of its gesture switches off, and lets five through; four contacts that stay put are not cancelled, and an iPhone takes the same four paths whole. The tool sends them as it sends two, three and five. Which recognizer of iPadOS claims them is not known; the switches were put back on and the probe removed afterwards.

Three simulators created for this work, headless (Simulator.app not opened): `manzanero-research-tv` (Apple TV 4K (4th generation) at 1080p, tvOS 27.2, 24K150), `manzanero-research-watch` (Apple Watch Series 12 (46mm), watchOS 27.2, 24S118) and `manzanero-research-duo` (iPhone Duo, iOS 27.2, 24B91016s). Host macOS 27.2.1 (26B131), Xcode 27.2 (27B52). No physical device was contacted. Background and the first pass are in [the research](other-families-research.md); the commands are described in [other simulator families](other-families.md).

### Simulator closing runs of 2026-11-22

Items left open on the roadmap that need no hardware, run by laia-LLM on simulators only (host macOS 27.2.1, Xcode 27.2). No physical device was contacted.

**`batch` with touch steps on an iPhone simulator** (`manzanero-research-phone`, iOS 27.2, the iOS probe in front). One batch of seven steps: `press --id probe.touch.reset`, `tap`, `double-tap`, `swipe` (0.3 s), `multi-tap` with two points, `long-press` (0.6 s), `wait --until visible`. `status: completed`, seven of seven, each step's receipt from `coresimulator-dtuhid`. The probe then read five gestures, six contacts began and six ended, none cancelled, `maxActive` 2, the swipe with 14 moves, each at its point to within 0.0002. The long press was not among them: it was aimed at y 0.75, which is inside the probe's text field (y 642 to 682 of 874 points), which takes the touch itself; a plain `tap` there was not counted either, and a long press at y 0.6 was. A step with a missing operand (`swipe` without its seconds, `wait --until exists`) was refused before anything ran, as designed.

**`fold` straight after boot, nothing else booted** (`manzanero-research-duo`, iOS 27.2, the phone simulator shut down first, so the Duo was the only simulator booted on the Mac). Right after `bootstatus` returns, the display information reads `backlightState: unknown`, then both `LCD` and `LCD-1` `activeOn` for about six seconds, then the folded state on its own, with the hinge at 0 throughout. With the 10 s bound (40 reads), in three boots of `fold`, `unfold`, `fold`, `unfold`: three of six folds were not observed, the first of a boot and twice the second, about 25 s after boot; one was observed at read 38. One missed fold was followed with `displays`: it had settled 14 s after it was sent. Once settled (a minute after boot), six folds of six were observed after 13 or 14 reads, 3 to 5 s. So it was neither load nor other simulators: a Duo that has just booted folds slowly, up to 14 s. The bound became 20 s (80 reads). With it, in seven boots: every first fold was observed, five of them after 41 to 46 reads (11 to 13 s), which the old bound would have missed. One fold, 13 s after a boot, was not observed: the hinge read 0 and both displays stayed `activeOn` for over 40 s more, so the simulator itself stayed between states; the receipt said `displayObserved: false` and the next `unfold` was observed after two reads. One `unfold` 15 s after a boot was not observed within 20 s either, and the next fold was. The receipt is right in both cases; nothing is resent, as designed.

**`scroll --search` on a list whose rows share no edge** (`manzanero-research-phone`, the iOS probe with `-ProbeList YES -ProbeListStagger YES`: each row's label at its own x, about 13 rows in the tree, none below or above the screen). Three faults, fixed that evening:

| Run | Before | After |
| --- | --- | --- |
| `--search 40` to row 55 | Failed after 30 s with "no reply within 0.1 seconds": on a simulator the session had the standard 30 s whatever the search's steps, where a physical one has 30 s plus 3 s a step. It now has the search's allowance | Ran out its 40 steps, then (below) reached row 55 in 18 s, `postcondition-verified` |
| Four searches of four steps down | The list went to rows 11–23, then back up to rows 1–13: a step that moved the list back counted as progress | A backward move is a failed try; row 55 in 18 s and row 60 in 20 s |
| `--search 40 --toward up` from row 60 | Stopped after 4 steps: with every row a line of its own, the highest candidates were the `Last` label and the strip's columns, which move nothing upward | Leaving out elements that form a list the other way, from rows 48–60 to row 1 in 50 steps over two runs (48 s) |

Row 1 and row 60 were then pressed and `probe.list.last` read `row-1` and `row-60`. A staggered step moves about one row upward and four downward, because the table holds no rows beyond the screen. With the final code the plain list and strip still searched in four directions (row 55 in 6 s, row 1 in 19 s, columns 38 and 2 in about 20 s), and so did the tvOS probe on `manzanero-research-tv` (row 35 in 9 s, row 1 in 21 s, columns 28 and 2 in 13 and 14 s).

**`set-value` on a SwiftUI field** (`manzanero-research-phone`, the iOS probe's new [SwiftUI form](probe-app.md#swiftui-form-probe), a `TextField` with a label and an identifier). `set-value --id probe.swiftui.field 'Año café'`: `acknowledged`, `valueMatches: true`, and the app's bound value read `Año café` with one change. `set-value --label 'Probe name' second`: the same, bound value `second`, two changes. So on iOS the request reaches a SwiftUI field's binding, unlike on watchOS, where it changes the field's text without the bound value ([other families](other-families.md#digital-crown-and-side-button-apple-watch)).

**Watch typing in other keyboard languages** (`manzanero-research-watch`, Apple Watch Series 12, watchOS 27.2, its language set with `defaults write -g AppleLanguages` and `AppleLocale` and rebooted, then put back to its original `en-US, en-ES, es-ES` and `en_US@rg=eszzzz`). In German the keyboard is QWERTZ with Ü, Ö and Ä, and every function key is labelled in German: the first `type 'Zoey 42!'` typed `Zoey` and stopped at the space, whose key is labelled `Leerzeichen`. The keys' identifiers are not translated (`shift`, `more`, `space`, `delete`), nor their classes; with keys named by them ([other families](other-families.md#digital-crown-and-side-button-apple-watch)), `type 'Zoey 42! a[1]#€x & b'` left Contacts' Vorname, Prénom and First name reading exactly that, in German, French and English. A `type` sent two seconds after pressing the field once found no keyboard yet; it now waits up to three seconds for it, and one sent at once typed `Al 7`. With no field pressed it still refuses with nothing sent. No contact was saved.

**`--index` in a two-column layout, and a regression fixed** (`manzanero-research-duo` unfolded, Settings in its two-column layout). `press --label General` listed five matches, the third the visible sidebar row; `press --label General --index 3` and even `press --id com.apple.settings.general` then failed with "target centre hit is another native element". Settings' root reported its frame as 669 × 951, unrotated, in the 951 × 669 interface, and the letterbox correction of 2026-11-21 took that for a narrow window and moved the hit by (141, −141). With the check requiring a window that fits inside the interface, `--index 3` pressed General, `press --label Accessibility --index 1` opened Accessibility (its VoiceOver row in the tree), and the letterboxed probe (root 469 × 669) was still pressed by `probe.touch.reset` and `probe.log.emit`.

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

### Apple TV remote

**2026-11-16**, `manzanero-research-tv`. Apps: Settings, and a throwaway SwiftUI probe built for the tvOS 27.2 simulator SDK with `swiftc` and installed with `simctl install` (three focusable buttons, readouts for focus, the selected button, `onMoveCommand` directions, `onExitCommand` and `onPlayPauseCommand` counts, read through the tree). Not committed; it lives in the worktree's `tmp/`.

| Command | Observed |
| --- | --- |
| `remote menu` on Settings > Video and Audio | Back to the Settings root (tree) |
| `remote select` | Opened the focused row (Video and Audio) |
| `remote down`, `select`; `menu`, `up`, `up`, `select` | Opened Screen Saver, then Profiles and Accounts: focus moved |
| `remote home` | The Home Screen (HeadBoard) |
| Probe: `play-pause` twice | `playPause 1`, then `2` |
| Probe: `right`, `right`, `left`, `select`, `down`, `up`, `menu` | Focus Alpha → Bravo → Charlie → Bravo; `selected Bravo`; moves `right,right,left,down,up`; `exit 1` |
| `tap 0.5 0.5` on the TV | Refused, `unsupported-operation`: Apple TV has no touch screen, pointing to `remote` |
| `remote down` on the Duo; `remote menu --device x` | Refused before input (`this simulator is an iPhone`), and before device contact |

### Apple TV focus

**2026-11-16**, `manzanero-research-tv`, the tvOS probe and Settings. With temporary diagnostics, the snapshot attributes and traits of the focused and an unfocused probe button were identical. AccessibilityPlatformTranslation's own mapping (`_attributeTypeForMacAttribute:`, read on the Mac) gave `AXFocused` 28 and `AXFocusedUIElement` 19; on the TV, 28 answered true for the focused button (Bravo) and false for Alpha, and 19 on the application answered Bravo's element.

| Command | Observed |
| --- | --- |
| `tree` on the probe, Bravo focused | One node `focused: true` (Bravo); `focus` `{nodeId: n7, label: Bravo, identifier: probe.bravo}` |
| `remote right`, then `wait --id probe.charlie --until focused` | `condition-met`, reason `focused` |
| `wait --id probe.alpha --until focused --timeout 1` | `timed-out`, reason `not-focused` |
| `tree` on Settings, then `remote down`, `tree` | `focus.label` Profiles and Accounts, then Video and Audio; `wait --label "Video and Audio" --until focused` met |
| `tree` on the Duo and on the watch | No `focus` key and no `focused` field |

**2026-11-23**, `remote --report-focus` on `manzanero-research-tv-4k` (tvOS 27.2), its Home Screen with Settings focused, read from a screenshot first. The first press, a few seconds after boot, was refused with "The simulator HID service did not become ready; no input sent", and the same press later went through.

| Command | Observed |
| --- | --- |
| `remote right --report-focus` | `focus` `{label: Probe TV, identifier: AppCell, frame: 388,824 250×150}`, `focusApplication.pid` PineBoard's, `status: dispatched` |
| `remote left --report-focus` | `focus.label` Settings |
| `remote swipe-right --report-focus` | `focus.label` Probe TV; a screenshot afterwards showed Probe TV focused |

### An Apple TV whose services stopped answering, awake

**2026-11-24, afternoon**, the Apple TV 4K (tvOS 27.2), some hours after the morning's session ended with a `remote sleep`; the human owner saw the television on, showing a picture, throughout.

| Step | Observed |
| --- | --- |
| `readiness` | `prerequisitesPresent`; the display, lock and passcode queries all failed (`displaysUnavailable`, `lockStateUnavailable`) |
| `wake` | 12 waits of 5 s for the HID service, refused each time before any input; `deviceNotReady`, nothing sent, 2 min 48 s |
| The device services' log and samples (`diagnose:device-services`) | `remotepairingd`'s RSD heartbeats for the device answered every 30 s, in 0.7 to 3.7 s (the phone's in 5 to 11 ms); service sockets were created; no failure line for the device |
| `wake` four minutes later | Its first screenshot timed out (52 s); nothing pressed |
| `remote home` | Refused: "Apple HID service did not become ready; no input sent" (25 s) |
| `remotectl dumpstate` | The device's connection `connected (connectable)`, not the stale state |
| `screenshot` | `devicectl`'s own 60-second timeout ("Assuming command got stuck and aborting") |
| The log over those calls | Each command's usage assertion granted and later invalidated by the device with an error the log keeps private; a `devicefs-browse` assertion of CoreDevice's DeviceFS extension held throughout |

So the device was awake and reachable, and its services took the connection and gave no answer: not sleep, and not the stale connection of 2026-11-18. `wake` waited and sent nothing, as designed; a screenshot that times out before a wake fails it with nothing pressed.

With the human owner's word laia-LLM restarted the device (`devicectl device reboot`, accepted in 91 s). Two minutes later `readiness` answered in 6.6 s with `asleep: false` and `displayPower: external`, and a `tree` ran on the tool's own pairing (`serviceDirectory: own-tunnel`, `ownTunnelLink: paired`): 179 nodes of the Home Screen. The pairing holds across a restart of the Apple TV.

Then the device was left idle on the Home Screen with nothing sent for 20 minutes: a screen saver had started (a still frame of an animated scene in the screenshot, `blankImage: false`). `remote sleep` from it pressed `lock` and Power Off and ended `asleep`, `verified: true`, in 13 s: from a screen saver the power button opened Control Centre as from the Home Screen.

After 12 minutes asleep, as long as the gap before the 25004 of the morning, `wake` pressed Home once and ended `awake`, `verified: true`, `hidWaits: 0`, in 6 s: the screenshot before it was refused as asleep (25005), so error 25004 did not come back and its branch is checked by unit tests only. A `remote sleep` then left the device asleep.

Then a long session on the tool's own pairing, through the MCP server connected to Claude Code (one process for the whole session): `wake_device` (`awake`, `hidWaits: 0`), `get_ui_tree` (227 nodes, `serviceDirectory: own-tunnel`, `ownTunnelLink: paired`), then over about ten minutes, with pauses of 1.5 to 2.5 minutes, `press_remote` `right`, `left`, `swipe-right` and `swipe-left` with `report_focus` (each receipt named the Home Screen icon the screenshot-free focus landed on; a swipe moved it four icons), `wait_for_element` `until: focused` on the icon the last press reported (`condition-met`, one poll) and a final `wait_for_element` with `index`, each on the paired tunnel. The first icon's handle was the same seven minutes apart (`ax:<pid>:<object>` unchanged). `remotectl dumpstate` afterwards: the device's connection `connected (connectable)`, not stale. `press_remote sleep` ended it `asleep`, `verified: true`.

### First run on a physical Apple Watch

**2026-11-24, night**, an Apple Watch (`Watch8,1`, watchOS 27.2.1), developer mode on, reached over the local network; on the human owner's word, everything inside the new [watchOS probe](probe-app.md#watchos-probe).

| Step | Observed |
| --- | --- |
| `details`, `readiness` | Paired, connected over `localNetwork`, developer mode on, display state `unknown` |
| `build-run … ProbeWatch` | Built, installed and launched with what the Mac already had for signing; no provisioning change was needed |
| `tree` | The probe's readouts and controls; the tool's own tunnel is not available for a watch ("Apple's MobileDevice framework does not list the device"), so it went over Apple's tunnel (`serviceDirectory: opened`); display 211 × 257 points |
| `press --id probe.watch.button.a` | Refused before sending at the hit test (error 8); the button was drawn small at the bottom edge by the watch's list |
| Then | The watch dropped from `remoted`'s list and showed `connecting`; later `available`, and after a reconnection the tree was refused for want of developer image services, then a scroll for want of an established `remoted` port for the watch's tunnel. Sending stopped there |
| `crown 200 --device` | Refused before contacting anything: `crown` is built for watch simulators only |

So the probe installs and its tree reads on a real watch, but the watch's network link does not stay up between commands, presumably while its screen sleeps or it is off its charger, and nothing that acts was completed. Next time: the watch on its charger with its screen on, and the steps close together. A physical watch's crown is not built.

Later the same night, on the human owner's "try again", with the watch reachable:

| Step | Observed |
| --- | --- |
| `readiness`, `launch --relaunch` of the probe | Connected, developer image services available |
| `scroll --id probe.watch.pad --search 4`, `press --id probe.watch.button.a` | `postcondition-verified`, `accepted` |
| `tap` on the pad | Refused before sending: "Device and display orientation disagree". The watch's panel is mounted sideways (`nativeOrientation: rot90`, `currentOrientation: rot270`, 514 × 422 pixels) and the result has no orientation sensor, which touch required for such a panel. Fixed the same night: with no sensor, an upright interface (the two turns adding to 0) is taken |
| `tap` aimed at (0.25, 0.3) of the pad, after the fix | The probe read `0.249,0.300` |
| `scroll --search` to row 25, `press`, `scroll --toward up` | Both scrolls `postcondition-verified`, the press `accepted`; the probe read `last: row:25`, `count: 3` (button A, the pad, row 25) |
| `press --id probe.watch.text.field`, `type 'Hi 42'` | The system keyboard (`QuickboardViewService`) opened; `type` was dispatched as keyboard events, which watchOS ignores, and nothing was typed. On a physical watch `type` does not yet tap the on-screen keys as it does on a simulator. The sheet was closed with `press --label Cancelar` (the watch is in Spanish) |

So on a real watch the tree, `press`, `tap` and `scroll --search` work inside the probe; `type` and `crown` are built for simulators only.

`type` and `crown` were then built for a physical watch the same night and run inside the probe:

| Step | Observed |
| --- | --- |
| `crown 200` with the probe in front | `probe.watch.crown` 0.000 → 1.000, as on a simulator: the same `IndigoScrollEvent` steps on the watch's own `hid.scroll` service, which its capability list names (`ADCRotateCrown`, `DirectPhysicalCrown`) |
| `crown 300 --events 3` | 1.000 → 2.500 |
| An earlier `crown 200` sent while the probe was not in front (the relaunch had not taken) | Went to whatever was in front; that screen was not read, to keep the watch face private. Check the app is in front before input |
| `press` the field, `type 'Hi 42'` | 7 key taps and Done in 41 s (`route: watch-on-screen-keyboard`); the field read `Yo 42` |
| The keyboard's tree against one screenshot (deleted) | Every key's frame matched where it was drawn; the keyboard is Spanish (Ñ, `ESPACIO`, suggestions `El` and `La`) and labels its letter keys in capitals. So the taps were right and the keyboard's autocorrection turned "Hi", not a Spanish word, into the nearest one, "Yo", at the space |
| The probe relaunched, `type 'Hola 42'` | 9 key taps and Done; the field read `Hola 42` |

So on a physical watch `type` taps the on-screen keys, read from a tree before each key, as on a simulator; the keyboard's autocorrection applies to what it is given, as it would to a person's taps.

The watchOS probe was uninstalled from the watch afterwards at the human owner's request; the app list no longer has it.

### The physical Apple Watch's remaining commands

**2026-11-25, just after midnight**, the same Apple Watch (`Watch8,1`, an Ultra, watchOS 27.2.1) over the local network, on the human owner's word, the watchOS probe installed by `build-run` for the run and uninstalled after it. The human owner allowed `button side`, `button action`, `reports`, `last-crash` and a read of `settings`; everything else ran inside the probe, and nothing of the watch face was read.

| Step | Observed |
| --- | --- |
| `crown` against the probe's `-ProbeCrownList YES` list | One row per event, as on a simulator: one 100-unit event moved the list 70.5 points (the title collapsing and one row), `crown 300 --events 3` exactly three rows of 59.5 points, one `crown -400` one row back |
| `screenshot` | 422 × 514 pixels, upright, the probe whole although the panel is mounted sideways |
| `frames --count 1`, `record … 5 --backend coredevice`, before a fix | Failed at the 12-second first-frame budget with hundreds of packets and no picture. The kept packets (`MANZANERO_KEEP_STREAM=1`) were H.264, not HEVC: payload type 123, FU-A fragments of an IDR slice and single slices, and a first packet of 138 bytes holding four bytes and then a QuickTime `avc1` sample description, whose `avcC` carries the SPS and PPS. The phone and the Apple TV send HEVC with its parameter sets in band |
| The same after the fix (`MediaH264Assembler`, H.264 in the decoder) | `frames`: one clean picture of the probe, 514 × 422, sideways as the panel is mounted (deleted after reading). `record`: `status: recorded`, 72 source pictures in 5 s, no restart |
| `button side` (new for a physical watch), twice | Control Centre came up over the probe (the system's `Carousel` process in front, its scroll view in the tree), and the second press closed it with the probe back in front |
| `button action` (new for a physical watch), twice | The Action button is set to the flashlight: the first press lit it (a full-screen `flashlight-white` element in the tree), the second put it out and the probe was back in front |
| `press` button A | Refused at the hit test before sending (error 8): the button sits at the display's bottom edge, its frame running past it. Button B beside it was pressed |
| `logs --bundle` the probe, at `default`, `info` and `debug`, while buttons were pressed | Ended at its duration with nothing received: `receivedRecords: 0`, `receivedBytes: 0`, over Apple's tunnel (the tool's own is not available for a watch). The probe logs each press at `info`. Why the watch's relay sends nothing was open that night; see [the next section](#an-apple-watchs-log-relay-sends-nothing-and-why) |
| `console` the probe, 5 s | The probe's own stderr line arrived; the launch ended at its bound (signal 2) |
| `last-crash --process ProbeWatch`, `reports list` | No probe report; the list read (three entries, none the probe's) |
| `settings` (read) | Refused by the device: it lacks CoreDevice's "Customize User Interface Style" capability (`com.apple.coredevice.feature.customizeuistyle`) |
| `files list` of the probe's container | Its directories read |
| `batch`: press B, `crown 200`, `scroll --search` to the pad, `tap 0.5 0.5`, a `wait` | The four actions took effect (count 2, crown 1.000, the tap at `0.500,0.400` of the pad); the `wait` timed out because it named a readout the scroll had moved off screen, a mistake in the step, and the batch stopped there as designed |
| `handoff --until value --id probe.watch.count --value 3`, with a press of B from another process playing the person | Ended by itself after 13 s, `status: observed` |
| MCP (the server of the current build over stdio): `press_element`, `rotate_crown` and `press_button side` with `platform: physical` | The press counted and the crown read 1.000 in the probe. An earlier session's crown and side presses were sent while the watch had locked and its display slept (`passcodeRequired: true` in their receipts); their effect is unknown. The MCP host's own server, started before the day's rebuild, refused the watch's display geometry, as the build before the fix for sideways panels did |

So on a physical watch every command family has now run inside the probe, except `logs`, which receives nothing, and `settings`, which the watch refuses. The watch's display sleeps and it locks once off the wrist: an input then goes to whatever is in front, so keep the steps close together and relaunch the probe before each group.

### The Duo simulator's inner display in other orientations

**2026-11-25, evening**, a second simulator of the Duo runtime made with `create-simulator` (deleted afterwards: the project's `manzanero-research-duo` already existed), unfolded, the iOS probe installed by `build-run`, shut down afterwards.

| Step | Observed |
| --- | --- |
| `rotate` to `landscape-right`, `portrait`, `landscape-left` and `portrait-upside-down`, the probe allowing every orientation | Each accepted by `devicectl` (`deviceOrientation` as asked, orientation lock off), and each time `displays` read `LCD-1` at `rot90` and the tree `rot90`, 951 × 669 points: the inner display did not turn. `press --id probe.touch.reset` accepted and `tap 0.25 0.4` sent in all four |
| The probe relaunched portrait only (`-ProbeAllowRotation NO`), the device in `portrait` and in `landscape-left` | `LCD-1` still `rot90`, 951 × 669 points: the app letterboxed, as recorded on 2026-11-21 |
| `tap 0.25 0.4` at `rot90`, the probe reset first | The probe's last gesture: one contact from and to (0.24991, 0.4001), 0.086 s |

The same evening the Home Screen was read again on `manzanero-research-duo` (the Duo runtime, iOS 27.2 24B91016s, the only one installed for it): folded, `tree` was refused (error 18); unfolded, the simulator returned no snapshot data at full depth or at depth 10 for 12 s; `screen` fell back to OCR both times. Unchanged since 2026-11-16; it waits for a later runtime.

So on the simulator the unfolded inner display is always `rot90`, whatever the device orientation and whatever the app allows; its other orientations exist only on the device, where the inner display read `rot0` and `rot90` on 2026-11-25 with trees, presses and taps in both ([record](#first-run-on-a-physical-iphone-duo)).

### A web view embedded in native content

**2026-11-25, evening**, the iOS probe's new `-ProbeWebEmbedded YES` screen: a label at the top, a native button at the screen's centre and a 220-point `WKWebView` along the bottom, as many apps embed one, so the app and not the page holds the display centre. On `manzanero-research-phone` (iOS 27.2) and on the iPhone 13 mini (iOS 27.2.1, the tool's own tunnel on the cable).

| Step | Observed |
| --- | --- |
| `tree`, simulator and phone | The app's native elements and the web view as one opaque element. The first read on the simulator had no page yet; the second, and the first on the phone, had the web view's remote element naming the page's process (`externalProcessReference: true`) |
| Simulator: `press --label "Top button" --pid <page>`, `press --label "Web field" --pid <page> --index 2` and `type hola` | Each accepted (`explicit-pid-shown-by-frontmost-or-centre-hit`); the probe read `web-top`, then `web-field:hola` |
| Simulator: `scroll --label "Bottom button" --pid <page> --search 30`, then `press` | First `postcondition-failed` and a refused press: the keyboard the field had raised covered the whole web view. After `press --label Done` (the keyboard's bar, in the app's tree, not the page's): `postcondition-verified`, the press accepted, the probe read `web-bottom` |
| Simulator and phone: `press --id probe.web.native` | Accepted; the probe read `native` |
| Phone: `tree --pid <page>` | The page's tree, the "Top button" in it |
| Phone: `press --label "Top button" --pid <page>` | Refused before anything was sent: "requested PID differs from display-centre process and does not host it". On a phone `--pid` may name only the display-centre process or the one that hosts it, and an embedded page is neither |

So on a simulator an embedded page was read and acted on like any page, and on a phone it could be read and not acted on: the simulator's wider `--pid` rule (a process one of the foreground app's remote elements shows, with a frame) was the human owner's decision of 2026-11-21 for simulators only.

**Later that evening the human owner extended that rule to phones and iPads** (not an Apple TV). On the iPhone 13 mini, the probe relaunched on the same screen: `press --label "Top button" --pid <page>` accepted with `selection: explicit-pid-shown-by-centre-hit-test` (`web-top`); `press --label "Web field" --pid <page> --index 2` and `type hola` (`web-field:hola`); `press --label Done` to close the keyboard; `scroll --label "Bottom button" --pid <page> --search 30` `postcondition-verified` and its press accepted (`web-bottom`); `press --id probe.web.native` (`native`). Every action on the page went through the same guards as before, the hit test at the target's centre included.

### `profile list` and `profile remove`

**2026-11-25, evening**, the iPhone 13 mini (iOS 27.2.1), through `devicectl device profile`.

| Step | Observed |
| --- | --- |
| `profile list` | Exit 0: 0 configuration and 11 provisioning profiles (only the counts were read) |
| `profile remove manzanero.no-such-profile --type configuration` | Refused by the device, nothing removed: CoreDevice error 22701, "was not found". Reported first as `tool-failed` with `inputSent: unknown`; since then as `ambiguous-or-missing-target`, `inputSent: none`, with a message pointing at `profile list` (`CommandFailure.missingProfile`) |

The same two `devicectl` requests, run by hand that afternoon, listed and removed the watchOS logging profile on the Apple Watch ([app logs](app-logs.md#an-apple-watch)); through the tool a real removal has not run yet.

### Upright pictures in landscape

**2026-11-25, evening**, the iPhone 13 mini (iOS 27.2.1) on its cable, the iOS probe in front, the phone turned with `rotate`.

| Step | Observed |
| --- | --- |
| Before the change, the probe launched with `-ProbeAllowRotation YES`, `rotate landscape-right` (`rot90`) | `screenshot` (Apple's `devicectl`): 2436 × 1125, upright. `frames --count 1`: 1125 × 2436, the interface on its side, its top-left corner at the picture's bottom left. The two commands disagreed |
| The same before that relaunch | The probe stayed portrait whatever the phone reported (`deviceOrientation: landscapeRight`, `currentOrientation: rot0`): it allowed landscape only with that option |
| After the change, the probe rebuilt (it now turns by default), in `landscape-right`, `landscape-left` and `portrait` | `frames`: 2436 × 1125, 2436 × 1125 and 1125 × 2436, `pictureTurn` 90, 270 and 0, each the size of the `screenshot` beside it; `record … 3`: 2464 × 1136, 2464 × 1136 and 1136 × 2464, 47 to 51 source pictures, `pictureTurn` in each result. The landscape-right picture and the landscape-left movie were looked at: upright, as the screenshot |

So `frames` and `record` now turn the panel's picture into the interface's orientation, as Apple's screenshot does, by the display's current orientation when the capture starts (`DirectTouchDisplay.pictureTurn`). A phone turned during a capture keeps the start's turn. The watch (a panel mounted sideways) and the Duo's inner display take the same rule.

**Later that evening, the Apple Watch Ultra** (watchOS 27.2.1, over the network), the watchOS probe installed for the run, launched and captured in one `batch` (a first try met the display going dark after the launch, a second a stale connection; the third, minutes later, ran whole): `frames` 422 × 514 and `record … 5` 448 × 528 (62 source pictures), both `pictureTurn: 270` and upright, the probe's rows reading normally; the `screenshot` beside them 422 × 514. Before the change the watch's pictures were 514 × 422 and sideways. The captures were deleted after reading and the probe uninstalled.

**Then the iPhone Duo**, unfolded by the human owner while the captures ran, its inner display (`LCD-1`, `currentOrientation: rot90`) the interface display, the iOS probe in front: `frames` 2016 × 1408 and `record … 3` 2016 × 1408, both `pictureTurn: 90` and upright, the probe reading normally in landscape; the `screenshot` beside them 2853 × 2007, landscape too. Before the change the inner display's pictures were 1408 × 2016 and sideways. The resolution stays what the device streams, about half the screenshot's. The captures were deleted after reading and the probe uninstalled.

### A second iPhone: the iPhone 17 Pro Max, inside the probe

**2026-11-25, afternoon**, the iPhone 17 Pro Max (iOS 27.2.1) on its cable, named by the human owner for the second-iPhone run under the iPad's privacy rule: the iOS probe installed by `build-run` with the signing already on the Mac (no registration needed), every step inside the probe, captures deleted after reading, the probe uninstalled after the run. Accessibility went over the tool's own tunnel (`serviceDirectory: own-tunnel`, `ownTunnelLink: cable`).

| Step | Observed |
| --- | --- |
| `test:probe-touch --repeat 5` (the built-in plan of 14 actions: taps at three points, a long press, a swipe, a drag, a pinch, two- to five-contact taps, a three-path drag and two gesture sequences), with the 200 ms input drain | 70 of 70 delivered, each with its contact count and the right number down at once; start positions within 0.0001 of the plan and hold times within −0.004 to +0.015 s; the probe counted 145 contacts began and 145 ended, none cancelled or unmatched, nothing dropped from its log; 380 s |
| `press --id probe.text.field`, `type " hello 17"`, `set-value --id probe.text.field "Año ¿qué?"` | `set-value` gave the field exactly `Año ¿qué?`, and typing after it gave `Año ¿qué? hello 17` |
| `screenshot` | 1320 × 2868, `blankImage: false`, the probe whole |
| `record … 5 --backend coredevice`, before a fix | Failed at the first picture: the stream negotiated 1328 × 2880 and coded 1328 × 2896. 2880 rows are already on a 32-pixel boundary, and the decoder accepted only padding up to that boundary |
| The same after the fix (a larger coded size is accepted when it is whole 16-pixel blocks and at most 32 pixels more, `NativeHEVCDecoder.acceptsCodedDimensions`) | `status: recorded`, 86 source pictures in 5 s, a movie of 1328 × 2896 showing the probe whole with nothing stray at the bottom |
| `batch` `[["hold","0.3","0.6"],["tap","0.7","0.6"],["release"]]` | Completed; the probe's last gesture was two contacts, the held one at (0.300, 0.600) for 0.436 s and the tap at (0.700, 0.600) for 0.081 s inside it |

So the 200 ms input drain chosen on the iPhone 13 mini delivers every planned touch on a second, newer phone too, and every command family tried there works inside the probe once the recording accepts this phone's coded size.

### The iPhone Duo's commands beyond the probe

**2026-11-25, afternoon**, the paired iPhone Duo (iOS 27.2.1), on the human owner's word for the six commands that reach beyond the probe, under its privacy rule: the iOS probe installed by `build-run` and in front, nothing of another app printed or kept, every output deleted after its counts were read, the probe uninstalled after the run.

| Step | Observed |
| --- | --- |
| `paste "Pegado ¿sí? 🍎"` into the probe's field (it replaces the clipboard) | Exit 0, and iOS asked "“Probe” would like to paste from “dtpasteboardd”": the pasteboard's text came from the device's developer pasteboard service, another process. `press --label "Allow Paste"` answered it, and the field read exactly `Pegado ¿sí? 🍎` |
| `settings` (read only) | Exit 0, the device's current settings read; nothing changed |
| `apps` | Exit 0, 275 apps listed, the probe among them; only the count was read |
| `reports list` | Exit 0, 18 entries in the top directory; only the count was read |
| `button lock` | `dispatched`; `readiness` then read `displayPower: off` and `passcodeRequired: true` |
| `wake` | Exit 1, `awake-locked`: the display came on (`displayPower: on`) and the lock screen stayed, because the Duo needs its passcode after a lock and `wake` never enters one; the human owner unlocks it |

So every command family has now run on the physical Duo. A paste into an app asks the person once for that app, since the text comes from another process; answer it by its label, as above.

### Reboot on a simulator and on an iPhone

**2026-11-25**, Xcode 27.2's `simctl`, an iPhone Air simulator (iOS 27.2) booted for the run and shut down after it.

| Step | Observed |
| --- | --- |
| `reboot --simulator <UUID>` | Exit 0 after 4 s, the simulator `Booted` again |
| The same, with SpringBoard's PID read from `launchctl list` in the simulator before and after | A new PID afterwards, so the simulator really restarted |

The same day on the iPhone 17 Pro Max (iOS 27.2.1), over the network, named by the human owner:

| Step | Observed |
| --- | --- |
| `reboot --device <UDID>` while the phone had not been unlocked for a while (`readiness`: `connection: disconnected`) | Refused at once, nothing done: `devicectl` answered CoreDevice error 10003, "the device was still locked", caused by RemotePairing error 1016, "The device has not been unlocked recently". The tool reported it as `tool-failed` with `inputSent: unknown`; since then such an answer is `device-not-ready`, `inputSent: none`, with a message that says to unlock the device (`CommandFailure.lockedDevice`) |
| `reboot --device <UDID>` again, after the phone had been unlocked | Exit 0 at once, `devicectl`'s outcome `success`; `readiness` read `connection: unavailable` for 50 s and `connected` at 60 s |

So `devicectl device reboot` returns when the device takes the request, and a phone that has not been unlocked recently refuses it, as it refuses every `devicectl` request.

### An Apple Watch's log relay sends nothing, and why

**2026-11-25, midday**, the same Apple Watch (an Ultra, watchOS 27.2.1) on the human owner's wrist, over the local network and Apple's tunnel (the tool's own is not available for a watch), the watchOS probe installed by `build-run`. Each capture at `debug`, with presses of `probe.watch.button.b` from a second process meanwhile, the probe seen in front in a tree first.

| Step | Observed |
| --- | --- |
| `logs --seconds 20 --bundle` the probe (the watch is asked for one PID), two presses, both `postcondition-verified` | `deviceStream: pid <n>`, `receivedBytes: 0`, `receivedRecords: 0`, `stopReason: duration`, `processWatch: devicectl`, `serviceDirectory: opened` |
| `logs --seconds 20 --bundle` the probe `--process ProbeWatch` (a group: the watch is asked for every process and the Mac keeps the probe's), two presses | `deviceStream: every process`, `receivedBytes: 0`, `receivedRecords: 0` |
| The same group for 60 seconds, five presses, all five taking effect | `receivedBytes: 0`, `receivedRecords: 0`, `stopReason: duration` |
| Apple's Console on the Mac, the watch selected and streaming started by the human owner | Nothing shown. Meanwhile the Mac's `remoted` logged one request from Apple's MobileDevice helper (`MDRemoteServiceSupport`) for `com.apple.os_trace_relay.shim.remote`, the service `logs` opens, and no request from it for another log service; the line does not name the device |
| Console again, with the watch's iPhone on a cable to the Mac and the watch on its charger (the human owner, the same afternoon) | Still nothing shown |

So the relay accepts the check-in and the stream request (the tool reads nothing before `RequestSuccessful`) and then sends no byte, whichever processes are asked for and for a minute; neither the PID in the request nor a short window is the cause, and Apple's own client gets no more. Apple's sources give the reason, logging being off on watchOS without Apple's logging profile; they are quoted with their links in [app logs](app-logs.md#an-apple-watch). The cable and the charger that Apple's pages also name were not enough without it. With the profile installed nothing has been run. Since that day a watch's empty result says so (`streamNote`).

**Later that afternoon, with the profile.** The human owner installed Apple's watchOS logging profile through the iPhone, as Apple's instructions say, and restarted the watch. Console on the Mac still showed nothing. `logs` did not:

| Step | Observed |
| --- | --- |
| `logs --seconds 60 --bundle` the probe `--process ProbeWatch` (every process asked for, the probe's kept), the probe seen in front first, five presses of which three took effect (the display went off before the fourth) | `receivedBytes: 107079791`, `receivedRecords: 252330`, `parseFailures: 0`, `stopReason: duration`; 850 entries kept, all the probe's, the three presses among them (`watch 1 button:b` to `watch 3 button:b`, level `info`, category `watch`) |
| `logs --seconds 20 --bundle` the probe (one PID asked for), twice | `receivedBytes: 0` both times, but neither counts: the display was off, both presses beside each were refused, and the second time the probe was not seen in front. Whether a watch honours a one-PID request was left open |
| The one-PID capture again, 20 s, the probe seen in front and all three presses taking effect | `deviceStream: pid <n>`, `receivedBytes: 330271`, `receivedRecords: 735`, every one the probe's, the three presses among them (`watch 4 button:b` to `watch 6 button:b`), `filteredOut: 0` |

So the profile switches the relay's stream on, for one process and for every process, while Apple's Console on the same Mac stayed empty. A watch with the profile sends about 107 MB a minute for every process at debug, so the 256 MiB received bound ends such a capture after about two and a half minutes.

What the run met on the way, for the next one on a watch:

- The watch's link drops and its display sleeps between commands; a command then fails with CoreDevice error 4000, with "Primary display is off", or reports the probe as not installed although it is. Launching an app brings both back (the human owner's finding with Apple's Home app; the probe's `launch` does the same), so launch the probe and send the steps that follow in one `batch`.
- The watch returns to the clock two minutes after an app was launched (Settings › General › Return to Clock, read there in Settings by the human owner's word and left as it was), so a tree taken later than that shows another screen and a press finds nothing.
- Three longer captures failed that way before the 60-second one ran; an empty result on a watch is only a fact when the presses beside it took effect.

### First run on a physical iPhone Duo

**2026-11-25, around 01:00**, the iPhone Duo paired with the Mac (`iPhone19,4`, iOS 27.2.1, build `24B91034`) over the local network, unfolded, with the human owner's word for each step. The device has the iPad mini's privacy restrictions, so everything ran inside the probe app (`build-run` installed it), every capture was deleted after reading, and nothing else on it is recorded here. `xcodebuild` logged that it could not parse the build string `24B91034`; the build, signing and install went through.

| Step | Observed |
| --- | --- |
| `devicectl device info displays` | Two integrated displays, as on the Duo simulator: the outer `LCD` (id 1, `primary: true`, 1398 × 2034 pixels, 466 × 678 points at 3×, `backlightState: off`) and the inner `LCD-1` (id 2, `primary: false`, `activeOn`, bounds 2007 × 2853, `nativeSize` 1878 × 2670, `nativeOrientation: rot0`, `currentOrientation: rot90`); the device `landscapeRight`. Each has its own `uniqueId`. Both panels are native portrait: no sideways panel, unlike the iPad and the watch |
| `readiness`, before a fix | `displayPower: off`: it read the primary display only. Fixed the same night: every physical display read takes the display the interface is on (`DeviceUIReadiness.interfaceDisplay`, the simulator's rule); `readiness` then said `on` |
| `tree`, twice, before a fix | The application selected by the centre hit test was a system process of the outer display, not the probe, both times (the probe was in front): physical hit tests always named display 0. Both trees were deleted unread. Fixed: hit tests carry the inner display's ID when the interface is there (`AccessibilityDisplay.hitDisplayId`) |
| `tree` after the fix | The probe, on the tool's own tunnel over the network (`ownTunnelLink: network`); display id 2, 669 × 951 points, `rot0`: by then the inner display read upright, the probe being portrait only, and it filled the display with no letterbox |
| `press --id probe.touch.reset` | Accepted |
| `tap 0.5 0.5`, before a fix | Dispatched, and the probe counted no touch: Indigo digitizer samples go to the primary display, as on the simulator |
| `screenshot`, before a fix | 1398 × 2034 and black (`blankImage: true`): `devicectl` captures the primary display unless given `--display-unique-id`. Fixed: a physical screenshot names the interface display when it is not the primary one; then 2007 × 2853, the probe whole and upright |
| `tap 0.5 0.5` after the fix | `route: universal-hid`, six reports to the inner display's own touchscreen (`CoreDevice touchscreen(<unique ID>)`, surface 258): the probe recorded one contact, began and ended at (0.50025, 0.50018), 0.12 s |

Later the same night, still unfolded and inside the probe:

| Step | Observed |
| --- | --- |
| The probe, portrait only, with the device held in landscape | The inner display turned to portrait for the probe (`rot0`), so the person holding the device saw it sideways; once the device was turned, the inner display read `rot90` (951 × 669 points) and the probe was letterboxed as on the simulator |
| `test:probe-touch --no-pull` (built-in plan) | 14 of 14 actions and 29 of 29 contacts delivered, one to five at once, taps, a long press, a swipe, a drag, a pinch, multi-drags and two gesture sequences; worst start error 0.0003, all through the inner display's touchscreen |
| `type 'Hola Duo 123'`, `set-value 'añadido ñ €'` in the probe's field | Both exact |
| `record … 5 --backend coredevice`, `frames --count 1`, before a fix | Both failed at the decoder: "coded dimensions 1408x2016 differ from negotiated 1408x2048". The kept stream (`MANZANERO_KEEP_STREAM=1`) decoded with ffmpeg at 1408 × 2016: the inner display, sideways, fitted into the middle of the frame with black bands above and below; 1408 × 2048 is the outer display's size, padded. Fixed: a coded size up to a sixteenth smaller than the negotiated one is accepted |
| The same after the fix | `record`: 5.0 s, 80 frames, 1408 × 2016, no restart. `frames`: one picture, not black or flat. Both show the inner display sideways at about half its resolution, as the device sends it (deleted after reading) |

Folded by hand, the probe in front on the outer display, with the fixes in:

| Step | Observed |
| --- | --- |
| `devicectl device info displays`, `readiness` | `LCD` `activeOn`, `LCD-1` off; `displayPower: on` |
| `tree` | The probe, display 1, 466 × 678 points, `rot0`, on the tool's own tunnel |
| `press --id probe.touch.reset`, `test:probe-touch --no-pull` | 14 of 14 actions and 29 of 29 contacts delivered, worst start error 0.0004, through the outer display's own touchscreen (the device has two, so touch names one) |
| `type 'Plegado 42'` | Exact |
| `screenshot`, `frames --count 1` | Both 1398 × 2034, upright, the probe whole, not black (deleted after reading); the stream negotiated 1408 × 2048 and the frame was cropped to the display |

Then unfolded again, in landscape, the probe relaunched with `-ProbeAllowRotation YES`:

| Step | Observed |
| --- | --- |
| `tree` | The probe full screen on the inner display, 951 × 669 points, `rot90` |
| `press --id probe.touch.reset`, `tap 0.25 0.4` | Accepted; the tap went to the inner display's touchscreen and the probe recorded it at (0.2499, 0.4001) |
| `screenshot` | 2853 × 2007, landscape, upright, the probe whole (deleted after reading) |
| `wait --id probe.touch.reset --until gone --timeout 60`, the device folded by hand 10 s in | After 9 polls (16 s) the wait stopped with "display geometry/orientation changed during the wait; the condition is not reported", no input sent, the session closed and the tunnel released. Its last poll, after the fold, had found the element absent in process 37: without the display check it would have reported `gone` |

The other families, folded, inside the probe:

| Step | Observed |
| --- | --- |
| `console` the probe, 5 s | Its stdout lines arrived; the launch ended at its bound with signal 2, which closes the probe: a command meant for the probe that follows needs a `launch` first |
| `logs --bundle` the probe, 15 s, `debug`, with two presses of `probe.log.emit` | 370 entries, all the probe's, its two emitted lines among them, on the tool's own tunnel (`ownTunnelLink: network`), `stopReason: duration`. Unlike the watch's relay, the Duo's sends |
| `last-crash --bundle` the probe | Printed the device's whole crash-report directory listing (54 entries) before its answer: it does not keep to the bundle while it lists. Nothing of it is recorded; on a device under a privacy rule it is not to be run |
| `files list` of the probe's container | Its four directories |
| `batch`: press, `tap 0.5 0.3`, `wait` | Three of three steps; the tap recorded at (0.500, 0.300) |
| `handoff --until visible --id probe.touch.reset` | Ended by itself, `status: observed`, 5 s |
| `test:mcp-press` (a real MCP session) on `probe.touch.reset` | Passed |

After the hold was built for a device with two touchscreens (its stream names the display's own touchscreen):

| Step | Observed |
| --- | --- |
| `batch` `hold 0.3 0.3`, `tap 0.7 0.7`, `release`, folded (outer display, surface 257) | Completed; the tap was merged into the hold's stream as contact 1 (six reports, nine in all). The probe's touch surface recorded the held contact, at (0.300, 0.300) for 0.80 s, and not the tap |
| The same unfolded (inner display, surface 258; the probe letterboxed) | The same: the held contact for 0.84 s (at 0.095 of the probe's 469-point window, the display's 0.3), and no tap |
| The same shape as one finished `gesture` (contact 1 at (0.7, 0.7) for 0.08 s, then for 0.3 s), unfolded | Contact 0 alone, both times |

None of this is a fault of the Duo or of the hold. (0.7, 0.7) is on the probe's text field, which spans the width at about 0.66 to 0.72 of the height in a 466 × 678 or 469 × 669 portrait layout, and the field takes the touch itself, so the touch surface never counts it. The touch plan keeps its points between y 0.3 and 0.65 for that reason, and the phone's hold run used (0.7, 0.6). The point was chosen without a look at the layout; the human owner's question whether each screen was used properly led to the check. Rerun at once on the touch surface, unfolded: `hold 0.3 0.5`, `tap 0.7 0.5`, `release` gave one gesture of two contacts, the held one 0.99 s at (0.095, 0.500) of the probe's window and the tap 0.08 s at (0.905, 0.500) during it, `maxActive: 2` |

A fold during input, in the probe, the human owner folding by hand about 3 s into a 10-second `long-press 0.3 0.5 10`:

| Step | Observed |
| --- | --- |
| Folded during the press, before a change | The receipt said `dispatched` (surface 258, the inner display's touchscreen) and nothing else, while the probe on the inner display recorded the contact `cancelled` after 1.02 s: iOS ended it at the fold, and the rest of the press went to a display that was off. Changed the same night: touch and gesture receipts read the display once more after the input and say `displayAfter` (`unchanged`, `changed`, `unknown`) |
| A tap, folded, after the change | `displayAfter: unchanged` |
| Unfolded during the press, after the change | `displayAfter: changed` with its note; the probe recorded the contact `cancelled` after 1.51 s. The device was not quarantined: the contact ended by the system's cancel, and the tool's release went to the touchscreen it was sent on |

The remaining commands that stay in the probe, unfolded:

| Step | Observed |
| --- | --- |
| `screen` | `method: accessibility`, the probe's elements |
| `key backspace` after `set-value abc` | The field read `ab` |
| `detect-layout --id probe.text.field` | Spanish – ISO (`com.apple.keylayout.Spanish-ISO`), the field restored by `set-value` |
| The probe with `-ProbeList YES`: `scroll --search 20 --id probe.list.row.55`, then `--search 30 --toward up --id probe.list.row.2` | Row 55 found downward; row 2 found upward in 20 steps, `postcondition-verified`. A search sent right after `launch` found nothing: the list was not yet on screen |
| `open-url manzanero-probe://duo-check` | `probe.url` read `1 manzanero-probe://duo-check`, with no prompt |
| `terminate` the probe by bundle, `launch` | Both succeeded. A relaunch without `-ProbeAllowRotation YES` brings the probe back portrait only, and the inner display turns to portrait for it; with the argument it turned back to landscape a few seconds after the launch |

Not run: `paste` (it replaces the device's clipboard, beyond the probe), `button lock` and `wake` (Claude Code's permission check refused the run), and `apps`, `reports`, `settings` and `last-crash` beyond the listing above (each reads beyond the probe; the permission check refused them too).

### First run on a physical iPad: the iPad mini (6th generation)

**2026-11-24, evening**, an iPad mini (6th generation) (iPadOS 27.2.1), on its cable, with the human owner's word for each step: the device has top privacy restrictions, so everything ran inside the probe app, every capture was deleted after reading, and nothing else on it is recorded here.

| Step | Observed |
| --- | --- |
| `details`, `readiness`, `devicectl device info displays` | Developer mode on, display on, no passcode required. The panel is mounted natively landscape: `nativeOrientation: rot270`, `currentOrientation: rot90`, bounds 2266 × 1488 pixels while held in portrait |
| `tree` | Refused before reading anything: "Invalid, ambiguous or unsupported primary display geometry", since accessibility took every panel as natively portrait. Fixed the same day: the interface's turn is the sum of the two orientations, as touch already took it, and a sideways panel's bounds are read the other way round |
| `tree` of the probe after the fix | On the tool's own tunnel over the cable (`ownTunnelLink: cable`); display 744 × 1133 points, `rot0`; the probe's elements with their frames |
| `press --id probe.touch.reset` | Accepted: the hit-test mapping is right |
| `test:probe-touch` (`--no-pull`, readouts only) | All 14 actions of the built-in plan delivered: taps, a long press, a swipe, a drag, a pinch, two to five simultaneous contacts, sequences; worst start error 0.0003 of the screen |
| A four-path `multi-drag` | iPadOS cancelled all four contacts after 0.095 s, as on the iPad simulators |
| `type 'Hola iPad 123'`, `set-value 'añadido ñ €'` in the probe's field | Both exact |
| The probe relaunched with `-ProbeAllowRotation YES`, `rotate landscape-left` | `tree`: 1133 × 744 points, `rot270`; `press --id probe.touch.reset` accepted; a tap at (0.25, 0.4) recorded at (0.250, 0.400) |
| `record` 5 s, `frames --count 1` (deleted at once) | 94 frames, no restart; the frame 2266 × 1488, not black |
| `rotate portrait`, the probe closed | |

The probe app, put there by an install interrupted before the human owner set the rule of asking first, was uninstalled afterwards at the human owner's request; the app list no longer has it.

### Biometrics on the phone: no type to control

**2026-11-24, 19:45**, the iPhone 13 mini (iOS 27.2.1), on the human owner's word, unlocked, with no Face ID enrolled.

| Step | Observed |
| --- | --- |
| `settings --biometrics state` | devicectl: "WARNING: Device does not support any biometrics" on stderr; `outcome: success`, `biometrics: []` |
| `settings --biometrics on`, once | "Device does not support any biometrics, nothing to do" on stderr, yet `outcome: success` and `enabled: true` in the JSON: a reader of the result alone would believe Face ID had been enabled. Fixed the same day: an empty `biometrics` list makes the result say `biometricsSupported: false`, `changed: false` and why (`biometricsNote`) |
| `settings --biometrics off`, `state`, with the fix | `changed: false` and `biometricsSupported: false` with the note; nothing on the phone changed |

So `devicectl device settings biometrics` controls no biometric type on this phone, although it has Face ID hardware: the enrolment it switches is a simulator's (and perhaps an internal device's), and a real prompt on a phone needs a face enrolled by a person. No prompt was raised and nothing was put back, since nothing had changed.

### StandBy on the phone, refused by the device

**2026-11-24, 19:25**, the iPhone 13 mini (iOS 27.2.1), on its cable and charging.

| Step | Observed |
| --- | --- |
| `button lock`, then `wake --no-dismiss` | `awake-locked`: the lock screen, display on |
| `settings --standby show --standby-seconds 10` | Refused by `devicectl`: "The capability 'StandBy' is not supported by this device" (CoreDevice error 1001, `CapabilityFeatureIdentifier = com.apple.coredevice.feature.standby`); the phone's `details` list no such capability |
| `button home` afterwards | The receipt's `lockNote`: a passcode is required. The phone has one set, so locking it left it locked until the human owner unlocked it by hand |

So `settings --standby` does not apply to this phone; a device whose capabilities include `com.apple.coredevice.feature.standby` is needed to see it work. Before locking a phone, read `readiness`'s `passcodeRequired` and the lock state: the tool does not enter passcodes.

### Crash symbols for a stripped build on the phone

**2026-11-24, 18:30**, the iPhone 13 mini (iOS 27.2.1), display on and unlocked.

| Step | Observed |
| --- | --- |
| `xcodebuild archive` of the iOS probe, Release, generic iOS | An `.xcarchive` with `ProbeApp.app` and `dSYMs/ProbeApp.app.dSYM`; the executable stripped (no local text symbols in `nm`), its UUID the dSYM's |
| `install` of the archived `.app`, then `console … -- -probeCrash trap` | The probe crashed with `fatalError` (`exited(1)`) |
| `last-crash --process ProbeApp` | `SIGTRAP`; the first frame `_assertionFailure` in libswiftCore, then two `ProbeApp` frames with an offset and no symbol |
| `--symbols <archive>/dSYMs` | First failed: the folder went to `dwarfdump` whole ("Is a directory"). Fixed the same day: a folder gives the DWARF files of each `.dSYM` in it, an `.xcarchive` those of its `dSYMs` |
| `--symbols <archive>/dSYMs`, then `--symbols <archive>` | Each: the UUID matched the `ProbeApp` image, 2 frames resolved, named `closure #1 in LogProbeEmitter.launched(arguments:)` and `thunk for @escaping @callee_guaranteed @Sendable () -> ()`, `<compiler-generated>:0` |

The archived Release probe stayed installed on the phone in place of the development build.

### A thirty-minute session on the Apple TV's own pairing

**2026-11-24, about 17:45 to 18:15**, the Apple TV 4K (tvOS 27.2), through the MCP server connected to Claude Code (one process), nothing played: `wake_device`, then eight rounds four to five minutes apart of `press_remote` arrows and swipes with `report_focus` and `wait_for_element` `until: focused`, by label and by handle; then `press_remote sleep`.

| Observed | |
| --- | --- |
| Every call | On the tool's own pairing (`serviceDirectory: own-tunnel`, `ownTunnelLink: paired`); none failed |
| A handle | The TV icon's handle read at about 14 minutes (`ax:<pid>:<object>`) met a focus wait at about 26 minutes |
| The screen saver | It started within four to five idle minutes (the device's own setting) and twice took the front: the reported focus was then one full-screen element of another process, an arrow did not end it, Home did; the last round found it again, and `remote sleep` from it ended `asleep`, `verified: true` |
| Afterwards | `remotectl dumpstate`: the device's connection `connected (connectable)`, not stale |

So the tool's own pairing holds a half-hour session of presses, focus reports and waits with no fault, and a screen saver shows in a focus report as a full-screen element with no label.

### `remote sleep` on an Apple TV in Spanish

**2026-11-24, about 17:30**, the Apple TV 4K (tvOS 27.2), on the human owner's word: the device's language changed to Spanish and back, all by the tool over its own pairing.

| Step | Observed |
| --- | --- |
| Settings › General › Apple TV Languages | `devicectl device settings` has no language subcommand. Selecting Español in the list changed nothing; Edit, then the row's reorder handle (`Reorder Español, Spanish`), select, two `remote up`, select, and Done pressed by its label put Español first, and the interface was in Spanish ("Idiomas del Apple TV") |
| `remote home`, `remote sleep` | `lock`, `power-off`, `status: asleep`, `verified: true`, 16 s: Power Off is pressed by its identifier, which does not change with the language |
| Back to English | `wake`; in Spanish the same way (`Editar`, `Reordenar Español`, `OK` by label); the list again English, English (US), Español, the interface in English; `remote sleep` |

What the run taught about driving such a screen:

- The tree lists Settings' rows bottom to top; the screen has About at the top. Read the direction from a screenshot or from `--report-focus`, not from node order.
- Labels can hold a non-breaking space (`Apple\u00a0TV Languages`): compare them as the tool's `--match contains` does, not byte for byte in a script.
- `press --label` refused `Apple TV Languages` (no match in the bounded snapshot) where arrows with `--report-focus` and a select reached it.
- In edit mode a press can land the focus on a row's trash button: every select there was preceded by a focus report, and Done and OK were pressed by label, which moves no focus.
- A reorder sometimes moved a row one place for two arrows, or none: look after each drop.

### Sound across a pulled Ethernet cable on the Apple TV 4K

**2026-11-24, 17:08**, the Apple TV 4K (tvOS 27.2) on Ethernet, the tvOS probe's [tone](probe-app.md#a-tone) playing (`probe.tv.tone` read `playing`), with the human owner's word and at the television: `record tmp/tone-loss.mp4 60 --backend coredevice --audio`; the human owner pulled the Ethernet cable a few seconds in and plugged it back about ten seconds later.

| Observed | |
| --- | --- |
| Result | `status: recorded`, 60 s; `recovery.restarts: 2`, one gap `{atSeconds: 2.318, seconds: 17.778, reason: stream-ended}`; `audioTrack.restarts: 1`, 4262 sound packets, none lost or refused, 42.62 s of received sound |
| The track, its level every two seconds | The beeps from 0 to 2 s, digital silence from 4 to 16 s, the beeps again from 18 s to the end (RMS about 7400 to 8400); 59.92 s in all |

So a recording with sound recovers on the Apple TV as on the phone: the sound stream starts again with the session, and the gap is written as silence, so the sound after it keeps its place. The probe was closed twenty seconds after the recording ended and the device put to sleep.

Sound against picture, measured the same evening with AVFoundation from the movie itself: the times of the probe's white flashes (frames whose mean is near white) against the start of each round's first beep in the sound track (the first loud sample after the 0.4-second rest). The sound's rounds are exactly 1.600 s apart; the flashes, drawn by the probe at the display's pace, from 1.54 to 1.70 s.

| Movie | Picture after sound |
| --- | --- |
| A 20-second baseline with no loss, made for this (the probe closed in the same command) | −7 to +140 ms over twelve rounds, about +60 ms in the middle; one flash 487 ms late, a frame missed |
| The cable-pull movie, the one round before the gap | +38 ms |
| The same movie, the 25 rounds after the gap | +113 to +250 ms, about +150 ms in the middle, with no drift over 38 s |

So after a restart the Apple TV's picture runs about 0.1 s, some three frames, later against its sound than without one, and stays there; on the phone the sound after a restart was within a frame or two (2026-11-22). Part of the spread is the probe's own flash, which follows the player's position less the output latency the audio session reports.


### The tool's host removed on the Apple TV, and paired again

**2026-11-24, about 17:00**, the Apple TV 4K (tvOS 27.2), the human owner at the television.

| Step | Observed |
| --- | --- |
| `tree` before | On the tool's own pairing (`ownTunnelLink: paired`) |
| The human owner removed the host `manzanero` in Settings › Remotes and Devices › Remote App and Devices | |
| `tree` | Refused, exit 1, nothing sent: "An Apple TV's accessibility commands run only on the tool's own tunnel, and it was not available: The device no longer knows the tool's pairing; pair again with manzanero pair. No tunnel was opened." No route over Apple's tunnel was tried. The message first said `serviceDirectory=opened`, although no connection had been made, and doubled a full stop; both fixed the same day (`serviceDirectory=none`) |
| `wait --label Settings` | Refused the same way |
| `devices` | Still listed the Apple TV as `paired`: it reads this Mac's identity, not the device's list |
| `pair --pin-file`, the Remote App and Devices screen still open | The television showed a PIN; the human owner wrote it to the file; `status: paired`, with this Mac's existing identity: no `--forget` was needed |
| `tree` | On the new pairing (`ownTunnelLink: paired`, `serviceDirectory: own-tunnel`) |

### Music playing aloud, and a silent sound track, on the Apple TV 4K

**2026-11-24, about 16:30 to 16:50**, the Apple TV 4K (tvOS 27.2), Apple's Music app (`com.apple.TVMusic`) playing an Apple Music radio station, on the human owner's word, at the volume as it was; `record … --backend coredevice --audio`, the position read from the Now Playing progress bar's value (`TVMusic.nowPlaying.progressBar`, "1:45 elapsed, 6:05 remaining"), the human owner listening in the room.

| Run | Observed |
| --- | --- |
| 30 s, the station started by `press --id` on its tile | `status: recorded`, 3021 sound packets, none lost, 30.21 s written; every sample of the track zero. The human owner heard nothing in the room, so the run proved nothing |
| 20 s after blind `play-pause` presses | The presses were out of step with the player: the music was paused during the recording and started at the "pause" afterwards, as the human owner heard. Track all zeros, as it should be |
| 20 s with the playback checked first: two reads of the progress bar 3 s apart (1:48, then 1:55), then the recording, then a `play-pause` checked the same way (2:38 twice) | The human owner heard the music before, during and after the recording; the player advanced 51 s in 51 s, through the recording. 2008 sound packets, none lost; every sample of the track zero |

So a recording does not silence the Apple TV's own output (the human owner's question): the music went on aloud while the stream carried digital silence. Either Apple Music's protected audio is left out of the system audio the device streams, as FairPlay video is left out of its pictures, or the Apple TV's sound stream has never carried sound: every earlier Apple TV recording with `--audio` was made with nothing playing. The phone's stream carried the iOS probe's tone. Toggle a player only after reading its state: a blind `play-pause` started the music instead of pausing it.

The same afternoon the tvOS probe got the iOS probe's tone ([a tone](probe-app.md#a-tone)), a sound with no DRM. Built onto the device with `build-run`, relaunched with `-ProbeTone YES` (`probe.tv.tone` read `playing`), with the human owner listening in the room at the volume as it was: a 20-second `record … --backend coredevice --audio` took 2009 sound packets, none lost, and the track held the beeps from start to end, at an RMS level of about 7940 and peaks of 16644 in every four-second stretch (the probe plays at half of full scale). The probe was closed at once. So the Apple TV's sound stream carries what the device plays, and Apple Music's audio, which is protected, is left out of it, as FairPlay video is left out of the device's pictures.

### Scrub on a simulator and on the Apple TV 4K

**2026-11-24.** `scrub --to` against the tvOS probe's silent video (`-ProbeVideo YES`, Apple's player), on `manzanero-research-tv-4k` (tvOS 27.2) and on the Apple TV 4K (tvOS 27.2, the tool's own pairing).

| Where, goal | Observed |
| --- | --- |
| Simulator, first build, 5:00 | 12 swipes moved nothing but playback: the controls were showing after the launch while the video played. Fixed: two readings 1.5 s apart tell playing from paused |
| Simulator, then 5:00 from 0:36 paused | Reached 297 s in 17 s: 10 swipes, each full 0.6 s swipe about 30 s of preview |
| Simulator, one paused swipe at full travel | 0.6 s: +30 s; 0.2 s: +71 s; 0.1 s: +132 s. The speed became a second knob |
| Simulator, 9:00, 40 %, 2:00 (playing, controls hidden), 3:00 and 1:00 back to back | Reached 535, 243, 117, 176 and 65 s, in 8 to 17 s; one earlier run right after another failed once and was not reproduced in three tries |
| Apple TV, 7:30 from 0:09 | Reached 449 s in 65 s: play-pause, then swipes of 0.6, 0.3, 0.2 and 0.1 s; one 0.1 s swipe moved nothing |
| Apple TV, 1:00 from 7:36, first loop | Not reached: 71 s after 11 swipes; 0.1 s swipes moved the preview 27, 209 and 0 s, swinging around the target. Fixed: slower swipes near the end and after an overshoot |
| Apple TV, 50 % | Reached 296 s in 41 s |
| Apple TV after the fix: 1:00, 8:30, 2:15 | Reached 60, 509 and 137 s, in 46, 65 and 51 s |
| Apple TV, a third-party streaming app, a 1311-second episode under FairPlay, on the human owner's word: 15:00, 5:00, 90 % | Reached 900, 298 and 1183 s (target 1181), in 52, 63 and 57 s, each after pausing the playing video itself; the picture was black to every capture and the times came from the player's controls |

Before that run, ten minutes after a `remote sleep`, `wake` failed: its screenshot was refused with CoreDevice error 25004 ("The screen capture operation failed"), not the 25005 of a zero-sized display that marks sleep, so it pressed nothing, and `readiness` said `sleepStateUnknown`. One `remote home` woke the device, and the next screenshot was black once before the Home Screen came. The active profile could not be read from the app's tree (its avatar is labelled generically); when the profile screen's countdown ran out, the app most likely took the one used last.

### FairPlay video on the Apple TV 4K

**2026-11-24, morning**, in a third-party streaming app with FairPlay-protected video and a series, both chosen by the human owner; the episodes played with sound, which the human owner had asked for, and were paused after each capture.

| Step | Observed |
| --- | --- |
| `wake`, `launch` | Awake (`hidWaits: 0`); the app's profile screen, with a countdown |
| `press --label <profile>` | The app's home page followed |
| `press --label <first episode's tile>` | Refused before sending (`live-attributes`): the tile was below the screen. `scroll --label` on it: `postcondition-failed`, this app's rows move by focus only. Moving the focus with `remote up`/`down` and reading the tile's frame from a fresh tree after each press, then a screenshot showing the tile focused, then `remote select` |
| `remote --report-focus` in this app | The focused node had no label or identifier, only a frame: the receipt can only be as good as the app's accessibility |
| `remote select` on the episode page's E1 | The pilot had been watched almost to the end: the app showed its "next episode" screen and counted down into E2 |
| `screenshot` while E2 played | Entirely black, `blankImage: true`, `playerOnScreen: true` with the player note |
| `frames --count 2` while it played | Both black, `blankFrames: 2` |
| `press --label <the app's start button>`, then the same captures | Screenshot black with `playerOnScreen: true`; `frames` both black |
| `remote play-pause`, `tree` | `AXElapsedTime` `00:18`; `Media Controls` "Tiempo transcurrido: 18 segundos, Tiempo restante: 21 minutos, 33 segundos" (in the device's language: read the position from `AXElapsedTime`) |
| `screenshot` while paused | The player's controls (title, bar, 00:18, "Información") drawn over a black video area; `blankImage: false` |
| `frames` while paused, one and then three half a second apart | Each a single flat dark green (RGB 1, 94, 1), not the controls |
| `remote sleep` | `asleep` |

So FairPlay video, unlike a layer that prevents capture, is left out of the stream as well as of screenshots: black while playing, a flat green picture while paused. The screenshot leaves out the video alone and keeps the interface drawn over it. The black-picture notes were changed the same day to say so, and `frames` counts flat pictures of any colour as `uniform`.

### Apple TV session of 2026-11-24: wake, the focus, a protected picture and seeking

**2026-11-24, morning**, the Apple TV 4K (`AppleTV14,1`, tvOS 27.2), on the tool's own pairing (`ownTunnel: paired`), on the human owner's word to go on with the Apple TV checks; the room kept quiet (the probe's movies have no sound track, its player is muted, and no recording took sound).

| Step | Observed |
| --- | --- |
| `readiness` on the sleeping device | `asleep: true`, with the advice to wake it |
| `wake` | `operation: wake`, Home pressed once, `status: awake`, `verified: true`, `hidWaits: 0`, 13 s; then `readiness` `asleep: false`; a screenshot showed the Home Screen |
| `remote right --report-focus` on the Home Screen | `focus.label` `JustWatchTV`, `identifier` `AppCell`; the screenshot afterwards showed JustWatchTV focused |
| `build-run` of the tvOS probe | Built, installed and launched |
| `-ProbeVideoProtected YES`: the tree | `probe.tv.video.protected` `preventsCapture`, `probe.tv.video.time` advancing (0.0, then 5.0) |
| `screenshot` over it | Entirely black, the readouts outside the protected layer too; `blankImage: true`, the Apple TV `blankNote`, `playerOnScreen: false` (it is not Apple's player view, as expected) |
| `frames --count 3` and a 5-second `record --backend coredevice` over it | The picture whole in every frame and in the movie (00:22.8 and 00:27.2 with the readouts), `blankFrames: 0`: the device's video stream does not honour `preventsCapture`, where its screenshot does |
| `-ProbeVideo YES` (Apple's player), one `remote right` while playing | 13.5 s, then 29.5 s six seconds later: a 10-second skip |
| One `remote left` while playing | 42.0 s, then 38.0 s five seconds later: a 10-second skip back |
| `remote play-pause`, `remote swipe-right --travel 0.8 --seconds 0.6`, `remote select` | Paused at 45.9 s; the swipe moved `Media Controls` to 1:10 with the video still at 45.9; the select resumed at about 73 s |
| `remote right --hold 3` while playing, then `remote play-pause` | Scanning (rate 0, the bar at 2:16, the picture at 90.5 s); the play-pause resumed at 155.5 s |
| `remote sleep` | `lock`, `power-off`, `status: asleep`; `readiness` `asleep: true` |

So the screenshot's black is the device's screenshot alone: the stream `record` and `frames` read shows what a layer that prevents capture hides. FairPlay video is a separate mechanism and was not tried. Seeking on the device is as on the simulator.

### Phone session of 2026-11-24: handles, the cost of a tree, symbols and VoiceOver

**2026-11-24, morning**, the iPhone 13 mini (iOS 27.2.1) on its cable, display on and unlocked, the probe in front; every accessibility command ran on the tool's own tunnel (`serviceDirectory: own-tunnel`), on the human owner's word to go on with the owed phone checks.

| Step | Observed |
| --- | --- |
| Two `tree` reads | The same 14 handles in both |
| `press --handle <reset button>` | Accepted, `by: handle`; the probe's session changed from `2b29b2dddced17f5` to `8e7c92be603a45a8` |
| `launch --relaunch`, then `press --handle` with the old handle | Refused, `ambiguous-or-missing-target`, `inputSent: none` |
| `wait --handle <new> --until visible`, `wait --handle <old> --until gone` | `condition-met`, `visible` and `absent` |
| `set-value --handle <text field> "handle ok"` | Acknowledged; `probe.text.value` read `"text":"handle ok"` |
| Three `tree` reads timed, with stage timings added for the run and removed after | 2.6 to 3.8 s each: opening (identity query, tunnel, accessibility connection) 0.43 to 0.49 s, the subscription 0.30 to 0.52 s, the snapshot 0.09 to 0.35 s, the unsubscription under 0.01 s, and about 1 to 1.5 s for the rest of the work, the two display queries and the foreground checks; one `devicectl` query 0.2 to 0.25 s |
| `build-run … --configuration Release --build-timeout 900` | Built, installed and launched the probe; one progress line, "build-run: 10 s, 9 steps, now SwiftCompile ProbeApp-dependencies-1.json", which named a dependency file instead of the source (fixed the same day: a source file's name is preferred) |
| `console … -- -probeCrash trap`, then `last-crash --symbols <the build's .dSYM>` | The first read found nothing: the device wrote the report a few seconds later. The second found it (`SIGTRAP`), matched the dSYM's UUID to the `ProbeApp` image, resolved 2 frames, `symbolicated: true`. The report itself already named both frames (a closure and a thunk), since the Release build is not stripped, and `atos` gave no file or line for them (`<compiler-generated>:0`): on this crash `--symbols` added nothing a person could use. A stripped build (an archive) is where it would |
| `settings --voiceover on`, `tree`, `settings --voiceover off`, `tree` | Each answered success; the Home Screen's tree (the probe had crashed) read 166 nodes with VoiceOver on and 158 after. A first switch-on left VoiceOver's "Gestos de VoiceOver" explanation on the screen, dismissed with `press --label Aceptar`, and then its "VoiceOver quiere enviarte notificaciones" permission prompt, answered `press --label "No permitir"` on the human owner's choice; the Home Screen was clean afterwards |

So for durable sessions a kept accessibility session would spare a tree the connection and the subscription, about 0.5 to 0.7 s of 2.6 to 3.8 s, a fifth.

### A Face ID prompt on a simulator

**2026-11-24**, `manzanero-research-phone` (iOS 27.2), the iOS probe with its new [biometric button](probe-app.md#biometric-probe). Face ID was disabled on the simulator at the start (`settings --biometrics state`).

| Step | Observed |
| --- | --- |
| `settings --biometrics on`, then the probe's value | `biometry=faceID`: the app sees Face ID enrolled |
| `press --id probe.biometrics.request` | Accepted; the screenshot showed the probe with no prompt drawn, the tree's foreground process changed, and the probe's value was not readable until it ended |
| `simctl spawn … notifyutil -p com.apple.BiometricKit_Sim.pearl.match`, later `settings --biometrics match` | The probe's value `success` |
| A press and `pearl.nomatch` | The "Face Not Recognized / Try Again" alert with Try Face ID Again and Cancel, drawn in the screenshot. Not in the default tree (SpringBoard's, two labels); in `LocalAuthenticationUIService`'s (`tree --pid`): `com.apple.localauthentication.ax.authentication.alert`, `….button.cancel`, `….button.try-again` |
| `press --id com.apple.localauthentication.ax.authentication.button.cancel --pid <that process>` | Accepted; the probe's value `failed:-2` (user cancel) |
| The same through the tool: press, `settings --biometrics nomatch`, `wait --id ….button.cancel --pid … --until visible`, `press` it | `posted`, `condition-met`, `accepted`; `failed:-2` |
| Press, `settings --biometrics match` | `success` |
| `settings --biometrics match --device <UDID>` | Refused, `unsupported-operation`, nothing contacted |
| `settings --biometrics off` | `enabled: false`, as the simulator was found |

### A protected layer on a simulator

**2026-11-24**, `manzanero-research-tv-4k` (Apple TV 4K (4th generation), tvOS 27.2), the tvOS probe launched with `-ProbeVideoProtected YES` ([protected video](probe-app.md#a-protected-video)): the probe's silent movie in an `AVSampleBufferDisplayLayer` with `preventsCapture` on, read back from the tree as `probe.tv.video.protected` = `preventsCapture`.

| Capture | Observed |
| --- | --- |
| `screenshot` | The protected picture whole (00:00.5 and its bar), with the readouts below it |
| `tree` | `probe.tv.video.time` 12.5, advancing |
| `record` of 3 s, its middle frame read with AVFoundation | The protected picture whole (03:34.8, the readout at 215.0 s) |

So a simulator does not honour `preventsCapture` in its screenshots or its recordings, and a black capture of protected content cannot be produced on one. A simulator plays no FairPlay video either.

### Element handles on a simulator

**2026-11-23**, `manzanero-research-phone` (iOS 27.2), the iOS probe in front.

| Step | Observed |
| --- | --- |
| Two `tree` reads in separate sessions | Every node's `handle` the same in both (14 nodes; the reset button `ax:86455:d5af…`) |
| `press --handle <reset button's handle>` | `status: accepted`, selector `by: handle`; the probe's session changed from `acf05f88288e1c67` to `916a636351de2cea`, as a press of the reset button does |
| `launch --relaunch` of the probe, then `press --handle` with the old handle | Refused before sending (`ambiguous-or-missing-target`, `inputSent: none`, stage `first-snapshot`): the new process has new handles |
| `wait --handle <current handle> --until visible` and `wait --handle <old handle> --until gone` | `condition-met`, reasons `visible` and `absent` |

### Hold on a simulator

**2026-11-23**, `manzanero-research-phone` (iOS 27.2), the iOS touch probe in front, `batch --simulator` with the new simulator stream (`ADCSimulatorPerformLiveDigitizerReports`). The probe's own readouts, read from screenshots, are the ground truth.

| Batch | Observed |
| --- | --- |
| `hold 0.5 0.5`, `tap 0.2 0.3`, `release`, sent at once after a `launch --relaunch` of the probe | Receipt: 7 reports, release confirmed by the barrier. The probe recorded nothing: it was not yet taking touches |
| The same, a minute later | One gesture of two contacts: c0 (0.500, 0.500) for 0.106 s and c1 (0.200, 0.300) for 0.081 s, both ended |
| `hold 0.5 0.6`, `wait --id probe.touch.reset --until visible`, `tap 0.3 0.7`, `release` | The wait failed after 12 s: the simulator returned no accessibility snapshot of the probe. The hold had sent 49 reports (48 refreshes) and was released by the failed step, confirmed; the probe recorded one contact at (0.500, 0.600) for 12.107 s, ended. A plain `tree` with nothing held failed the same way, so the hold was not the cause; VoiceOver had been switched on and off on that simulator earlier the same evening (`settings --voiceover`), and after `simctl shutdown` and `boot` the tree read 14 nodes |
| The same after the restart | The wait was met (`visible`) while the contact was down; the probe recorded one gesture: c0 (0.500, 0.600) for 0.165 s and c1 (0.300, 0.700) for 0.081 s, both ended; release confirmed |

### Seeking in Apple's player on a simulator

**2026-11-23**, `manzanero-research-tv-4k` (tvOS 27.2), the tvOS probe's [silent video](probe-app.md#a-silent-video) in `AVPlayerViewController`. The position was read from the probe's readout, the transport bar's `Media Controls` value and screenshots.

| Step | Observed |
| --- | --- |
| Playing, controls hidden: `tree` | 15 nodes, none labelled but the probe's readout; the player shows in the class names (native attribute 5003): `_AVPlayerViewControllerContainerView`, `_AVFocusContainerView`, `__AVPlayerLayerView` |
| `remote play-pause`, then `tree` | 43 nodes: the transport bar (`AVNowPlayingTransportBar`) with `Media Controls` (value "17 seconds elapsed, 9 minutes, 43 seconds remaining"), `Scrub Needle`, `Elapsed Time Scrubbing Marker`, `AXElapsedTime` `00:17`, `AXRemainingTime` `-09:43`, `Reverse Scanning Speed`, `Forward Scanning Speed`, `AVAudibleSettings` |
| Paused: `remote swipe-right --travel 0.8 --seconds 0.6` | The picture stayed at 00:17.2; the bar's marker moved to 00:42 with a preview thumbnail. `Media Controls` said 42 seconds; the video had not moved |
| `remote select` | Playback resumed at 43.0 s: the select committed the scrub |
| Playing: `remote right --hold 3` | Fast-forward scanning (the ⏩ icon): the picture held at 48.8 while the marker ran on, 1:16 then 1:49; rate 0 |
| `remote play-pause` | Scanning ended and playback resumed at 156.0 s |
| Paused: `set-value --id "Media Controls" 300` | Refused before sending: "target enabled/visible state is unavailable, changed or unsuitable", stage `live-attributes` |

Later the same evening, on the same simulator, the video playing, the position read from the probe's readout before and after each press:

| Step | Observed |
| --- | --- |
| `remote right` | 16.0 s, then 27.0 s about a second later: a skip of 10 s forward |
| `remote left` | 32.0 s, then 23.0 s about two seconds later: a skip of 10 s back |

So a swipe while paused moves only a preview, which a select commits; a held arrow scans until play-pause; and one arrow press while playing skips 10 s, as a press on the second-generation remote's clickpad ring does. An agent that swiped while paused and saw the playhead stay put (2026-11-23, on the Apple TV 4K) may have been seeing the preview before a commit; whether the device behaves the same has not been run.

### The new tools over MCP

**2026-11-16**, a real stdio `manzanero mcp` session fed from a file, against the three simulators at once: `list_displays` (Duo), `press_remote play-pause` (TV probe), `rotate_crown 200` (watch probe) and `screenshot` with `display: LCD` (Duo). All four answered `isError: false`; over six sessions the probes counted every Play/Pause and moved the crown value by exactly 1.0 per call, and the PNG was written. When the first `tools/call` followed `notifications/initialized` with no pause, it sometimes got no response at all (in about half of eight such sessions, each time a `list_displays` call; the same `list_displays` alone also answered in one run and not in another, and two sessions starting with `inspect_device` answered). With a one-second pause after initialization three sessions in a row answered every call. This looked like a startup race in the MCP session, not in these tools; it was one, and is fixed ([MCP calls sent without waiting](#mcp-calls-sent-without-waiting)).

### Apple TV remote touch surface (not built)

Superseded on 2026-11-18: swipes are built on another request of the same daemon ([record](#apple-tv-simulator-power-off-held-keys-searches-in-four-directions-and-swipes), [guide](other-families.md#remote-touch-surface)). What follows is the first pass, as it was.

**2026-11-16**, `manzanero-research-tv`, raw XPC from a scratch copy of the research probe; no product code. `universalhidservice` refused `connect`, `report` and `supportedDevices` as unknown requests. The `universalhid` feature (`LegacyUniversalHIDServer`) answered `supportedDevices` (`appleTVRemote`, `digitizer`, `mouse`, three more) and, from its decoding errors, takes `connect {_0: {vendorID (Int), productID (Int), product, usages [{page, code} (UInt16)]}}` and `report {_0: UInt64, _1: Data}`. A `connect` with usages 12/1 and with 13/5 each activated a virtual service logged as `unknown(0x0)`, but the reply failed with `NSCocoaErrorDomain` 4866 ("in-place encode must encode to a dictionary at the top level") and the service was cancelled when the connection closed. No swipe was delivered; details and what is missing are in [other families](other-families.md#remote-touch-surface).

### Digital Crown and side button

**2026-11-16**, `manzanero-research-watch`. Apps: Watch Settings and a throwaway SwiftUI probe (built for the watchOS 27.2 simulator SDK with `swiftc`, installed with `simctl install`; a `digitalCrownRotation` binding at low sensitivity and a change counter, read through the tree). Raw events were first sent with a copy of the research probe, then through `crown`.

| Experiment | Observed |
| --- | --- |
| Single raw events `y` 10, 100, −100 ×2, 1000, 1, 3, 1.5, 0.5 | Value +0.05, +0.5, −1.0, +5.0, +0.005, +0.015, +0.005, 0: 0.005 per integer unit, fractions dropped |
| Five 20-unit events 16 / 100 / 300 ms apart | +4.835 / +2.636 / +0.500: fast events are accelerated |
| Two 100-unit events 200 and 300 ms apart | +1.0 each time |
| Phase 1, 2, 4 alone (10 units) | +0.05 each; began–changed–changed–ended (30 units) +0.20, twice |
| Momentum 1, 2 (10 units) | +0.05 each |
| Settings list, single events of 100 / 300 / 1000 (after 1.5 s pauses) | One row each (General y 242 → 218 → 158 → 98), back the same way with negative units; 20 and 50 units: nothing |
| Settings, two 100-unit events 250 / 500 / 800 / 1200 ms apart | General y 242 → −22, −22, 158, 158 |
| `crown 200`, `crown 1000 --events 5`, `crown -- -2400` on the probe | +1.000, +5.000, −12.000 |
| `crown 300 --events 3`, `crown 200 --events 2` on Settings (from the top) | General y 242 → 98 (three rows), 242 → 158 (two rows) |
| `button side` on the watch face, twice | Control Center opened (screenshot and tree), then closed |
| `crown 100` on the Apple TV, `button side` on the Duo | Refused before input, `unsupported-operation` |

### Action button and keyboard input on the watch

**2026-11-17**, `manzanero-research-watch` (Series 12, 46mm) and a new `manzanero-research-watch-ultra` (Apple Watch Ultra 4, 49mm), both watchOS 27.2 (24S118), headless; host macOS 27.2.1, Xcode 27.2. Raw events were sent with the research probe first, then through `manzanero`. The text probe was a throwaway SwiftUI app (a `TextField` and a readout of its bound string, built with `swiftc`).

| Experiment or command | Observed |
| --- | --- |
| Raw `IndigoButtonEvent` page 0xFF01, usage 512, down and up, on the Ultra's watch face | The Action button's setup appeared: `Choose Action`, `Choose what you'd like the Action button to do.`, `Cancel` (tree) |
| The same event on the Series 12 | Watch face unchanged (tree) |
| `button action` on the Ultra, from the watch face | `dispatched`, `usagePage` 65281, `usage` 512; the Action button's sheet appeared again (tree: `carousel.actionButtonMiniBuddy.button.cancel`) |
| `button action` on the Duo | Refused before input, `unsupported-operation` |
| Before the refusal: `type ab` with no field open; `press --id probe.text.field` (the text entry sheet opened, screenshot); `type 'Hola 12'`, `key backspace`, `key return` | Each `dispatched`; the sheet's field stayed empty and the sheet stayed open (screenshots) |
| `set-value --id probe.text.field 'Hola ñ'` with the sheet closed | `acknowledged`; the field showed and reported `Hola ñ`, the readout of the bound string stayed `value:` (tree and screenshot) |
| After the change: `key return`, `type ab` on the Series 12 | Refused, `unsupported-operation`, `inputSent: none` |

Not checked: a physical watch, what the Action button does once an action is chosen, and `set-value` in a UIKit or WatchKit field.

### Fold (iPhone Duo)

**2026-11-16**, `manzanero-research-duo-fold` (iPhone Duo, iOS 27.2, 24B91016s), booted headless with `simctl boot`; host macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreDevice 651.32. Commands in [other families](other-families.md#fold-iphone-duo).

| Command | Observed |
| --- | --- |
| `fold` (from 180) | Exit 0 in 4.9 s: `displayObserved: true` after 11 display reads, `activeDisplay` LCD. The first version's 5 s bound was close to that, so it became 10 s / 40 reads |
| `unfold` (from 0) | Exit 0 in 1.7 s: observed after 3 reads, `activeDisplay` LCD-1; `displays` then showed LCD `off`, LCD-1 `activeOn` |
| `hinge 90` (from 180) | Exit 0, `activeDisplay` null right after sending (both or neither awake at that instant); 2 s later LCD-1 still `activeOn`, LCD `off`, as in the research |
| `hinge 110` (from 0) | Exit 0; 3 s later LCD-1 `activeOn`, LCD `off`: one step to 110 unfolds, as in the research |
| `fold`, SIGINT after 1.2 s (in the wait) | Exit 130 with the input-interruption diagnostic; the process was gone at once. The event had been sent: `displays` then showed LCD `activeOn`, LCD-1 `off` |
| `fold`, `hinge 45` on `iPhone 17e` (iOS 27.2) | Exit 1, `unsupported-operation`, `inputSent: none`: "lists 1 integrated display(s) with a framebuffer" |
| `unfold --device` (placeholder identifier) | Refused while parsing, `unsupported-operation`; no device contacted |
| MCP `fold_device unfold`, `set_hinge_angle 90`, `fold_device fold`, sent together in one stdio session without waiting for answers | All `isError: false`, but the simulator ended at 90 degrees: the server ran the calls out of order, and the first version's wait (`Task.sleep`) let another call run during it. The wait now blocks the command service's thread, as timed input does |
| `hinge` (read) folded, unfolded, after `hinge 90`, after `hinge 120` | `angle` 0, 180, 94.62 (`mechanicalAngle` 90), 113.84 (`mechanicalAngle` 120); `isAngleValid` true, `velocity` 0; `activeDisplay` LCD, LCD-1, LCD-1, and null right after sending 120, LCD-1 1 s later. About 0.7 s per read; five reads in a row all answered |
| MCP `fold_device unfold`, `get_hinge_angle`, `set_hinge_angle 90`, `fold_device fold`, `get_hinge_angle`, pipelined in one session (`set_hinge_angle` answered first) | All `isError: false`; answered in the order 90 (displayObserved false), angle 91.54 (still moving), unfold (observed), angle 180, fold (observed): each call ran whole, but pipelined calls still ran in no fixed order. The server now runs a device's mutations in arrival order ([MCP calls sent without waiting](#mcp-calls-sent-without-waiting)); repeated on the Duo on 2026-11-17 ([below](#the-duos-inner-display)) |
| `displays` and `hinge` (read) after `unfold`, `hinge 90` (from 180, then from 0), `fold`; `displays` on `iPhone 17e` | `hinge.angle` 180 `flat`; angle 85.38 `partially-open` (approached from 0; from 180 it had read 94.62); 0 `closed`. The 17e listing has no `hinge` key. MCP `list_displays` on the folded Duo: `isError: false`, angle 0, `closed` |

### The Duo's inner display

**2026-11-16**, `manzanero-research-duo-fold` unfolded with `unfold`, same versions as above. Apps: the [probe app](probe-app.md) (an existing simulator build, installed with `simctl install`, launched with `-ProbeAllowRotation YES`; its view reported 951 × 669) and Settings. Touches were read back from the probe's `probe.touch.*` readouts through `tree`. A scratch copy of the research probe (`tmp/duo-fold-build/`, untracked) sent the raw experiments; everything else ran through `manzanero`.

| Experiment or command | Observed |
| --- | --- |
| Raw Indigo tap on `hid.digitizer` at portrait-native (0.75, 0.75), payload `target` 0, 1, 2, 3, 4, 5 | Probe: `began 0` after each; nothing reached LCD-1 |
| `connectedServices` on `universalhidservice` | Three touchscreens, `CoreDevice touchscreen(<uniqueId>)` of LCD, LCD-1 and Resizable, plus keyboard, buttons, `touchscreenGesture` and `avpCustom` |
| Raw Universal HID tap on LCD-1's touchscreen at (0.75, 0.75); then three contacts | Probe: one contact at (0.250, 0.750), so interface (x, y) = touchscreen (y, 1 − x); then `max 3` |
| `tree` before the change | Worked (frontmost answered: the probe), but with the outer display's 466 × 678 geometry |
| `press --label "Reset probe"` with `displayId` 0, 1, 2 or 3, mapped or unmapped point | Error 8 for all but `displayId` 3 with the point mapped to LCD-1's native portrait points (563, 475.5): `accepted` |
| `displays`, `screenshot`, `screen`, `record 2` (no `--display`) | `interfaceDisplay` 3; a 2853 × 2007 PNG; `screen` by accessibility with display LCD-1; video 2852 × 2006 of LCD-1. `screen tree --display LCD` refused before capture |
| `tree` | `screen`: 669 × 951 native, interface 951 × 669, `rot90`, display LCD-1; frames match the screenshot (Reset at 385.5, 537) |
| `tap 0.25 0.75`, `long-press 0.6 0.4 1.5`, `swipe 0.2 0.5 0.8 0.5 0.4`, `drag 0.3 0.3 0.6 0.6 0.5` | `route: universal-hid`; probe: (0.2499, 0.7499); held 1.502 s at (0.6001, 0.4001); 0.2001 → 0.7999 in 0.401 s; (0.300, 0.300) → (0.600, 0.600) |
| `pinch 0.5 0.5 0.2 0.5 0.5`, `multi-drag 0.5` two paths, `multi-tap` with 3 and 5 points | Two contacts 0.400/0.600 → 0.250/0.750; both paths as sent; `max 3` and `max 5` at the requested points (error under 0.0005) |
| `press --label "Reset probe"`, `wait --id probe.touch.reset --until visible`, `set-value --id probe.text.field "Pliegue ñ"`, `tap` on the field, `type " abc"` | Probe session reset; `condition-met`; `acknowledged`; the text probe read `Pliegue ñ abc` |
| Settings: `tree`, `press --label General`, `press --id com.apple.settings.general`, `scroll --id com.apple.settings.standBy` | Right after `simctl launch`, the frontmost request still named the probe for a few seconds (Settings blank); then the two-column Settings tree. `--label General` refused as ambiguous (several matches); `--id` opened General's detail; scroll `postcondition-verified` |
| `button home`, then `tree` | Failed: no snapshot data at full depth or depth 10, as on the folded Duo |
| Folded again: `displays`, `tap 0.25 0.75`, `multi-tap` 3, `tree`, `press`, `screenshot` | `interfaceDisplay` 1; Indigo route (no `route` key), (0.2504, 0.7503); `max 3`; 466 × 678 `rot0` without a `display` object; `accepted`; 1398 px wide |
| `iPhone 17e` (iOS 27.2, single display): `displays`, `tap`, `multi-tap` 3, `press`, `tree`, `screenshot` | `interfaceDisplay` 1; Indigo route, (0.300, 0.600); `max 3`; `accepted`; 390 × 844; `simctl io … screenshot` without `--display`, as before |
| MCP, one call every 4 s: `list_displays`, `tap`, `get_ui_tree`, `screenshot` (no display) | All `isError: false`; `interfaceDisplay` 3, `route: universal-hid`, the probe recorded (0.3999, 0.5999), a 2853-px PNG |

**2026-11-17**, the same simulator, unfolded, three other simulators booted on the Mac; the probe launched with `-ProbeAllowRotation YES`.

| Experiment or command | Observed |
| --- | --- |
| `mise run test:probe-touch <UUID> --platform simulator --any-orientation`, the built-in plan once | 14 of 14 actions and 29 of 29 contacts `delivered`, all through the recent-gestures readout; start error median 0.0002, max 0.0003; hold error median +1.4 ms, max +3.0 ms; `maxActive` 1, 2, 3, 4 and 5 as scheduled. This includes the two `gesture` sequences and the three-path `multi-drag`, which had not run on `LCD-1`. Identity matched on all 15 readbacks |
| MCP `fold_device fold`, `get_hinge_angle`, `set_hinge_angle 90`, `get_hinge_angle`, `fold_device unfold`, `get_hinge_angle`, written at once in one stdio session, five sessions | Every call `isError: false` and answered in the order sent, in all five. The reads gave 0 (`closed`), 84.69 to 85.38 (`mechanicalAngle` 90, `partially-open`) and 180 (`flat`) each time, so each observation saw the state after the mutation before it. `fold` was observed after 16 to 18 display reads in four sessions; in one it was not observed in 35 reads (10 s) although the angle then read 0. `unfold` was observed after 2 to 7 reads |
| `button home`, then `tree`, with the snapshot retry depth changed to 8, 6, 4 and 2 in a scratch build | No snapshot data each time. The frontmost process is SpringBoard |
| The same with the foreground taken from a hit test at the centre, on the Settings icon and in the dock (client type 0 and 2) | SpringBoard again, no snapshot data. A hit on the Maps widget answered `WidgetRenderer_Default` and its tree (34 labels) |
| Settings in two columns, `press --label General` after the ambiguity message was extended | Refused, `ambiguous-or-missing-target`, `inputSent: none`, listing 5 elements: two hidden title texts at 572,38, the row `identifier 'com.apple.settings.general'` visible at 20,254 280x52, its hidden text, and a visible element without identifier at 360,177 80x26 |

Folding took longer here than the 11 reads recorded above, once longer than the 10 s bound; whether the landscape probe in front or the load on the Mac caused that was not separated.

**2026-11-17, 23:30**, the same simulator with two other simulators booted on the Mac (the owner's, left alone), and the probe launched without `-ProbeAllowRotation`, so it stays in portrait.

| Experiment or command | Observed |
| --- | --- |
| `unfold` then `fold`, five times | All ten reported `displayObserved: true` within the 10 s bound. Not the "nothing else booted" condition, but one simulator fewer than when a fold was missed |
| Unfolded, `screenshot` and `tree` | The portrait probe is letterboxed: a 469 × 669-point window centred on the 951 × 669 inner display, black on both sides. The tree's frames are relative to that window (root 0,0 469 × 669) |
| `press --id probe.touch.reset` there | Refused before anything was sent, at the target hit: "semantic refusal or notification in request response (error 8)". The hit test is asked at window-relative coordinates on the display. Launched with `-ProbeAllowRotation YES` the probe fills the display and the same press was accepted (above) |
| `multi-drag 0.6` with four paths at x 0.2, 0.4, 0.6, 0.8 and five at x 0.15, 0.3, 0.5, 0.7, 0.85 | The probe received only the contacts inside its window (2 of 4, 3 of 5), at window positions that match a linear mapping of the display's x from about 0.253 to 0.747 |
| The same with every path inside the window: four at x 0.32 to 0.68, five at x 0.30 to 0.70 | 4 of 4 and 5 of 5 contacts, `maxActive` 4 and 5, each starting at y 0.29995 and at the expected window x (0.135 to 0.865; 0.095 to 0.905) |

So four- and five-path `multi-drag` reach the inner display. New and open: for an app letterboxed on the inner display, selector actions fail at the hit test and normalized touch coordinates are the display's, not the app window's.

**2026-11-18**, `manzanero-research-duo-fold` just booted, with one other simulator running on the Mac (an iPhone 18 Pro that is not this project's): five rounds of `fold` then `unfold`. The first `fold`, seconds after boot, was not observed (`displayObserved: false` after all 40 reads); the other four were, after 12 to 16 reads, and all five unfolds after 1 to 10 reads.

## Retired implementations

These results are preserved as history, not current runtime availability:

| Former route | Historical evidence | Current implication |
| --- | --- | --- |
| AXe simulator adapter | SpringBoard tree → Settings label tap → Settings tree succeeded | Executable blocked; direct simulator input/AX replacement pending. Later: replaced ([simulator input](#simulator-input-and-accessibility)) |
| idevice HID | Early phone unavailable through usbmuxd; later read-only HID discovery passed; Home/tap receipts lacked visible effect | Cause unresolved; not proof of current native input |
| idevice independent pairing | Protocol/build/validation existed | Live initial pairing/reconnection/input unverified; executable route blocked |
| idevice AX | Raw callback/offline decoding, Settings trees and selector navigation passed | Separate from unsuccessful idevice HID; replaced by native AX route |
| ipb native input/video helpers | Scoped input effects and short movies; video cleanup/sharing uncertainty | Helpers blocked; old tests do not validate current direct code |
| Finite OS trace bridge | Parser/duration/entry/byte-limit code tested | Live trace and remote cleanup unverified; route blocked |

The current policy is project-owned Apple API/framework calls or Apple executables. See [dependencies/provenance](dependencies.md); no commercial binary is a runtime dependency.

## Distribution and privacy checkpoints

### Release rehearsal

**2026-11-18**, version 0.1.0-beta.1 as in `Version.swift`. Nothing was published and no tag exists.

| Step | Observed |
| --- | --- |
| On the Mac: `mise run package`, `mise run test:package`, `mise run release:formula kikeenrique/manzanero` | All passed: two byte-identical universal archives, ad hoc signed and not notarized; extraction, signatures, architectures, notices, symlink and CLI smoke; a formula with matching checksums, syntax OK; linkage to system libraries only |
| The owner pushed `main`; the ordinary CI run | Passed: build and 702 tests |
| The owner ran `gh workflow run release.yml --ref main` (run 44206257584) | `package` succeeded in 7 min 37 s (two release builds, 702 tests, packaging) and uploaded `beta-dist`; `publish` was skipped, as a manual run should. The workflow's first pass: its one earlier run had failed |
| The artifact, downloaded | `SHA256SUMS` and the formula agree, and the archive's own SHA-256 matches. Unpacked, the binary reports `manzanero 0.1.0-beta.1`, holds `x86_64` and `arm64`, is ad hoc signed, and has the commands of that commit |

The checksums of the CI archives differ from the Mac's local ones, as expected of separate builds; a published release takes CI's.

### First beta published

**2026-11-18, 00:49 UTC.** After the [audit and the small history rewrite](public-readiness.md#audit-before-the-first-release-2026-11-18), the owner force-pushed `main`, CI passed on it (702 tests), and the owner ran `mise run release v0.1.0-beta.1` from his own terminal. A first attempt from inside an agent session created the local tag and failed at the push, because that shell has no access to the SSH key; the repeat reused the tag.

| Step | Observed |
| --- | --- |
| The tag's workflow run (44209986413) | `package` and `publish` both succeeded |
| The release | `v0.1.0-beta.1`, a prerelease, not a draft, with four assets: the two archives (6,901,207 bytes each), `SHA256SUMS` and `manzanero.rb` |
| The assets, downloaded | Both archives have the SHA-256 that `SHA256SUMS` and the formula give; unpacked, the binary reports `manzanero 0.1.0-beta.1` and holds `x86_64` and `arm64` |

The formula attached to this release fails `brew style` as shipped, with 5 `FormulaAudit/ComponentsOrder` offenses found when it was added to the tap: `url` and `sha256` inside a top-level `on_arm`/`on_intel`, and `depends_on` after them. The tap's copy wraps the two blocks in `on_macos` and puts `depends_on` first, with URLs and checksums unchanged. `release:formula` now generates that shape for later releases; `brew style` would not inspect the generated file outside a tap, so the new shape is checked only by `ruby -c` here and by the tap's own run on the same layout. Later: the generator's shape changed again to Apple silicon only, and that one passed `brew style` in the tap ([record](#the-taps-formula-apple-silicon-only)). The asset on the published release stays as it is, since releases are immutable.

### Second beta published

**2026-11-21, 00:22 UTC.** The human owner pushed `main`, CI passed on it, two manual runs of the release workflow built the archive without publishing (the first with 30 warnings from a Swift file prefix map, dropped before the second, which had none), and the human owner pushed the tag `v0.1.0-beta.2` from a terminal.

| Step | Observed |
| --- | --- |
| The tag's workflow run (44842753884) | Built, 805 tests passed, packaged and published |
| The release | `v0.1.0-beta.2`, a prerelease, not a draft, with three assets: one Apple silicon archive (3,675,533 bytes), `SHA256SUMS` and `manzanero.rb` |
| The assets, downloaded | The archive has the SHA-256 that `SHA256SUMS` and the formula give; unpacked, the binary reports `manzanero 0.1.0-beta.2`, holds `arm64` only with a deployment target of macOS 26.6, passes `codesign --verify --strict`, and carries no `/Users/` path |
| The formula | `url` for this tag's archive, `version "0.1.0-beta.2"`, `depends_on arch: :arm64`, `macos: :tahoe` and `xcode: ["27.0", :run]` |

The tap, the same night, done by the tap's own session and the human owner:

| Step | Observed |
| --- | --- |
| The formula in `kikeenrique/homebrew-tap` | Copied from the release unchanged: four lines differ from beta.1's (the URL's tag, `version`, `sha256`, the version in the test). `ruby -c` and `brew style` clean; committed as "Update manzanero to 0.1.0-beta.2" and pushed by the human owner |
| `brew update`, `brew upgrade kikeenrique/tap/manzanero` | Homebrew's clone of the tap at that commit; the Cellar holds only 0.1.0-beta.2, and the install receipt names that tap commit |
| `brew audit --strict --online kikeenrique/tap/manzanero` | No findings |
| `brew test`, and `manzanero --version` through the `bin` link | Both pass; `manzanero 0.1.0-beta.2` |
| The installed binary | Thin arm64, ad hoc signed, no team identifier; `com.apple.provenance` and no `com.apple.quarantine`. It ran at once, with no Gatekeeper block, as beta.1 did |

### Signing and notarization trial

2026-11-23, on the development Mac (macOS 27.2.1, Xcode 27.2), with `mise run package` and then `mise run release:notarize v0.1.0-beta.2 --local --no-publish` ([notarization](releasing.md#notarization)); no release was changed.

- **Identity.** The keychain held two Developer ID Application certificates of one name and team (one from 2025, one issued that day); `codesign` refuses the name then, so the task takes the certificate's SHA-1 hash, set in `.env.local`. Signed with the newer one.
- **Signing.** The executable with the hardened runtime and a secure timestamp, the bundled Swift runtimes with a timestamp; `codesign --verify --strict` passed, and the executable's `Authority` is the Developer ID.
- **Notarization.** `notarytool submit --wait` through the keychain profile: `Accepted`, no issues in Apple's log, twice (the second run after the fix below).
- **Gatekeeper.** `syspolicy_check distribution` failed the first run with "Notary Ticket Missing": it demands a stapled ticket, which a bare executable cannot hold. `spctl --assess --type install` reported "Unnotarized Developer ID" for about five minutes after acceptance, then "Notarized Developer ID". The task now waits for that assessment, at most 15 minutes, instead of the staple check; on the second run it passed.
- **The archive.** Packed again, `test:package` passed on it (extraction, signatures, architecture, notices, the CLI through a Homebrew-style link).
- **The hardened runtime on devices**, with the signed binary from that archive: `doctor` listed every private interface available, as the unsigned debug build does; its one difference was the firewall entry, `no-rule` for the new executable's path. On `manzanero-research-phone` a `tap` reached the probe and `tree` read it. On the iPhone 13 mini, on its cable: `readiness`, `press --id probe.touch.reset` over the tool's own tunnel (`ownTunnelLink: cable`), a `tap` the probe counted, a `tree`, and a 5-second `record --backend coredevice` (94 H.264 frames) although the firewall had no rule for that path. No entitlement was needed.

### An install on a second Mac

2026-11-23, reported by the human owner: the tool was installed on a Mac other than the development one and works there. The beta's version, the install route and that Mac's macOS and Xcode versions were not recorded, nor which commands ran.

### Homebrew install from the tap

**2026-11-18, morning**, on the development Mac (Apple silicon, Homebrew 7.0.x), reported by the session working in the tap repository; the owner ran the install himself.

| Step | Observed |
| --- | --- |
| The formula in `kikeenrique/homebrew-tap`, in the adapted layout | `brew style`: no offenses. `brew audit --strict --online kikeenrique/tap/manzanero`: no findings |
| `brew install kikeenrique/tap/manzanero` | Succeeded: 27 files, 25.1 MB, the caveats shown |
| `brew test manzanero` | Passed |
| Through the installed `bin` symlink: `manzanero --version`, `manzanero --help` | `manzanero 0.1.0-beta.1`; the full command list. Exit 0 both |
| Gatekeeper | The binary ran at once, with no dialog. `com.apple.quarantine` is set nowhere in the installed files or on Homebrew's cached archive (only `com.apple.provenance`). `codesign -dv`: universal, `Signature=adhoc`, no team identifier. `spctl -a -t execute`: rejected, as expected of ad hoc, unnotarized code |

So a Homebrew install runs straight away, because Homebrew's download carries no quarantine and Gatekeeper then does not assess the binary at launch. An archive downloaded by hand in a browser would be quarantined, and `spctl` says it would be rejected; that path has not been tried. One Mac, the one that built nothing of this release but has Xcode and every development tool installed; a tester's clean Mac has not been tried.

### Apple silicon only, Xcode 27 and macOS 26.6

**2026-11-18.** The owner pointed out that the tool needs Xcode 27 or later, that Xcode 27 has no Intel build and that it needs macOS 26.6 or later, so v0.1.0-beta.1's x86_64 slice, its `on_intel` formula block and the "macOS 15+" in the manifest and guides described Macs the tool could never work on. On this Mac the selected Xcode 27.2's own executable holds `arm64` only. Changed for the next beta, and checked locally:

| Change | Observed |
| --- | --- |
| `Package.swift` deployment target 26.6, with the two `macOS 26` availability guards and the attributes removed | Build with no warnings; all tests pass; the debug executable's `LC_BUILD_VERSION` says `minos 26.6` |
| `doctor` gains a `Requirements` entry (Xcode 27, macOS 26.6, arm64) | `available` on this Mac; unit tests cover an older Xcode and macOS 26.5 (`unavailable`, exit 1) and an unreadable Xcode version (`unknown`) |
| `mise run package`, `test:package`, `release:formula` | One archive, `manzanero-aarch64-apple-darwin.tar.gz`; the executable is `arm64` only with `minos 26.6`; `SHA256SUMS` lists that one file; the formula has a single `url`, `depends_on arch: :arm64`, `macos: :tahoe` and `xcode: ["27.0", :run]`, `ruby -c` OK |

Not run: the hosted workflow with these changes (its runner is macOS 27.0.1 with Xcode 27.2, above the floor). `brew style` on the new formula shape ran later that day, below.

### The tap's formula, Apple silicon only

**2026-11-18**, on the development Mac (Apple silicon, macOS 27.2.1, Xcode 27.2), reported by the session working in the tap repository; the owner pushed the tap and ran the reinstall.

The tap's formula for v0.1.0-beta.1 was replaced with the shape the generator now emits, pointing at the archive already published: one `url` and `sha256`, `depends_on arch: :arm64`, `depends_on macos: :tahoe`, `depends_on xcode: ["27.0", :run]`, and the caveat naming Xcode 27 and macOS 26.6.

| Step | Observed |
| --- | --- |
| `brew style` | "1 file inspected, no offenses detected". The explicit `version` beside the `url` is not flagged |
| `brew audit --strict --online kikeenrique/tap/manzanero` | No findings |
| `brew reinstall kikeenrique/tap/manzanero` | Used the new formula (the install receipt names the new tap commit, and the installed copy of the formula has the new caveat). `brew upgrade` did nothing, the version being the same |
| `brew info` | "Required: arm64 architecture, macOS >= 26, Xcode >= 27.0", all three accepted on this Mac |
| `brew test`, `manzanero --version` | Passed; `manzanero 0.1.0-beta.1` |
| Quarantine | Still none on the binary |

So the generated formula can go into the tap unchanged. What the formula cannot say is 26.6: Homebrew compares macOS by major version, and the published beta.1 binary, built before the change, neither refuses to load on 26.0 to 26.5 nor has the `doctor` requirement. Not tried: Homebrew refusing the install on an Intel Mac, on macOS 15 or with an older Xcode.

### Earlier checkpoints

The four paragraphs below predate the sections above and are kept as written. Later: hosted CI and the release workflow have run, v0.1.0-beta.1 is published and installed through Homebrew, the archive is Apple silicon only from the next beta, the server lists 46 tools, and a second scan covered the history as it is now ([public readiness](public-readiness.md#audit-before-the-first-release-2026-11-18)).

The Manzanero rename passed all 314 local Swift tests with no build errors or warnings. Native multitouch and timed-gesture sender tests also passed without a device. All 48 mise tasks validated, and 41 documented command forms passed dry-run checks. The renamed stdio MCP server identified itself as `manzanero`, listed 33 tools and exited successfully on EOF without running device operations.

Both architecture builds and the universal `manzanero` beta archives passed packaging checks. Extraction into a Homebrew-style layout verified signatures, architectures, notices, symlink execution, version/help and a dry-run command. The `manzanero.rb` formula generated with valid Ruby syntax using a placeholder `example/manzanero` repository; that is a local generation check, not a real release URL or public Homebrew installation. Test environment variables now use the `MANZANERO_` prefix. No live-device verification was repeated for this rename.

`8681d00` added local universal beta archives, checksum/formula generation and the tag/manual workflow. Both architectures built, native version/help ran, signatures/linkage and Homebrew-style extraction/symlink smoke passed. The optimized archive was about 4.1 MiB and needed no supplemental Swift compatibility library. The project now uses MIT, and its public source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero). GitHub Actions, actual beta release and public Homebrew install have not run.

The earlier source/history privacy review used Gitleaks 8.30.1 against the pre-cleanup snapshot and its 88 reachable commits and found no detected leaks. Those scan results apply to the original history, not the rewritten trees. The later publication cleanup preserved author identities, removed personal paths and private investigation material, and verified those specific removals throughout reachable history. No additional secrets scan was requested. See [public readiness](public-readiness.md).

## What these records do not establish

No result here completes all Apple-family coverage or reliable unattended testing. Important gaps include cross-process ownership, uncertain-release quarantine, crash/cable-loss recovery, broad app/overlay/orientation behavior, simulator input migration and dedicated iPad/Watch/TV/Duo validation. Later: the device lease and the simulator route now exist and have scoped live checks; quarantine after an uncertain release exists on the Mac and has run on one simulator and, for a killed touch, on the phone; iPad, Watch, TV and Duo have simulator results only. Native recording ran three times and `frames` once on the phone after the bridge's decoded-JPEG mode was removed on 2026-11-17. Web pages are read in Chrome only, a phone in landscape is not read at all, and human handoff has run with one person, one phone and one MCP host. The first beta is published and has been installed on one Mac, the one it was developed on. The [roadmap](roadmap.md#pending) lists what remains.

When repeating a check, record the current versions/target/backend, separate transport acceptance from visible effect and cleanup, and retain failures rather than automatically retrying an input action.
