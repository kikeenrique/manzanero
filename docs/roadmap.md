# Roadmap

The goal is a Swift CLI with broad Apple-device inspection and control, plus an optional MCP server that shares the same operations. iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope; physical controls and the observe → act → inspect loop come first.

This page has two halves: what exists today and how far it has been checked, and what is still to do. [Feature status](feature-status.md) is the compact inventory per area, the [live check plan](live-check-plan.md) lists the runs still owed on hardware, and [verification](verification.md) is the dated record of what was observed.

Verification levels used below:

- **iPhone 13 mini**: run on the one test phone (iOS 27.2.1, wired, macOS 27.2.1, Xcode 27.2). One phone and one OS version; not a general reliability claim.
- **Simulators only**: run on the named simulators (iOS, tvOS or watchOS 27.2 runtimes); nothing known about the hardware.
- **Unit-tested only**: local tests and dry runs; never run against a device.

## Achieved

| Area | What exists | Verified | Guide and record |
| --- | --- | --- | --- |
| Physical input | `tap`, `long-press`, `swipe`/`drag`, `pinch`, `multi-tap`, `multi-drag`, `gesture` (one to five contacts), `button` (home, lock, volume), `key`, guarded `wake` | iPhone 13 mini: the probe app received 150 of 150 measured actions, one to five simultaneous contacts, after the 200 ms input drain; Settings and Maps effects; `wake` once | [Physical input](native-input.md), [multitouch](multitouch.md), [sequences](gesture-sequences.md); [record](verification.md#touch-delivery-measured-with-the-probe-app) |
| Accessibility and screen | `tree`, `press`, `scroll`, `wait` (visible, gone, enabled, disabled, value, focused), `screen` (auto, tree, OCR), `ocr`, `decode-ax-archive` | iPhone 13 mini in Settings and the probe app, including a system prompt read and dismissed through the tree; every wait condition except `focused`, which is checked on the Apple TV simulator only | [Accessibility](direct-accessibility.md), [screen inspection](screen-understanding.md); [record](verification.md#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session) |
| Text entry | `type` in any layout the Mac ships (`--layout`), `keyboard-layouts`, `detect-layout`, `set-value`, physical `paste` | iPhone 13 mini: Spanish – ISO typing and detection, `set-value` in the probe's field, `paste` in Settings. Simulators: five layouts typed exactly, detection under four settings | [Physical typing](physical-typing.md), [layout research](keyboard-layouts.md); [phone](verification.md#keyboard-layouts-on-the-phone), [detection](verification.md#layout-detection), [set-value](verification.md#unicode-entry-by-set-value-on-the-phone) |
| Capture and recording | `screenshot`, `record` (`devicectl` default, in-process `--backend coredevice`), `frames`, `media-status`, `displays` and `--display` on simulators | iPhone 13 mini: native recordings up to 300 s, cancellation and reuse, `frames` in portrait. The `devicectl` recording backend fails on that phone (error 1001). Simulators: screenshots and movies, Duo display choice | [Recording](recording.md); [native recording](verification.md#native-media-and-recording), [frames](verification.md#frames-on-the-phone) |
| App lifecycle and diagnostics | `apps`, `launch`, `terminate`, `install`, `uninstall`, `open-url`, `files list/pull/push`, `reports list/get`, `build-run` with opt-in provisioning, `console`, `last-crash`, simulator `logs` | iPhone 13 mini: all of these except `logs`, which is simulator-only; `build-run` signed and installed the probe app. Simulators: `logs`, `console` and `last-crash` on one iPhone Air simulator, `build-run` project and workspace flows | [Build & Run](build-run.md), [app logs](app-logs.md); [phone](verification.md#app-console-and-last-crash-on-the-phone), [simulator](verification.md#app-logs-console-and-crashes) |
| iOS simulators | Every touch, key, typing, accessibility and `set-value` command in process, with orientation mapping; `boot`, `shutdown` | Simulators only: iPhone 17e in portrait and landscape and iPad mini (iOS 27.2), 70 of 70 built-in-plan actions per run, one to five contacts | [Simulator input](simulator-input.md); [record](verification.md#simulator-input-and-accessibility), [rotation and iPad](verification.md#rotation-and-ipad-on-the-simulator) |
| Other families | Apple TV `remote` and focus in trees and waits; Apple Watch `crown`, `button side` and `button action`; iPhone Duo `fold`, `unfold`, `hinge`, and touch, trees and captures that follow the active display | Simulators only: one tvOS, one watchOS and one iPhone Duo simulator (27.2) | [Other families](other-families.md); [record](verification.md#other-simulator-families) |
| CLI and MCP interface | Operation-first grammar with Swift Argument Parser, `MANZANERO_DEVICE`/`MANZANERO_SIMULATOR` defaults, exit 64 for usage errors, typed `CommandRequest` dispatch, a `--dry-run` plan for every device command, structured errors (`--error-format json`, MCP `structuredContent.error`), 45 MCP tools with inline image options, MCP startup hold and per-device call order, `handoff` | Grammar: iPhone 13 mini. MCP: live sessions on the phone and on simulators; call ordering on two simulators. Error classification: unit-tested, seen live for usage and busy errors. `handoff`: synthetic only | [MCP](mcp.md), [errors](errors.md), [handoff](handoff.md); [grammar](verification.md#operation-first-grammar-on-the-phone), [call order](verification.md#mcp-calls-sent-without-waiting) |
| Reliability and ownership | Per-device lease across processes, serial command-service queue, SIGINT/SIGTERM and MCP cancel/EOF cleanup, 200 ms input drain, `readiness`, `doctor` with private-interface and firewall reports | Lease: one two-process check on the phone and one on a simulator. Interrupts and MCP shutdown: iPhone 13 mini. Firewall diagnosis: found the cause of failed recordings on that Mac | [Physical input](native-input.md#ownership-across-processes), [readiness](readiness.md), [doctor output](dependencies.md#reading-doctor-output); [record](verification.md#first-live-run-of-the-queue-lease-wait-and-trimmed-bridge) |
| Test fixtures | Probe app (touch, log and text probes) and the touch measurement runner | iPhone 13 mini and simulators | [Probe app](probe-app.md), [runner](probe-touch-runner.md) |
| CI and packaging | Hosted CI (task validation, build, tests) on the `xcode-27` runner image; local universal beta archives, checksums and formula generation; guarded `release` task | CI passes on `main`. Packaging: local checks only. The beta release workflow has never passed on GitHub | [Releasing](releasing.md), [CI review](ci-review.md); [record](verification.md#distribution-and-privacy-checkpoints) |

The retired helper backends (AXe, the Rust idevice bridge, ipb helpers) are gone; their results stay in [verification](verification.md#retired-implementations) as history only.

## Pending

The order below is a suggested order, not one the owner set, except where an item says the owner decided. It follows the standing priorities of this page: dependable physical testing first, then coverage of more devices, then the gaps in other families, then delivery.

### Waiting for the owner

1. **`handoff` live test.** Only synthetic terminal and MCP exchanges have run. The owner decided it runs only when they say so.
2. **The decoded-JPEG video mode in the bridge.** Apple's `AVCStreamOutput` access check refuses this process, so `frames` uses the RTP stream instead and the mode is unused. Whether to remove it is the owner's decision.

### Dependable physical testing

3. **Recording startup and recovery.** Keyframe requests (PLI/FIR), crash and disconnect recovery are not built; the negotiated-feedback value has never been read live. Earlier startup failures were traced to the macOS firewall in one case; whether that explains all of them is open.
4. **Release after failure.** Quarantine after an uncertain release, and device-side release after a forced exit, crash or cable loss, are not handled. The lease is host-side only.
5. **Open questions on the phone.** One tap on the Settings search field had no effect while 36 others did; Apple's device services stopped answering once on 2026-11-16 (capture evidence before restarting them next time); one wait reported its subscription stop unconfirmed. See the [live check plan](live-check-plan.md#questions-still-open).
6. **Unclassified failures.** A few host-side recording, `frames` and archive failures, and errors that are not `CommandFailure`, still report `unclassified` ([errors](errors.md#unclassified-sites)).

### More devices and more apps

7. **A second iPhone, an iPad, and landscape on a phone.** Everything physical ran on one portrait iPhone 13 mini; rotation and iPad were measured on simulators only. The 200 ms input drain was measured on that phone alone.
8. **`set-value` in other apps** (SwiftUI, secure, search and web fields) and through MCP against a phone. It has run only in the probe app's field.
9. **Keyboard layouts on a phone.** Only Spanish – ISO, the layout the test phone uses on its own, has been typed and detected on hardware. A phone's layout cannot be read; `detect-layout` is the substitute. Whether a phone applies the ISO or ANSI table to the 13 layouts where they differ is unchecked.
10. **`frames` beyond portrait.** Rotated displays, other devices, long runs toward the 1000-frame and 1 GiB limits, and a second process competing for the stream.
11. **What apps' recognizers make of three to five contacts.** Delivery is measured; recognition in real apps is not.

### Other families

12. **Real Apple TV, Apple Watch and iPhone Duo hardware.** Everything in [other families](other-families.md) has run on simulators only; on hardware nothing is known.
13. **Apple TV remote touch surface.** Blocked: the simulator's `universalhid` service creates a virtual device but fails to encode its reply (`NSCocoaErrorDomain` 4866), so the device's ID never comes back and no swipe can be addressed ([details](other-families.md#remote-touch-surface-not-built)).
14. **Text entry on Apple Watch.** Keyboard events do not reach watchOS, so `key` and `type` are refused there, and `set-value` changed a SwiftUI field's text without changing the app's bound value ([details](other-families.md#digital-crown-and-side-button-apple-watch)). The remaining route is tapping the text entry sheet's own keys, which is not built.
15. **iPhone Duo gaps.** The Home Screen tree comes back empty on the Duo runtime, folded and unfolded: SpringBoard answers no snapshot at any depth there, so only OCR reads that screen. `press --label` is ambiguous in two-column layouts such as Settings (use `--id`). One `fold` in five was not observed within its 10 s bound on a loaded Mac.

### Not built

16. **Simulator `wake` and `paste`.** Both are refused as `unsupported-operation`; `simctl pbcopy` did not reach the simulator's pasteboard, so `set-value` is the Unicode route there.
17. **Physical `logs`.** Refused as `unsupported-operation`. The native `os_trace_relay` route ([research](app-logs-research.md)) is to be built only if `console` proves insufficient; debug-level lines and large outputs through physical `console` are unchecked.
18. **Agent features.** Durable sessions, reusable element handles, automatic prompt detection and notifications, symbolication, `.xcappdata` export, build progress and a build deadline.

### Delivery

19. **Beta release and Homebrew tap.** The release workflow ran once, manually, and failed before the CI fixes; it has not run since. No release has been published and the tap formula has not been tested with a real install ([releasing](releasing.md)).

## Owner decisions, 2026-11-16

| Topic | Decision | State |
| --- | --- | --- |
| Typing and keyboard layouts | `type` must work with any keyboard layout, not only the US one, on physical devices and simulators | Built: the caller names the layout (`--layout`, `MANZANERO_KEYBOARD_LAYOUT`, MCP `layout`), tables come from the Mac's own layouts ([research](keyboard-layouts.md)), and a simulator's explicit layout setting is checked first. Verified on a simulator in five layouts ([verification](verification.md#keyboard-layouts-on-the-simulator)) and, for Spanish – ISO, on the iPhone 13 mini, which uses that layout on its own ([verification](verification.md#keyboard-layouts-on-the-phone)). Open: other layouts on a phone |
| Keyboard layout detection | Yes: type a short probe into a field that can be read back and work out the layout from what arrives | Built: `detect-layout` (MCP `detect_keyboard_layout`), with a probe computed from the Mac's layouts, a restored field and no setting changed ([guide](physical-typing.md#finding-the-layout-detect-layout)). Found Spanish – ISO on the iPhone 13 mini and matched the setting on a simulator under four settings ([verification](verification.md#layout-detection)). US-like layouts that differ only under Option stay `ambiguous`. Open: other phones and layouts, fields other than the probe's, MCP against a phone |
| `set-value` on physical devices | Enable it; it is wanted on phones as well as simulators | Done: enabled and run on the iPhone 13 mini ([verification](verification.md#unicode-entry-by-set-value-on-the-phone)). Open: apps other than the probe, MCP against a phone |
| `handoff` live test | Do it only when the owner says so | Waiting for the owner |
| Apple TV, Apple Watch, iPhone Duo | Quick research on their simulators first (all three have one installed) | Research done ([other families research](other-families-research.md)); the work it proposed is built, see the next rows. Simulators only |
| Decoded-JPEG video mode in the bridge | Keep it and test it; do not remove it. Expose it as `frames`, N frames saved to a folder, for fast repeated screenshots | Tested: Apple's `AVCStreamOutput` access check refuses `manzanero` before any stream starts ([recording](recording.md#the-bridges-decoded-jpeg-mode-is-refused)); passing it would need a changed default, a renamed process or a patched framework. `frames` (MCP `capture_frames`) is built on the RTP stream that recording decodes instead, and verified on the iPhone 13 mini in portrait ([verification](verification.md#frames-on-the-phone)). The JPEG mode stays in the bridge, unused; whether to keep it is the owner's call |
| Other families: what to build | All of it: selectable Duo display, tvOS `remote`, watch `crown`, press with duplicate labels, tvOS focus and touch surface, and Duo fold | Built and run on simulators ([guide](other-families.md)), except the Apple TV remote's touch surface, which is blocked ([details](other-families.md#remote-touch-surface-not-built)). Press with duplicate labels: fixed for the TV and the Duo's row/text pairs by the hit-test client type; a label shown in both columns of a two-column layout is still ambiguous. The MCP call that sometimes got no answer right after initialization is fixed ([MCP](mcp.md#calls-sent-without-waiting)). The watch's left side button is built as `button action`; keyboard input does not reach watchOS and is refused |
| Duo fold | "Folding is missing in simctl. Look how other tools do it." | Built: a vendor-defined HID event sets the hinge angle and a CoreDevice stream reads it ([fold research](duo-fold-research.md)). `fold`, `unfold`, `hinge <degrees>`, reading the angle (`hinge`) and a derived posture are verified on one simulator ([guide](other-families.md#fold-iphone-duo)). Touch, trees, actions, waits and default captures follow the display the interface is on, verified on the inner display ([inner display](other-families.md#the-inner-display-unfolded)). Pipelined fold calls over MCP kept their order in five sessions, and `gesture` ran on the inner display. Open: real hardware |

## Architecture constraints

Device operations communicate with Apple frameworks/APIs from this project's code or Apple executables. Non-Apple device helpers remain blocked. Use maintained general-purpose libraries where useful, and preserve attribution for implementation references.

Keep private interfaces behind backend boundaries. Avoid automatic replay of input or a fallback that changes the operation's semantics. Surface native acceptance, observed effect and cleanup as separate facts.

## Implementation references

Independent protocol references and their licenses are documented in [dependencies.md](dependencies.md). The capability inventory distinguishes those references from this project's implemented routes and live verification.

## Completion criteria

A build or dry run proves planning/compilation, not hardware behavior. Completion requires evidence for the claimed platform, device family, transport and operation, including material failure and interruption cases. A returned receipt alone cannot establish UI effect, exact contact delivery or release.
