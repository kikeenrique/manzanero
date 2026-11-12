# Native CoreDevice input backend

The optional native backend supports physical `button`, `tap`, `long-press`, `drag`, `swipe`, `multi-drag`, `pinch`, `key`, and Unicode `paste`. The default remains the experimental idevice backend; selection is explicit and a failed action never triggers an automatic retry or another backend.

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
