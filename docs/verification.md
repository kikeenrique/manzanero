# Verification record

This is the evidence summary for the current implementation and the material failures that shaped it. It is organized by capability so readers do not have to reconstruct the latest state from an append-only development log.

**Commands recorded before 2026-11-16 use the earlier grammar**, with the platform and device first (`physical <UDID> tap 0.5 0.5`, `simulator <UUID> press-id <id>`). From that date the CLI names the operation first and the target as an option (`tap 0.5 0.5 --device <UDID>`, `press --id <id> --simulator <UUID>`); see the [argument parser proposal](cli-argument-parser-proposal.md). The records below are kept as they were run.

**A build, fixture or dispatch receipt is not a hardware assertion.** Each result below applies to its stated backend/device/environment. Retired helper results are labeled separately. [Feature status](feature-status.md) describes current availability, the [roadmap](roadmap.md) summarises what is achieved and pending, the [live check plan](live-check-plan.md) lists the hardware runs still owed, and [development tasks](development-tasks.md) explains repeatable checks.

**Entries are not rewritten.** A few undated summary paragraphs were written before later dated sections; where they differ, the dated section is the later record, and a "Later:" note points to it.

Where to find the physical results: [discovery and readiness](#discovery-and-readiness) through [app console and last crash](#app-console-and-last-crash-on-the-phone) and the runs of 2026-11-17 and 2026-11-18, the newest on the phone: [the log relay](#the-log-relay-on-the-phone), the [morning session](#phone-session-of-2026-11-17), [web content](#web-content-on-the-phone), [a passcode, pairing and the lock screen](#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen), and human handoff [with a physical step](#handoff-with-a-physical-step), [with a permission prompt](#handoff-with-an-app-permission-prompt), [through an MCP host](#handoff-through-an-mcp-host-the-pause-and-the-form) [watching the device](#handoff-that-watches-the-device), its [timeout and simulator runs](#handoff-watch-a-timeout-on-the-phone-and-runs-on-a-simulator) and [the last runs with the owner](#the-last-handoff-runs-on-the-phone), the [selector, layout and screenshot changes](#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note) and [the offer that asked for RTCP feedback](#an-offer-that-asks-for-rtcp-feedback); then [direct physical input](#direct-physical-input), [physical accessibility](#physical-accessibility-and-screen-understanding), [native media](#native-media-and-recording) and [frames](#frames-on-the-phone). Simulator results: [simulator input](#simulator-input-and-accessibility), [keyboard layouts](#keyboard-layouts-on-the-simulator), [layout detection](#layout-detection), [app logs](#app-logs-console-and-crashes) and [other simulator families](#other-simulator-families). MCP ordering: [calls sent without waiting](#mcp-calls-sent-without-waiting). Distribution: the [release rehearsal](#release-rehearsal), the [first beta](#first-beta-published), its [Homebrew install](#homebrew-install-from-the-tap) and the [Apple silicon requirement](#apple-silicon-only-xcode-27-and-macos-266).

## Environment and evidence handling

The latest physical checks used the designated iPhone 13 mini, iOS 27.2.1 (24B156), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2 and CoreDevice 651.32. Media work observed AVConference 2260.15.1. Some earlier input records used iOS 27.2 (24B119); results from one checkpoint do not establish all OS versions.

The phone had Developer Mode and Enable UI Automation enabled for the successful UI checks. It had no passcode until the evening of 2026-11-17, when the owner set one for testing; records before that describe a phone without one. Its default browser was Chrome until the same evening and is Safari since. Later checks found its display off. User preparation is not continuous proof that the device remains awake/unlocked.

Raw screenshots, movies, app/process inventories, addresses, device IDs, archives and stderr remain under ignored `tmp/`. They are not public fixtures. The Git commits named below retain the detailed implementation checkpoints; temporary artifact UUID lists and intermediate test counts are omitted here.

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

### Phone session of 2026-11-17

**2026-11-17, at `01988bf`**, the same iPhone 13 mini (unlocked, portrait, reached over `apple-network-rsd`), macOS 27.2.1, Xcode 27.2 (27B52), `devicectl` 651.32. Evidence is under `tmp/session-1117/` (not tracked).

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

Unit tests only, not run on a device: the masked read-back of a secure field (`valueMatches: null`, `readBack: masked`), `press` on an element that reaches past the display's edge with its centre on it, a selector action with the PID of the process hosting the display-centre one, and the categories of errors that are not this tool's own.

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

On 2026-11-18, one Apple TV 4K (3rd generation, `AppleTV14,1`), paired over the network and asleep at the start, with the build from `main`, macOS 27.2.1, Xcode 27.2 (27B52), `devicectl` 651.32. The tvOS version was not recorded. Only commands meant to observe were run; no input was sent. Evidence is under `tmp/appletv-4k3/`.

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

Later, with the external display let through for capture once: `frames --count 3` saved three images (first frame after 6.4 s) and `record --backend coredevice` a 5-second H.264 movie, each 3168 × 1792 and each a black rectangle on grey, while `screen ocr` read the Home Screen. Both commands refuse an Apple TV since. The [tvOS probe](probe-app.md#tvos-probe) was written and run on a simulator the same day; it is not on the device.

In the afternoon the owner ran the tvOS probe onto the device from Xcode. Six seconds after that run's connection was released (14:05:25), `remotepairingd`'s heartbeat to the Apple TV began to fail at once (`failed after 0ms`) and every query timed out, for twenty minutes, while the network tunnel still carried packets and the Mac listed the device as connected; evidence is under `tmp/device-services/`. With the owner's word both services were restarted and the first query answered. Then, against the probe:

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

The connection went stale twice more: at 15:14:06, as a `tree` started with Control Centre open, and at 16:17:39, as a `tree` started on the sleeping device. Each time `remoted` logged "Device connection interrupted" with no "Handshake complete" after it, then "Heartbeat failed: not connected" every 30 seconds. The same interruption, followed by a handshake, was logged for the iPhone 13 mini during two of five `tree` runs, one of them with a random peer identity in manzanero's directory handshake (a scratch change, not kept), and in the second before one of them only `devicectl` had been active. Logs are under `tmp/appletv-4k3/power/` and `tmp/device-services/`.

On the tvOS 27.2 simulator the same afternoon, with a forty-row list added to the probe: the tree held rows 1 to 13; `scroll --id probe.tv.row.13` returned `nativeResult: true`, the row moved from y 1020 to 954 and row 14 joined the tree, but the status was `postcondition-failed` ("target centre hit is another native element"), five checks 250 ms apart included. The element that answered the hit test belonged to `PineBoard`, not to the probe. With the hit test left out on an Apple TV, rows 18, 19 and 20 each scrolled into view as `postcondition-verified`, and `press --id probe.tv.row.20` was recorded as `select:row-20`. `button lock` on the simulator did not open Control Centre, so the power sequence is a hardware matter.

`scroll --search`, built that evening, on the same simulator with the probe relaunched and its list at the top (rows 1 to 13 in the tree): `scroll --id probe.tv.row.35` alone failed with no match; with `--search 40` it took 22 steps in about 8 seconds and ended `postcondition-verified` with row 35 at y 954, and `press --id probe.tv.row.35` was recorded as `select:row-35`. `scroll --id probe.tv.row.99 --search 60` stopped after 30 steps with "the list stopped moving". Two faults were found and fixed on the way: with a 40-step limit the first version reached only row 17, because every few steps the lowest element was the list's own container, 3200 points tall, and scrolling to it put the list back at the top; and a search started straight after launch found no rows, because the list was not in the tree yet (`wait --id probe.tv.row.1` first).

More simulator runs that evening, against the probe. On the 1080p simulator, after the hit test was left out: `set-value --id probe.tv.text.field 'héllo sim'` was `acknowledged` with `valueMatches: true` and the app's bound text agreed, but it left tvOS's full-screen keyboard in front, so `wait` answered `not-visible` and `press` was refused until `remote menu` closed it; then `type ' abc'`, `wait --until value`, `wait --until focused` (correctly `not-focused` for an element without focus), `press --id probe.tv.button.c` (recorded `select:c`), `screen` (method `accessibility`) and a 3-second `record` all worked. A real stdio MCP session answered `press_remote` twice, once without `platform` and once with `platform: simulator`, and `scroll_to_element` with `search: 20` (7 steps, `postcondition-verified`); the probe recorded `select:b`. Calls written to the server just before its input closed got no answer: only `initialize` did.

A new simulator, `manzanero-research-tv-4k` (`Apple TV 4K (3rd generation)`, tvOS 27.2), reported its display as the device had: `TVOut`, external, 3840 × 2160 pixels, point scale 1, with a tree 1920 × 1080 points. `displays` listed 3840 × 2160 points there, now corrected to 1920 × 1080 at scale 2. On it `press`, `scroll --search 30` (17 steps to row 30), `press` on that row (recorded `select:row-30`) and `remote` worked. `handoff --until focused --id probe.tv.button.b` ended as `observed` 5 seconds in, when a second process sent `remote right`; with the condition already true it returned at once, and with a 4-second limit and no change it ended `timedOut` with exit 1.

A held remote button, on the 1080p simulator: with the hold raised to 1.5 s in a scratch build, `home` opened Control Centre (OCR read Power Off, Audio, Ethernet, Do Not Disturb, Sleep Timer), while `menu` and `play-pause` held as long showed Settings unchanged. Built as `remote --hold`: `remote home --hold 1.5` returned `holdMilliseconds: 1500` and opened Control Centre again; the tree then gave `PineBoard` with 24 nodes and no item; `remote menu` closed it. `--hold` on `select`, a hold of 9 seconds, and a hold with `--device` were each refused before anything was sent.

Not shown: a scroll that moves a list on the physical device, which command wakes the device, whether the television also switches off with it, and the Mac's second Apple TV.

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

**Probe trigger.** A `manzanero-probe://` URL opened with `open-url` showed "Open in “Probe”?" and needed a touch, so the trigger became the accessibility element `probe.log.emit`, which `press-id` activated (`status: accepted`).

Not established: anything on a physical device (physical `console` and `last-crash` have only unit tests and dry runs), `log show` over long windows, extensions, other runtimes or Xcode versions, and MCP calls against a live simulator (the tools' routing and schemas are unit-tested).

## Apps, files, reports and development

Physical Settings launch and app inventory succeeded. The launch option-order fix (`4c47998`) ensures devicectl options precede the bundle operand. One Safari URL preflight failed; broad physical URL/lifecycle claims are not made.

App-data command plans and an Apple-tool-owned temporary-domain synthetic copy round trip were checked. This is not actual app-container access/round-trip evidence. Physical saved-report listing passed. Download is implemented but hardware-unverified. Filtering and parsing now exist as [`last-crash`](#app-logs-console-and-crashes), verified on a simulator only; symbolication and deletion are missing. See [feature status](feature-status.md). Later: a report was downloaded on the phone ([wider command run](#wider-command-run-on-the-phone-and-a-simulator)), physical `last-crash` found and downloaded a crash ([console and last crash](#app-console-and-last-crash-on-the-phone)), and the probe app's container was listed, pushed and pulled ([remaining phone checks](#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session)).

The [probe app](probe-app.md) fixture and its touch probe passed its core unit tests, a warning-free simulator build, a simulator launch, XCUITest recording checks and a simulator `build-run` (2026-11-15, iPhone 17e simulator, iOS 27.2). It has not been run on hardware, so it has produced no delivery evidence yet. Its [touch measurement runner](probe-touch-runner.md) passed offline tests against canned tree output, receipts and logs, and its dry run's commands were accepted by `manzanero --dry-run`; it has not been run against a device. Later: both ran on the phone ([touch delivery](#touch-delivery-measured-with-the-probe-app)).

Simulator screenshot and finite H.264/HEVC movie checks passed. Build & Run passed simulator project/Debug and workspace/Release flows with product validation/install/launch; complete physical signing/deployment remains unverified. Later: physical signing, install and launch of the probe app passed ([touch delivery](#touch-delivery-measured-with-the-probe-app), [remaining phone checks](#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session)).

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

### The new tools over MCP

**2026-11-16**, a real stdio `manzanero mcp` session fed from a file, against the three simulators at once: `list_displays` (Duo), `press_remote play-pause` (TV probe), `rotate_crown 200` (watch probe) and `screenshot` with `display: LCD` (Duo). All four answered `isError: false`; over six sessions the probes counted every Play/Pause and moved the crown value by exactly 1.0 per call, and the PNG was written. When the first `tools/call` followed `notifications/initialized` with no pause, it sometimes got no response at all (in about half of eight such sessions, each time a `list_displays` call; the same `list_displays` alone also answered in one run and not in another, and two sessions starting with `inspect_device` answered). With a one-second pause after initialization three sessions in a row answered every call. This looked like a startup race in the MCP session, not in these tools; it was one, and is fixed ([MCP calls sent without waiting](#mcp-calls-sent-without-waiting)).

### Apple TV remote touch surface (not built)

**2026-11-16**, `manzanero-research-tv`, raw XPC from a scratch copy of the research probe; no product code. `universalhidservice` refused `connect`, `report` and `supportedDevices` as unknown requests. The `universalhid` feature (`LegacyUniversalHIDServer`) answered `supportedDevices` (`appleTVRemote`, `digitizer`, `mouse`, three more) and, from its decoding errors, takes `connect {_0: {vendorID (Int), productID (Int), product, usages [{page, code} (UInt16)]}}` and `report {_0: UInt64, _1: Data}`. A `connect` with usages 12/1 and with 13/5 each activated a virtual service logged as `unknown(0x0)`, but the reply failed with `NSCocoaErrorDomain` 4866 ("in-place encode must encode to a dictionary at the top level") and the service was cancelled when the connection closed. No swipe was delivered; details and what is missing are in [other families](other-families.md#remote-touch-surface-not-built).

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

**2026-11-17**, `manzanero-research-watch` (Series 12, 46mm) and a new `manzanero-research-watch-ultra` (Apple Watch Ultra 4, 49mm), both watchOS 27.2 (24S118), headless; host macOS 27.2.1, Xcode 27.2. Raw events were sent with the research probe first, then through `manzanero`. The text probe was a throwaway SwiftUI app (a `TextField` and a readout of its bound string, built with `swiftc`, untracked in `tmp/watch-left/`).

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
