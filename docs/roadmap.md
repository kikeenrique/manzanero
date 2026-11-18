# Roadmap

The goal is a Swift CLI with broad Apple-device inspection and control, plus an optional MCP server that shares the same operations. iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope; physical controls and the observe → act → inspect loop come first.

This page has two halves: what exists today and how far it has been checked, and what is still to do. [Feature status](feature-status.md) is the compact inventory per area, the [live check plan](live-check-plan.md) lists the runs still owed on hardware, and [verification](verification.md) is the dated record of what was observed.

Verification levels used below:

- **iPhone 13 mini**: run on the one test phone (iOS 27.2.1, macOS 27.2.1, Xcode 27.2), in portrait. One phone and one OS version; not a general reliability claim. It had no passcode until the evening of 2026-11-17 and has one since.
- **Simulators only**: run on the named simulators (iOS, tvOS or watchOS 27.2 runtimes); nothing known about the hardware.
- **Unit-tested only**: local tests and dry runs; never run against a device.

The tool runs on an Apple silicon Mac with macOS 26.6 or later and Xcode 27 or later selected; there is no Intel version, because Xcode 27 has none.

Last brought up to date on 2026-11-18, after the first beta was published.

## Achieved

| Area | What exists | Verified | Guide and record |
| --- | --- | --- | --- |
| Physical input | `tap`, `long-press`, `swipe`/`drag`, `pinch`, `multi-tap`, `multi-drag`, `gesture` (one to five contacts), `button` (home, lock, volume), `key`, guarded `wake` | iPhone 13 mini: the probe app received 150 of 150 measured actions, one to five simultaneous contacts, after the 200 ms input drain; Settings and Maps effects; `wake` once | [Physical input](native-input.md), [multitouch](multitouch.md), [sequences](gesture-sequences.md); [record](verification.md#touch-delivery-measured-with-the-probe-app) |
| Accessibility and screen | `tree`, `press`, `scroll`, `wait` (visible, gone, enabled, disabled, value, focused), `screen` (auto, tree, OCR), `ocr`, `decode-ax-archive`; selection by identifier, label or current value (`--with-value`), `--index` among elements that share one, `--pid` for the browser around a page; web pages read through the browser's remote element | iPhone 13 mini in Settings and the probe app, including a system prompt read and dismissed through the tree, the passcode gate of Settings, and a web login form in Chrome filled and submitted; every wait condition except `focused`, which is checked on the Apple TV simulator only. `--with-value` on a simulator only; the browser `--pid` and `press` on an element reaching past the display's edge are unit-tested only. Portrait only: the tree refuses a phone in landscape | [Accessibility](direct-accessibility.md), [screen inspection](screen-understanding.md); [record](verification.md#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session) |
| Text entry | `type` in any layout the Mac ships (`--layout`), `keyboard-layouts`, `detect-layout` (with `--index`), `set-value`, physical `paste` | iPhone 13 mini: Spanish – ISO typing and detection, `set-value` in the probe's field and in a text field and a secure field in Settings, `paste` in Settings. Simulators: five layouts typed exactly, detection under four settings, `detect-layout --index`. A secure field's masked read-back receipt is unit-tested only | [Physical typing](physical-typing.md), [layout research](keyboard-layouts.md); [phone](verification.md#keyboard-layouts-on-the-phone), [detection](verification.md#layout-detection), [set-value](verification.md#unicode-entry-by-set-value-on-the-phone) |
| Capture and recording | `screenshot`, `record` (`devicectl` default, in-process `--backend coredevice`), `frames`, `media-status`, `displays` and `--display` on simulators | iPhone 13 mini: native recordings up to 300 s, cancellation and reuse, `frames` in portrait; one run of each passed after the bridge change of 2026-11-17; a screenshot of the sleeping phone says the display was off. The phone negotiated RTCP feedback as `disabled` in three recordings, one of which asked for it. The `devicectl` recording backend fails on that phone (error 1001). Simulators: screenshots and movies, Duo display choice | [Recording](recording.md); [native recording](verification.md#native-media-and-recording), [frames](verification.md#frames-on-the-phone) |
| App lifecycle and diagnostics | `apps`, `launch`, `terminate`, `install`, `uninstall`, `open-url`, `files list/pull/push`, `reports list/get`, `build-run` with opt-in provisioning, `console`, `last-crash`, simulator `logs`; an opt-in probe of the phone's log relay (`test:os-trace-relay`) | iPhone 13 mini: all of these except `logs`, which is simulator-only; `build-run` signed and installed the probe app; the probe read the probe app's log lines at every level, debug included, through the relay. Simulators: `logs`, `console` and `last-crash` on one iPhone Air simulator, `build-run` project and workspace flows | [Build & Run](build-run.md), [app logs](app-logs.md); [phone](verification.md#app-console-and-last-crash-on-the-phone), [simulator](verification.md#app-logs-console-and-crashes) |
| iOS simulators | Every touch, key, typing, accessibility and `set-value` command in process, with orientation mapping; `boot`, `shutdown` | Simulators only: iPhone 17e in portrait and landscape and iPad mini (iOS 27.2), 70 of 70 built-in-plan actions per run, one to five contacts | [Simulator input](simulator-input.md); [record](verification.md#simulator-input-and-accessibility), [rotation and iPad](verification.md#rotation-and-ipad-on-the-simulator) |
| Other families | Apple TV `remote` and focus in trees and waits; Apple Watch `crown`, `button side` and `button action`; iPhone Duo `fold`, `unfold`, `hinge`, and touch, trees and captures that follow the active display | Simulators only: one tvOS, two watchOS (Series 12 and Ultra 4) and one iPhone Duo simulator (27.2) | [Other families](other-families.md); [record](verification.md#other-simulator-families) |
| CLI and MCP interface | Operation-first grammar with Swift Argument Parser, `MANZANERO_DEVICE`/`MANZANERO_SIMULATOR` defaults, exit 64 for usage errors, typed `CommandRequest` dispatch, a `--dry-run` plan for every device command, structured errors (`--error-format json`, MCP `structuredContent.error`), 46 MCP tools with inline image options, MCP startup hold and per-device call order, `handoff` answered at a terminal or in an MCP host's form, or ended by the device itself with `--until` | Grammar: iPhone 13 mini. MCP: live sessions on the phone and on simulators; call ordering on two simulators and the phone. Error classification: unit-tested, seen live for usage and busy errors. `handoff`: iPhone 13 mini with the owner, every ending: observed (`unlocked`, `paired`, an element), timed out, declined at a terminal while watching, and Accept, Decline and Cancel from Claude Code; a simulator too | [MCP](mcp.md), [errors](errors.md), [handoff](handoff.md); [grammar](verification.md#operation-first-grammar-on-the-phone), [call order](verification.md#mcp-calls-sent-without-waiting) |
| Reliability and ownership | Per-device lease across processes, quarantine after an input whose release is unknown (`clear-quarantine`), serial command-service queue, SIGINT/SIGTERM and MCP cancel/EOF cleanup, 200 ms input drain, lock state in every input receipt, `readiness`, `doctor` with requirement (Xcode 27, macOS 26.6), private-interface and firewall reports | Lease: one two-process check on the phone and one on a simulator. Quarantine: one simulator and the phone, for a killed touch. Interrupts and MCP shutdown: iPhone 13 mini. `wake` and the lock note: the phone with a passcode set. Firewall diagnosis: found the cause of failed recordings on that Mac | [Physical input](native-input.md#ownership-across-processes), [readiness](readiness.md), [doctor output](dependencies.md#reading-doctor-output); [record](verification.md#first-live-run-of-the-queue-lease-wait-and-trimmed-bridge) |
| Test fixtures | Probe app (touch, log, text and permission probes) and the touch measurement runner | iPhone 13 mini and simulators; the permission probe on the phone only | [Probe app](probe-app.md), [runner](probe-touch-runner.md) |
| CI, packaging and release | Hosted CI (task validation, build, tests) on the `xcode-27` runner image; an Apple silicon beta archive, checksums and formula generation; the release workflow and the guarded `release` task; the formula in `kikeenrique/homebrew-tap` | CI passes on `main`. v0.1.0-beta.1 was published on 2026-11-18 through the release workflow, after a rehearsal and an audit of the history, and installed from the tap with Homebrew on the development Mac; no other Mac has installed it. The arm64-only archive and formula are built and checked locally, and not yet released | [Releasing](releasing.md), [public readiness](public-readiness.md), [CI review](ci-review.md); [record](verification.md#distribution-and-privacy-checkpoints) |

The retired helper backends (AXe, the Rust idevice bridge, ipb helpers) are gone; their results stay in [verification](verification.md#retired-implementations) as history only.

### Added on 2026-11-17

The first table is work that ran on simulators or in unit tests. The second is the phone: a session in the morning, then web content, a passcode and human handoff through the day, all on the iPhone 13 mini.

| Task | Result | Record |
| --- | --- | --- |
| Touch plan on the Duo's inner display | 14 of 14 actions and 29 of 29 contacts delivered, including `gesture` and a three-path `multi-drag` | [Inner display](verification.md#the-duos-inner-display) |
| Pipelined `fold_device`/`set_hinge_angle` over MCP | Answered in the order sent in five sessions; each read saw the state after the call before it | [Inner display](verification.md#the-duos-inner-display) |
| Apple Watch Ultra Action button | `button action` (page 0xFF01, usage 0x200) opened the Action button's setup on an Ultra simulator | [Watch](verification.md#action-button-and-keyboard-input-on-the-watch) |
| Keyboard input on watchOS | Found not to arrive; `key` and `type` are refused on watch simulators | [Watch](verification.md#action-button-and-keyboard-input-on-the-watch) |
| Duo Home Screen tree | Cause narrowed: SpringBoard answers no snapshot at any depth; not fixable by a shallower request | [Inner display](verification.md#the-duos-inner-display) |
| Ambiguous selectors | The failure lists up to five matches with identifier, visibility and frame | [Accessibility](direct-accessibility.md#current-guarded-native-press) |
| Failure classification | The recording, `frames` and archive sites have categories; a reply that is not a property list no longer escapes as a Foundation error | [Errors](errors.md#unclassified-sites) |
| Evidence for stuck device services | `mise run diagnose:device-services` | [Tasks](development-tasks.md) |
| Unconfirmed subscription stop | The diagnostic carries the stop's duration and frame count | [Record](verification.md#first-live-run-of-the-queue-lease-wait-and-trimmed-bridge) |
| Decoded-JPEG bridge mode | Removed; the bridge's video session is packet-only | [Recording](recording.md#the-bridges-decoded-jpeg-mode-is-refused) |
| Quarantine after an uncertain release | Input is refused as `device-quarantined` until `clear-quarantine`; a killed long press quarantined a simulator, an interrupted one did not | [Guide](native-input.md#quarantine-after-an-uncertain-release), [record](verification.md#quarantine-after-an-uncertain-release) |

On the phone:

| Task | Result | Record |
| --- | --- | --- |
| Recording and `frames` after the bridge change | Both passed; `rtcp.negotiatedFeedback` read live for the first time, as `disabled` | [Session](verification.md#phone-session-of-2026-11-17) |
| A hold whose sender is killed | The phone ended the contact by itself; quarantine, `clear-quarantine` and the next tap behaved as on the simulator | [Session](verification.md#phone-session-of-2026-11-17) |
| `set-value` outside the probe app | A text field and a secure field in Settings, and the probe's field through MCP | [Session](verification.md#phone-session-of-2026-11-17) |
| MCP calls sent without waiting | Seven calls to the phone answered and ran in the order sent | [Session](verification.md#phone-session-of-2026-11-17) |
| `console` | Info and above mirrored, debug-level lines not; a 1 KiB bound kept the tail of 4.6 kB | [Session](verification.md#phone-session-of-2026-11-17) |
| Web content | Cause found and fixed: a page's tree arrives rooted at the browser's remote element, which the normalizer refused. `tree`, `wait`, `press` and typing after a press work on a page in Chrome | [Guide](direct-accessibility.md#web-content), [record](verification.md#web-content-on-the-phone) |
| `--index` (MCP `index`) | Chooses among elements that share a label; built for `press`, `scroll`, `set-value` and `wait` and used to fill a web login form | [Guide](direct-accessibility.md#current-guarded-native-press), [record](verification.md#web-content-on-the-phone) |
| A passcode on the phone | Setting one dropped the pairing once. `wake` stops at `awake-locked` without pressing Home; a sleeping phone refuses `tree` and `tap` as `display-off`; an awake lock screen takes input | [Record](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen) |
| Lock state in input receipts | Every physical input receipt carries `passcodeRequired`, and a `lockNote` when the phone is locked | [Guide](native-input.md#receipts-and-partial-effects) |
| `handoff` at a terminal | With the owner: `done`, `decline`, `cancel`, a timeout and the non-interactive refusal, around a rotation, a re-pairing, a passcode unlock and an app permission prompt | [Physical step](verification.md#handoff-with-a-physical-step), [passcode](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen), [permission](verification.md#handoff-with-an-app-permission-prompt) |
| Permission probe | The probe app raises a real notification prompt on demand and reports the decision | [Probe app](probe-app.md#permission-probe) |
| `request_handoff` from an MCP host | In Claude Code: a tap sent while a handoff was pending was refused; the form, reworked three times to no fields and three lines, was answered with Accept and with Decline, and a refused permission was still reported as a finished step | [Guide](handoff.md#mcp-flow), [record](verification.md#handoff-through-an-mcp-host-the-pause-and-the-form) |
| `handoff --until` | Watches the device and ends by itself, with a timeout, no form and no terminal; it ended 21 s after a prompt was raised, when the owner answered it | [Guide](handoff.md#watching-the-device---until), [record](verification.md#handoff-that-watches-the-device) |

### Added on the night of 2026-11-17 and on 2026-11-18

Decisions the owner took that night, built and run as far as the last column says, then the first release.

| Task | Result | Record |
| --- | --- | --- |
| `press` on an element partly off the display | Accepted when its centre is on the display and the hit test answers the element; a centre off the display is refused. Unit-tested | [Guide](direct-accessibility.md#current-guarded-native-press) |
| Selection by value | `--with-value` (MCP `by: value`) for `press`, `scroll`, `set-value`, `wait` and `handoff --until`, for elements with neither label nor identifier. Run on a simulator | [Record](verification.md#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note) |
| The browser around a web page | A selector action accepts `--pid` for the process hosting the display-centre one; any other PID is still refused. Unit-tested | [Guide](direct-accessibility.md#web-content) |
| Small faults of 2026-11-17 | A secure field's bullets read back as `masked`, not as a mismatch (unit-tested); `detect-layout` takes `--index` (simulator); a screenshot of a sleeping phone says the display was off (phone); a watching handoff names the awaited value | [Record](verification.md#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note) |
| Failure classification, second pass | Errors that are not the tool's own get a category by type and domain: decoding, POSIX, URL, file and AVFoundation errors. Unit-tested | [Errors](errors.md#unclassified-sites) |
| Handoff, finished | On the phone with the owner: `unlocked` from locked, `paired` from unpaired, the passcode gate of Settings going away, a three-minute timeout, a decline typed while watching, the MCP `until` field, and Cancel on the host's form. On a simulator: a prompt and a value changed by a second process | [Timeout and simulator](verification.md#handoff-watch-a-timeout-on-the-phone-and-runs-on-a-simulator), [with the owner](verification.md#the-last-handoff-runs-on-the-phone) |
| An offer that asks for RTCP feedback | The phone still negotiated `disabled` and recorded normally. Keyframe requests are dropped; the scratch change was not kept | [Record](verification.md#an-offer-that-asks-for-rtcp-feedback) |
| The Duo's inner display | Four- and five-path `multi-drag` delivered; `fold` observed five times of five with two other simulators booted. Found: a portrait-only app is letterboxed there, and `press` fails on it | [Inner display](verification.md#the-duos-inner-display) |
| The phone's log relay | `os_trace_relay` advertises a plain, unencrypted shim; a bounded stream for one PID delivered the probe app's lines at every level over the native tunnel, and reopened. An opt-in task, not a command | [Record](verification.md#the-log-relay-on-the-phone) |
| Audit before the first release | The test phone's UDID, committed the day before, was removed from the file and from 11 commits of history; Gitleaks found nothing in the history or the tracked files | [Public readiness](public-readiness.md#audit-before-the-first-release-2026-11-18) |
| First beta | The release workflow passed a rehearsal, then published v0.1.0-beta.1 as a prerelease; the assets match their checksums | [Rehearsal](verification.md#release-rehearsal), [publication](verification.md#first-beta-published) |
| Homebrew | The formula is in the tap, clean under `brew style` and `brew audit`; `brew install kikeenrique/tap/manzanero` installed, tested and ran on the development Mac with no Gatekeeper prompt | [Record](verification.md#homebrew-install-from-the-tap) |
| Apple silicon, macOS 26.6, Xcode 27 | The manifest targets macOS 26.6, `doctor` reports the requirement, packaging builds one arm64 archive and the formula generator declares the architecture and Xcode 27. Checked locally; in no release yet | [Record](verification.md#apple-silicon-only-xcode-27-and-macos-266) |

## Pending

The order below is a suggested order, not one the owner set. It follows the standing priorities of this page: dependable physical testing first, then coverage of more devices, then the gaps in other families, then what is not built, then delivery.

### Decisions waiting for the owner

None at the moment. What was decided on 2026-11-17 and 2026-11-18 is in the [decision tables](#owner-decisions-2026-11-17) below.

### Dependable physical testing

1. **Phone runs owed for the changes of 2026-11-17.** Unit-tested or simulator-only so far: `press` on a web field wider than the display, a selector action on the browser's own controls with `--pid`, `--with-value` on the Settings search field, and the masked receipt of a secure field. The first two need a web page in Safari, which the owner chooses.
2. **Web content: what is left.** Checked in Chrome only: Safari and an app's own `WKWebView` are unrun, and so is `scroll` on a page. The first read after a page load can select the browser instead of the page; how often is not counted. `set-value` is acknowledged by a web input and does not change it (press it and `type`).
3. **A phone in landscape.** `tree` and every selector command refuse it ("native AX centre selection requires portrait geometry"), seen on 2026-11-17. Touch, keys, `frames` and recording in landscape are unrun on hardware; rotation was measured on simulators only.
4. **Recording startup.** Recovery is not built (item 21). Earlier startup failures were traced to the macOS firewall in one case; whether that explains all of them is open. `rtcp.negotiatedFeedback` has been read in three recordings, `disabled` each time.
5. **Release after failure.** Quarantine is built and ran on a simulator and the phone, where a killed process's contact ended by itself. Still unobserved: a held key or button whose sender is killed, and a lost cable or network path mid-input, which reaches quarantine only if the bridge reports an unknown outcome. The mark's `since` time is when the next input was refused, not when the owner died.
6. **Open questions on the phone.** One tap on the Settings search field had no effect while 36 others did; Apple's device services stopped answering once on 2026-11-16 (`mise run diagnose:device-services` captures the evidence before a restart next time). Neither has recurred. An unconfirmed subscription stop recurred on 2026-11-17, three times among about thirty selector commands: each time the socket closed 2 to 3 ms into the stop exchange after one cleanup frame, so the phone closed first; whether that is harmless is not settled. Setting a passcode dropped the pairing once; whether it always does is unknown. A mode in the touch runner that compares the tree before and after each action, to catch the next missed tap with evidence, is not built. See the [live check plan](live-check-plan.md#questions-still-open).
7. **Unclassified failures.** Errors that are not `CommandFailure` get a category when their type and domain are recognised; the rest still report `unclassified` ([errors](errors.md#unclassified-sites)). None of the recognised ones has been provoked on a device.
8. **Handoff: what needs other equipment.** Finished on this phone and host. Left: a second MCP host, and a real biometric or purchase prompt (the test phone has no Face ID set up; the passcode gate of Settings ran in its place). Whether a host removes a form the server withdraws is untested, so a watching handoff shows no form.

### More devices and more apps

9. **A second iPhone and an iPad.** Everything physical ran on one iPhone 13 mini; iPad was measured on a simulator only. The 200 ms input drain was measured on that phone alone. Other iPhones and iPads are paired with the development Mac; none is used until the owner names it.
10. **`set-value` in more fields.** It ran in the probe's field, in a UIKit text field and a secure field in Settings, and through MCP. A SwiftUI field with a label or identifier is untried.
11. **`--index` among real duplicates on a simulator, and through MCP against a device.** It ran on the phone from the CLI, on a web form; on a simulator only `detect-layout --index` ran, on a field that has no duplicate.
12. **Keyboard layouts on a phone.** Only Spanish – ISO, the layout the test phone uses on its own, has been typed and detected on hardware. A phone's layout cannot be read; `detect-layout` is the substitute. Whether a phone applies the ISO or ANSI table to the 13 layouts where they differ is unchecked.
13. **`frames` beyond one portrait phone.** Other devices, long runs toward the 1000-frame and 1 GiB limits, and a second process competing for the stream.
14. **What apps' recognizers make of three to five contacts.** Delivery is measured; recognition in real apps is not.
15. **`console` above its default bound.** An output above 64 KiB has not been produced: the probe app has no bulk trigger.

### Other families

16. **Real Apple TV, Apple Watch and iPhone Duo hardware.** Everything in [other families](other-families.md) has run on simulators only; on hardware nothing is known. Two Apple TVs, a watch and an iPhone Duo are paired with the development Mac; none is used until the owner names it.
17. **Apple TV remote touch surface.** Blocked: the simulator's `universalhid` service creates a virtual device but fails to encode its reply (`NSCocoaErrorDomain` 4866), so the device's ID never comes back and no swipe can be addressed ([details](other-families.md#remote-touch-surface-not-built)).
18. **Text entry on Apple Watch.** Keyboard events do not reach watchOS, so `key` and `type` are refused there, and `set-value` changed a SwiftUI field's text without changing the app's bound value ([details](other-families.md#digital-crown-and-side-button-apple-watch)). The remaining route is tapping the text entry sheet's own keys, which is not built.
19. **iPhone Duo gaps.** The Home Screen tree comes back empty on the Duo runtime, folded and unfolded: SpringBoard answers no snapshot at any depth there, so only OCR reads that screen; recheck on the next runtime. On the inner display, four- and five-path `multi-drag` ran on 2026-11-17; the centre-hit fallback (for a simulator that reports no frontmost application) has not, and only one orientation was seen. A portrait-only app is letterboxed there, in a window 469 points wide: its tree's frames are relative to that window, so `press` fails at the hit test (error 8), and touch coordinates are the display's, not the window's ([record](verification.md#the-duos-inner-display)); mapping frames by the window's origin is not built. One `fold` in five was not observed within its 10 s bound on a Mac with three other simulators booted; with two others booted, five of five were. It has not run with nothing else booted. A label shown in both columns of a two-column layout is ambiguous; `--index` now chooses, and has not been tried there.

### Not built

20. **`logs` for physical devices.** Pending since the owner's word on 2026-11-18. It is refused as `unsupported-operation` today, and it is the only way to an app's debug-level lines on a phone, because `console --os-log` mirrors info and above. The route is the native `os_trace_relay` service ([research](app-logs-research.md), section P-B), and two experiments showed it works on the test phone: the service is a plain, unencrypted shim, and a bounded stream for one PID delivered the probe app's lines at every level over the native tunnel ([record](verification.md#the-log-relay-on-the-phone)). The opt-in task `test:os-trace-relay` and the bridge's shim-port function are the starting point. Still to build: the command with the options simulator `logs` has, a bound on raw bytes received as well as entries kept, filtering by subsystem, category and level on the Mac, bundle-to-PID resolution and what to do when a relaunch changes the PID, a dry-run plan, the MCP mapping, and the `doctor` and dependency notes. Still to learn on the device: long streams, a stream of every process, and records with unusual fields.
21. **Recording recovery.** A restart of the stream after loss, a crash or a disconnect. Keyframe requests were dropped after the phone declined an offer that asked for RTCP feedback, so a restart is the route. Not designed yet.
22. **Simulator `wake` and `paste`.** Both are refused as `unsupported-operation`; `simctl pbcopy` did not reach the simulator's pasteboard, so `set-value` is the Unicode route there.
23. **Agent features.** Durable sessions, reusable element handles, symbolication, `.xcappdata` export, build progress and a build deadline. Prompt detection exists only in the form a caller asks for: `handoff --until gone` on a prompt's button. Nothing notices a prompt by itself.

### Delivery

The first beta is out: v0.1.0-beta.1, published on 2026-11-18 and installable with `brew install kikeenrique/tap/manzanero` ([record](verification.md#first-beta-published)). What is left:

24. **Correct the tap's formula for beta.1.** It still has the `on_intel` block and `macos: :sequoia`. The corrected text (one `url`, `arch: :arm64`, `macos: :tahoe`, Xcode 27.0) is written and waits to be put in the tap, run through `brew style` and `brew audit`, and reinstalled; the tap is another repository.
25. **The next beta.** The Apple silicon, macOS 26.6 and Xcode 27 changes are on `main` and in no release: the hosted release workflow has not run with them, and `brew style` has not seen the generated formula's new shape. v0.1.0-beta.1 itself still ships an x86_64 slice and claims macOS 15.
26. **An install on a tester's Mac.** Only the development Mac has installed it, and that Mac has Xcode and every tool already.
27. **Signing.** The archives are ad hoc signed and not notarized. Through Homebrew that runs at once; an archive downloaded by hand would be quarantined and Gatekeeper is expected to refuse it, which nobody has tried. Developer ID signing and notarization are not planned and would be the owner's decision ([releasing](releasing.md)).
28. **Before each release:** repeat the identifier check and the secrets scan of the [public-readiness audit](public-readiness.md#audit-before-the-first-release-2026-11-18), and run the publishing commands from the owner's own terminal, because an agent session's shell has no access to the SSH key.

## Owner decisions, 2026-11-16

| Topic | Decision | State |
| --- | --- | --- |
| Typing and keyboard layouts | `type` must work with any keyboard layout, not only the US one, on physical devices and simulators | Built: the caller names the layout (`--layout`, `MANZANERO_KEYBOARD_LAYOUT`, MCP `layout`), tables come from the Mac's own layouts ([research](keyboard-layouts.md)), and a simulator's explicit layout setting is checked first. Verified on a simulator in five layouts ([verification](verification.md#keyboard-layouts-on-the-simulator)) and, for Spanish – ISO, on the iPhone 13 mini, which uses that layout on its own ([verification](verification.md#keyboard-layouts-on-the-phone)). Open: other layouts on a phone |
| Keyboard layout detection | Yes: type a short probe into a field that can be read back and work out the layout from what arrives | Built: `detect-layout` (MCP `detect_keyboard_layout`), with a probe computed from the Mac's layouts, a restored field and no setting changed ([guide](physical-typing.md#finding-the-layout-detect-layout)). Found Spanish – ISO on the iPhone 13 mini and matched the setting on a simulator under four settings ([verification](verification.md#layout-detection)). US-like layouts that differ only under Option stay `ambiguous`. Open: other phones and layouts, fields other than the probe's, MCP against a phone |
| `set-value` on physical devices | Enable it; it is wanted on phones as well as simulators | Done: enabled and run on the iPhone 13 mini ([verification](verification.md#unicode-entry-by-set-value-on-the-phone)), then in Settings and through MCP ([session](verification.md#phone-session-of-2026-11-17)). Open: fields without label or identifier, web fields, a SwiftUI field |
| `handoff` live test | Do it only when the owner says so | Run on 2026-11-17 at the owner's word, through the day: at a terminal, from an MCP host, and watching the device ([what is left](#dependable-physical-testing)) |
| Apple TV, Apple Watch, iPhone Duo | Quick research on their simulators first (all three have one installed) | Research done ([other families research](other-families-research.md)); the work it proposed is built, see the next rows. Simulators only |
| Decoded-JPEG video mode in the bridge | Keep it and test it; do not remove it. Expose it as `frames`, N frames saved to a folder, for fast repeated screenshots | Tested: Apple's `AVCStreamOutput` access check refuses `manzanero` before any stream starts ([recording](recording.md#the-bridges-decoded-jpeg-mode-is-refused)); passing it would need a changed default, a renamed process or a patched framework. `frames` (MCP `capture_frames`) is built on the RTP stream that recording decodes instead, and verified on the iPhone 13 mini in portrait ([verification](verification.md#frames-on-the-phone)). On 2026-11-17 the owner decided to remove the unused JPEG mode, and it is gone from the bridge |
| Other families: what to build | All of it: selectable Duo display, tvOS `remote`, watch `crown`, press with duplicate labels, tvOS focus and touch surface, and Duo fold | Built and run on simulators ([guide](other-families.md)), except the Apple TV remote's touch surface, which is blocked ([details](other-families.md#remote-touch-surface-not-built)). Press with duplicate labels: fixed for the TV and the Duo's row/text pairs by the hit-test client type; a label shown in both columns of a two-column layout is still ambiguous. The MCP call that sometimes got no answer right after initialization is fixed ([MCP](mcp.md#calls-sent-without-waiting)). The watch's left side button is built as `button action`; keyboard input does not reach watchOS and is refused |
| Duo fold | "Folding is missing in simctl. Look how other tools do it." | Built: a vendor-defined HID event sets the hinge angle and a CoreDevice stream reads it ([fold research](duo-fold-research.md)). `fold`, `unfold`, `hinge <degrees>`, reading the angle (`hinge`) and a derived posture are verified on one simulator ([guide](other-families.md#fold-iphone-duo)). Touch, trees, actions, waits and default captures follow the display the interface is on, verified on the inner display ([inner display](other-families.md#the-inner-display-unfolded)). Pipelined fold calls over MCP kept their order in five sessions, and `gesture` ran on the inner display. Open: real hardware |

## Owner decisions, 2026-11-17

| Topic | Decision | State |
| --- | --- | --- |
| Release after failure | Yes to quarantine on the Mac first; the device-side release waits for the phone | Built and run on one simulator and on the phone ([guide](native-input.md#quarantine-after-an-uncertain-release)). The phone ended a killed process's contact by itself. Open: a held key or button, and a lost connection |
| Decoded-JPEG video mode in the bridge | Remove it | Removed, with its `doctor` entry and the `test:media-frames` task. One recording and one `frames` run passed on the phone after the change |
| Selector index for labels without identifiers | Not now; then, the same afternoon, go ahead, once web pages showed such labels | Built as `--index` (MCP `index`) and used on the phone |
| Input sent to a locked phone | Say so in the receipt; do not refuse it | Built: `passcodeRequired` and `lockNote` in every physical input receipt ([guide](native-input.md#receipts-and-partial-effects)) |
| A source for a real permission prompt | Add one to the probe app | Built: the permission probe ([guide](probe-app.md#permission-probe)) |
| The MCP handoff form | The checkbox, then a required choice, were both rejected as confusing; the wording had to agree with the device's own prompt | No fields, three lines, the host's Accept and Decline as the answer ([guide](handoff.md#mcp-flow)) |
| A handoff without a form | Yes: watch the device for the step and end by itself, with a timeout | Built as `handoff --until` and run on the phone for a prompt, an unlock, a pairing and the passcode gate ([guide](handoff.md#watching-the-device---until)) |
| The test phone's default browser | Safari | Changed from Chrome through Settings on 2026-11-17 |
| `press` on an element partly off the display | Yes | Built: the centre must be on the display and hit the element itself ([guide](direct-accessibility.md#current-guarded-native-press)). Unit-tested; open: the zoomed web field on the phone |
| A selector for elements with neither label nor identifier | Yes, by value | Built as `--with-value` (MCP `by: value`) for `press`, `scroll`, `set-value`, `wait` and `handoff --until`, and run on a simulator ([record](verification.md#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note)). Open: the Settings search field on the phone |
| One tree for a browser and its page | No graft; let `--pid` name the browser | Built: a selector action accepts the PID of the process hosting the display-centre one ([guide](direct-accessibility.md#web-content)). Unit-tested; open: a browser on the phone |
| An offer that asks for RTCP feedback | One time-boxed experiment; drop keyframe requests if it stays `disabled` | Run: the phone still negotiated `disabled` and the recording was normal ([record](verification.md#an-offer-that-asks-for-rtcp-feedback)). Keyframe requests are dropped; recovery is to be a stream restart |
| Finishing handoff | "Now and for all" | Done that night on the phone and a simulator ([timeout and simulator](verification.md#handoff-watch-a-timeout-on-the-phone-and-runs-on-a-simulator), [with the owner](verification.md#the-last-handoff-runs-on-the-phone)). Open only: a second host and a real biometric prompt |

## Owner decisions, 2026-11-18

| Topic | Decision | State |
| --- | --- | --- |
| Debug-level logs from a phone (`os_trace_relay`) | Look before deciding: read what the service advertises, then one bounded stream | Both done: a plain shim, not RemoteXPC and not encrypted, and a stream that delivered the probe app's debug lines over the native tunnel ([record](verification.md#the-log-relay-on-the-phone)) |
| `logs` for physical devices | Mark it as a pending task | [Pending](#not-built), with what the command still needs |
| The test phone's UDID in a test file | Replace it and rewrite history, then scan | Done before any tag existed: 11 commits have new IDs, and the scan found nothing ([audit](public-readiness.md#audit-before-the-first-release-2026-11-18)). The owner force-pushed |
| First beta | Publish | v0.1.0-beta.1, a prerelease, published by the owner's tag; formula in the tap; installed with Homebrew on the development Mac ([record](verification.md#first-beta-published)) |
| Intel | Do not distribute for Intel: the tool needs Xcode 27 or later, which is Apple silicon only and needs macOS 26.6 or later | Built for the next beta: deployment target 26.6, one arm64 archive, a formula with the architecture and Xcode 27, a `doctor` requirement ([record](verification.md#apple-silicon-only-xcode-27-and-macos-266)). Open: the tap's beta.1 formula, and a release that carries it |

## Architecture constraints

Device operations communicate with Apple frameworks/APIs from this project's code or Apple executables. Non-Apple device helpers remain blocked. Use maintained general-purpose libraries where useful, and preserve attribution for implementation references.

Keep private interfaces behind backend boundaries. Avoid automatic replay of input or a fallback that changes the operation's semantics. Surface native acceptance, observed effect and cleanup as separate facts.

## Implementation references

Independent protocol references and their licenses are documented in [dependencies.md](dependencies.md). The capability inventory distinguishes those references from this project's implemented routes and live verification.

## Completion criteria

A build or dry run proves planning/compilation, not hardware behavior. Completion requires evidence for the claimed platform, device family, transport and operation, including material failure and interruption cases. A returned receipt alone cannot establish UI effect, exact contact delivery or release.
