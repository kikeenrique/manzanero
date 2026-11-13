# Native CoreDevice input backend

## Current direct backend

Device operations must not invoke non-Apple intermediate executables. Physical `button home|lock|volume-up|volume-down` now calls Apple CoreDevice/RemoteXPC **in process**, through the project's `AppleDeviceBridge` interoperability target. Both `physical <device> button <name>` and explicit `--physical-backend coredevice` use it. There is no ipb helper build, helper launch, Swift private-value ABI shim, or third-party runtime dependency in this button path.

Swift validates the operation, queries fresh identity/readiness with Apple's `devicectl`, checks the requested UUID/UDID and reported CoreDevice version, then enters the bridge. The bridge dynamically loads the installed Apple framework, requests the button service socket, sends one `IndigoButtonEvent` down/up pair, and waits for a service barrier before closing its connections. The socket request has a 15-second deadline and the barrier a 3-second deadline. Up is attempted after down even if a connection error is observed. A failed dispatch is never replayed. Normal dispatch does not prove UI effect or release; receipts report `backend: coredevice-direct`, `verified: false`, `releaseVerified: false`. SIGINT/crash release and other buttons are not hardware-verified.

The Home action was screenshot-verified from Settings to Home on the selected USB iPhone 13 mini. The direct implementation follows protocol observations in the MIT AXe/ipb references; no executable or implementation source from either project is invoked by this path. Private symbol availability is checked at runtime and unavailable interfaces fail before input. Existing human-handoff pause applies.

## Direct single-contact touch

Physical `tap`, `long-press`, `drag`, and `swipe` also use the in-process backend, by default or with explicit `--physical-backend coredevice`. Coordinates are normalized 0...1 in the current interface, with origin at its top left. A tap lasts 80 ms; long-press accepts 0.1...10 seconds; drag/swipe accepts 0.03...10 seconds. Inspect a fresh screen before choosing coordinates.

After fresh identity/readiness, Apple's `devicectl device info displays` must report exactly one awake integrated primary display, finite positive bounds/scale, and recognized native/current orientation. Normalized interface coordinates are rotated into the digitizer's portrait frame. Panels with a nonzero native orientation additionally require agreeing non-flat device orientation. A second display query must match before dispatch. These reads are sequential, not atomic; rotation during a gesture is not monitored.

The project's bridge opens Apple's Indigo digitizer service and requires a readiness barrier before input. It sends a custom `DigitizerPoint` dictionary with x/y doubles; it is not a Codable CGPoint array. Stationary taps/holds include position pulses at approximately 60 Hz. Drags have 30 movement samples followed by lift 1 ms after the requested movement duration. Scheduling uses absolute monotonic offsets and is not a real-time delivery guarantee. The C boundary independently checks sample counts, finite normalized coordinates, increasing times and complete down/move/up phases before opening a connection. On an ordinary connection error it attempts lift at the last attempted position, then checks a completion barrier. No movement is replayed and no alternate backend runs.

On the USB iPhone 13 mini, direct tap opened Settings, drag moved the Settings list, and a 0.8-second hold opened Maps' Home Screen context menu. Other orientations/families, system edge gestures, interruption/crash release and simultaneous independent controllers remain unverified. Dispatch receipts retain `verified: false` and `releaseVerified: false`; the readiness/completion barriers prove service/transport behavior, not UIKit delivery or release. See paired movement, timed schedules, named-key and paste sections below and [direct typing](PHYSICAL-TYPING.md#current-direct-implementation).

## Direct two-contact movement

Physical `pinch` and two-path `multi-drag` use the in-process Apple Indigo digitizer service by default or with explicit coredevice selection. Three-to-five-path `multi-drag` uses the direct Universal HID schedule engine, with 30 movement samples and release 1 ms after the requested movement duration. Standalone `multi-tap` presses two to five contacts together and releases after 80 ms through Universal HID. Pinch derives two horizontal paths from normalized current-interface center and positive start/end spans. Smaller final span pinches inward; larger spreads outward. All endpoints must fit. Movement duration remains 0.03...10 seconds.

The paired schedule retains both points in each of 32 events: simultaneous down, 30 movement samples and simultaneous lift 1 ms after the requested movement interval. Each point is independently rotated into portrait digitizer coordinates. The Apple `IndigoDigitizerEvent` payload adds the optional custom `pointTwo` dictionary alongside `pointOne`; slot order stays fixed. On ordinary failure, lift includes both last-attempted positions. Swift rejects paths whose continuous linear trajectories coincide or cross, even between samples. The C boundary independently rejects nonfinite, out-of-range or coincident second points before opening a connection. Display readiness/recheck, transport barriers, deadlines and no-replay behavior are shared with single-contact input.

Direct pinch/spread has **scoped hardware verification** on the USB iPhone 13 mini: CLI spread zoomed Maps in, and a real MCP inward pinch visibly zoomed it out. The earlier location prompt was absent on a fresh screenshot before testing; the tool made no permission selection. General independent multi-drag paths and failure release remain hardware-unverified. `mise run test:mcp-pinch <UDID> <center-x> <center-y> <start-span> <end-span> <seconds>` runs one explicit live MCP gesture and saves its receipt and screenshot. Historical helper verification below remains separate from these direct results.

## Direct timed schedules

`physical <device> gesture <JSON>` and MCP `perform_gesture` now use the project's in-process Apple Universal HID backend, with one to five slots, independent arrival/lift and repeated strokes. The same complete-state report encoder is shared with historical native schedules, but no helper is launched. Fresh display validation rotates current-interface coordinates before encoding. Apple `connectedServices` discovery must identify exactly one touchscreen; its service ID is used for all reports in the owned session. Readiness/completion barriers and strict C report prevalidation apply. See [direct schedule semantics and limits](GESTURE-SEQUENCES.md#current-direct-implementation).

A direct MCP sampled swipe visibly moved Home to App Library, and direct CLI repeated taps visibly zoomed Maps on the USB iPhone 13 mini. Standalone `multi-tap` and three-to-five-path `multi-drag` now share this direct schedule engine. Five-slot encoding has local tests; broad multi-contact effects and failure/interruption release remain hardware-unverified. This does not complete general multitouch verification or ownership/cancellation requirements.

## Direct named keyboard keys

`physical <device> key <name>` and MCP `press_key` default to the in-process backend. Supported names are `return`, `escape`, `backspace`, `tab`, `space`, `right`, `left`, `down`, and `up`. They map to HID usages 40...44 and 79...82. Swift checks fresh identity/readiness before dispatch; the C boundary rejects unsupported usages before framework access. Existing per-device human-handoff pause applies.

The bridge opens the registered Apple button feature with service name `com.apple.coredevice.hid.indigo`. Keyboard messages carry feature `com.apple.coredevice.feature.remote.hid.keyboard` and message type `IndigoKeyboardButtonEvent`, with unsigned `usageCode` and down/up `state`. A readiness barrier precedes the single down/up pair, separated by 80 ms; a completion barrier follows. Named keys use current focus without focusing a field, modifying the clipboard, or replaying failed input. Unicode paste has the separate behavior below; [typing](PHYSICAL-TYPING.md#current-direct-implementation) shares the same keyboard transport with a bounded text schedule.

Backspace has scoped visual verification in Settings search on the USB iPhone 13 mini. Other named keys, field types, layouts, Wi-Fi, other Apple families and interrupted release remain hardware-unverified. Receipts retain `verified: false` and `releaseVerified: false`; barriers alone cannot verify deletion or release. `mise run test:mcp-key <UDID> <key>` sends one explicit key at current focus and saves before/after screenshots and a receipt for independent inspection.

## Direct Unicode paste

For clipboard-free US-layout ASCII entry, use the separate [direct physical typing operation](PHYSICAL-TYPING.md#current-direct-implementation). Its layout/focus restrictions differ from paste.

CLI `physical <device> paste <text>` and MCP `paste_text` use Apple's installed `devicectl device pasteboard copy`, followed by the project's in-process Indigo keyboard sequence. No separate project or third-party executable is launched. The Objective-C bridge is linked into `appledevicescmd`; it is not a helper process.

Paste accepts 1...65536 UTF-8 bytes without NUL. Fresh target identity and Developer Mode checks precede the clipboard write. Text passes through private file-backed stdin, removed after the Apple subprocess exits, rather than a child argument or shell interpolation. A confirmed Apple copy is followed by Left Command down, V down/up and Left Command up over 160 ms, with readiness/completion barriers. The C boundary validates bounded timing, supported usages, balanced transitions and complete release before any keyboard connection. Ordinary connection failure attempts release of outstanding keys, without replaying input. Timing, UI effect and release are not guaranteed by the transport receipt.

**This replaces the phone clipboard and does not restore it.** It uses current focus/selection, without focusing, selecting all, submitting, or approving paste permissions. A failed/unconfirmed copy sends no paste keys and reports uncertain clipboard state. Failure/cancellation after confirmed copy reports the clipboard replacement and unknown insertion/release. Successful receipts retain `verified: false`, `insertionVerified: false` and `releaseVerified: false`.

Synthetic accented text, emoji and CJK insertion has scoped verification in Settings search on the USB iPhone 13 mini after the user authorized Allow Paste. An iOS prompt can remain after CLI/MCP dispatch completes; inspect the screen. `mise run test:mcp-paste <UDID> <synthetic-text>` saves before/after screenshots and a receipt, without handling prompts. Other fields, permission states, Apple families and failure/interruption release remain unverified. Clipboard-free typing has separate US-layout limits.

Both process runners continue to reject non-Apple device executables. The documentation below is retained as a **historical implementation reference**, not current execution instructions.

## Historical helper implementation (disabled)

The optional native backend supports physical `button`, `tap`, `long-press`, timed `gesture`, `drag`, `swipe`, `multi-drag`, `pinch`, `key`, and Unicode `paste`. The default remains the experimental idevice backend; selection is explicit and a failed action never triggers an automatic retry or another backend.

```sh
mise run coredevice:build
mise run build
mise run cli --physical-backend coredevice physical <device> button home
mise run cli --physical-backend coredevice physical <device> tap 0.5 0.5
mise run cli --physical-backend coredevice physical <device> long-press 0.5 0.5 0.8
mise run cli --physical-backend coredevice physical <device> drag 0.5 0.4 0.5 0.8 0.5
mise run cli --physical-backend coredevice physical <device> pinch 0.5 0.4 0.2 0.6 0.5
mise run cli --physical-backend coredevice physical <device> key backspace
# Replaces the phone clipboard and pastes once into the already-focused field:
mise run cli --physical-backend coredevice physical <device> paste 'mañana 🚀 中'
```

For direct executable use, put `tmp/bin` on PATH. This backend requires the installed Apple CoreDevice, Mercury, and UniversalHID private frameworks. It was built and checked on macOS 27.2.1 / Xcode 27.2; it does not expand the main Swift executable's macOS deployment target. Private ABI changes can break the helper even if the Swift CLI still builds.

The helper is built from MIT-licensed [ipb](https://github.com/ipbtools/ipb) revision `8c227a10710dad479852aa0203de729fed57471b`. Mise keeps the unchanged pinned checkout under `tmp/ipb`, stages sources under `tmp/coredevice-source`, applies the repository's [multitouch patch](../Backends/CoreDevice/multitouch.patch), and builds under `tmp/coredevice-build`. The native executable is copied to `tmp/bin/appledevices-coredevice`. [The MIT notice](../ThirdParty/ipb-LICENSE.txt) is retained. The build uses the upstream Makefile/report-size check through xcsift; Make's exit status and executable check establish build success even when xcsift reports an incomplete log because Make emits no Xcode/SwiftPM completion marker. No upstream Python AX runtime, shell CLI wrapper, proprietary device-control tooling executable, XCTest runner, or phone helper app is used by this input path.

The Swift planner passes an argument array to `/usr/bin/env`, setting the installed Apple framework search path and quiet/wait options before executing the helper. It does not interpolate user input into shell code. Each query/helper subprocess has a 40-second host deadline. Timeout is an error and cannot establish whether the action already happened; process termination does not promise device-side rollback or key/contact release.

## Identity, discovery, and output

The CLI queries fresh CoreDevice details for the requested device, checks Developer Mode, and resolves the CoreDevice UUID required by the helper. A supplied UUID or hardware UDID must match the corresponding returned identity. Name aliases rely on CoreDevice's resolution and are restricted during pending handoff just like other physical mutations.

Touch input queries native HID descriptors and requires exactly one matching touchscreen and a valid service ID. There is no fixed-ID fallback. Coordinates remain normalized 0...1 with origin at the top left; drag duration is 0.03...10 seconds. `swipe` and `drag` both use coordinated point-to-point contact movement. Rotation and multiple-display behavior remain unverified.

Buttons are `home`, `lock`, `volume-up`, and `volume-down`. The helper sends down/up and a native barrier; `lock` uses a 0.4-second hold, the other buttons 0.08 seconds. Lock can toggle the side-button state and was not tested in this task. A barrier is a transport fence, not an assertion that the UI changed.

JSON receipts identify `backend: coredevice-ipb`, the requested device, resolved UUID, operation, and `verified: false`. Helper diagnostics go to stderr. Observing the result with a fresh screenshot or other app check is still required for each action. Existing handoff mutation pause applies. The native backend does not accept idevice pairing files, create trust, or initiate Wi-Fi pairing.

MCP `tap`, `drag`, `multi_drag`, `pinch`, `press_button`, and `press_key` accept optional `backend: coredevice`; omitting it preserves existing behavior. `paste_text` and `long_press` always use the native backend. The native path uses Apple's existing CoreDevice pairing/tunnel rather than the independent usbmuxd software tunnel.

## Long-press

`long-press <x> <y> <seconds>` holds a stationary touch for a requested 0.1...10 seconds, then releases. It reuses the pinned helper's existing `cd_uhid_long` operation: contact down, hold, contact release, and barrier. No new report encoder or native patch is needed. The Swift CLI validates and canonicalizes finite coordinates/duration before identity discovery or input. Application gesture thresholds vary; a short hold need not open a context menu.

MCP `long_press` accepts `device`, normalized `x`/`y`, and `seconds`. CLI use requires explicit `--physical-backend coredevice`; the default idevice path does not expose this operation. Developer Mode, identity matching, unique touchscreen discovery, dry-run, and handoff pause use the same native path as taps.

The receipt adds requested `holdSeconds`, `coordinateSpace: normalized-top-left`, and `releaseVerified: false`. It does not measure delivered timing or prove device-side release. A helper failure/timeout reports that UI effect and contact release are unknown; no replay is sent. The helper attempts release after an ordinary send failure, but a blocked framework call, transport loss, or process termination can interrupt it. The existing 40-second subprocess deadline applies.

## Moving multitouch

For sampled paths, holds, repeated taps, and independently arriving/lifting contacts, use the separate [timed gesture sequence](GESTURE-SEQUENCES.md) command and MCP `perform_gesture`. It uses the same report encoder and native transport, with a bounded complete-state schedule and release attempt on failure. Its broader contact patterns have separate verification limits.

Native `multi-drag` and `pinch` use the [shared gesture syntax and bounds](MULTITOUCH.md). Swift prepares an initial frame, 30 linear movement frames, and release with stable identities 0...4. The 58-byte mainTouchscreen layout follows the pinned idevice implementation; the native adapter wraps these bytes in ipb's Apple HIDReport representation. The helper validates all 32 frames before sending any contact, schedules movement against absolute monotonic offsets, then attempts release and a barrier. A send error stops movement and attempts release at the last attempted positions. Release failure prevents a successful helper exit. This is not a real-time delivery guarantee.

The outer 40-second subprocess deadline also applies here. Connection loss, blocked framework calls, or process termination can prevent release and barrier completion. The CLI never repeats a partial gesture automatically. `mise run coredevice:test` checks sender validation, failure cleanup, and release failure without a phone; Swift tests check contact encoding, interpolation, endpoints, and shared planner bounds.

## Keyboard and Unicode paste

`key` supports Return, Escape, Backspace, Tab, Space, and the four arrows using the lowercase names shown in CLI help. Each call discovers exactly one native keyboard, then sends one key press/release and barrier. Backspace was verified in a live field; other keys remain unverified on hardware.

`paste` accepts 1...65536 UTF-8 bytes without NUL, including Unicode, tab, and newline. It first resolves the device and discovers the keyboard. It then writes the supplied text to the device's general clipboard through the installed `devicectl device pasteboard copy` command, and sends one native Command+V sequence. Text reaches the pasteboard subprocess through private file-backed stdin under `tmp/`, removed when the process exits. It is not interpolated into a shell command or passed as a pasteboard child argument.

**This operation replaces the phone clipboard and does not restore it.** It pastes at the current caret/selection: it does not focus a field, select all, submit the field, or check its value. iOS may interpose an Allow Paste prompt. The CLI does not approve prompts or retry a pending insertion. Observe the focused field before deciding what to do next.

The JSON receipt adds `clipboard: replaced` and `insertionVerified: false`. If discovery fails, the clipboard is not written. If the copy command fails or does not confirm success, paste is not sent and the error reports that clipboard state may have changed. If dispatch fails after a confirmed copy, the error reports that the clipboard was replaced and insertion is unknown. No automatic retry occurs in either case. Dry runs show both copy and input phases, the byte count, and the clipboard effect without reading or changing the device. Existing `type`/`type_text` behavior is unchanged; see [idevice ASCII typing](PHYSICAL-TYPING.md).

## Physical verification

A native 0.8-second long-press at normalized `(0.38,0.12)` opened the Maps Home Screen icon context menu on the selected USB iPhone 13 mini. A screenshot confirmed the menu; Home dismissed it. A separate real MCP `long_press` call reopened the same menu, also confirmed by its captured PNG. No menu item was selected. This verifies that context-menu gesture on this phone, not exact timing, every app recognizer, rotated displays, or device-side release after failure.

Native two-contact spread through `pinch` and inward movement through `multi-drag` visibly zoomed Apple Maps in and out on the selected USB iPhone 13 mini. Screenshots confirmed both effects. Three-to-five-contact gestures, exact timing, and failure cleanup on hardware remain unverified. Maps first-run setup used Allow Once for location, Not Now for notification onboarding, and declined optional improvement data sharing. These were explicit test actions, not automatic permission handling in the tool.

With the user-selected iPhone 13 mini awake, unlocked, and UI Automation enabled, fresh screenshots showed native Home leaving Settings, native tap reopening Settings, and native drag scrolling its list. A later test focused Settings search and pasted the synthetic marker `mañana 🚀 中X`. After an explicit test tap allowed the visible paste prompt, a screenshot showed the exact marker. A native Backspace removed only the final `X`; a separate clear-field tap removed the marker afterward. The clipboard remained replaced with the test text. These checks verify the observed USB/CoreDevice operations, not all devices, transports, field types, orientations, or keyboard behavior.

The idevice path returned dispatch receipts but showed no visible Home or tap effects in these checks. Its root cause remains unresolved. An exploratory barrier read was removed because the pinned library's receive API filters empty dictionaries, preventing that test from observing the documented empty reply. That timeout did not prove a device refusal. See [verification records](VERIFICATION.md).
