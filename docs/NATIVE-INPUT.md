# Native CoreDevice input backend

The optional native backend currently supports physical `button`, `tap`, `drag`, and `swipe`. The default remains the experimental idevice backend; selection is explicit and a failed action never triggers an automatic retry or another backend.

```sh
mise run coredevice:build
mise run build
mise run cli --physical-backend coredevice physical <device> button home
mise run cli --physical-backend coredevice physical <device> tap 0.5 0.5
mise run cli --physical-backend coredevice physical <device> drag 0.5 0.4 0.5 0.8 0.5
```

For direct executable use, put `tmp/bin` on PATH. This backend requires the installed Apple CoreDevice, Mercury, and UniversalHID private frameworks. It was built and checked on macOS 27.2.1 / Xcode 27.2; it does not expand the main Swift executable's macOS deployment target. Private ABI changes can break the helper even if the Swift CLI still builds.

The helper is built from MIT-licensed [ipb](https://github.com/ipbtools/ipb) revision `8c227a10710dad479852aa0203de729fed57471b`. Mise keeps its checkout/build under `tmp/ipb`, checks the exact revision and tracked source changes, and copies the native executable to `tmp/bin/appledevices-coredevice`. [The MIT notice](../ThirdParty/ipb-LICENSE.txt) is retained. The build uses the upstream Makefile/report-size check through xcsift; Make's exit status and executable check establish build success even when xcsift reports an incomplete log because Make emits no Xcode/SwiftPM completion marker. No upstream Python AX runtime, shell CLI wrapper, proprietary device-control tooling executable, XCTest runner, or phone helper app is used by this input path.

The Swift planner passes an argument array to `/usr/bin/env`, setting the installed Apple framework search path and quiet/wait options before executing the helper. It does not interpolate user input into shell code. Each query/helper subprocess has a 40-second host deadline. Timeout is an error and cannot establish whether the action already happened; process termination does not promise device-side rollback or key/contact release.

## Identity, discovery, and output

The CLI queries fresh CoreDevice details for the requested device, checks Developer Mode, and resolves the CoreDevice UUID required by the helper. A supplied UUID or hardware UDID must match the corresponding returned identity. Name aliases rely on CoreDevice's resolution and are restricted during pending handoff just like other physical mutations.

Touch input queries native HID descriptors and requires exactly one matching touchscreen and a valid service ID. There is no fixed-ID fallback. Coordinates remain normalized 0...1 with origin at the top left; duration remains 0.03...10 seconds. `swipe` and `drag` both use coordinated point-to-point contact movement. Rotation and multiple-display behavior remain unverified.

Buttons are `home`, `lock`, `volume-up`, and `volume-down`. The helper sends down/up and a native barrier; `lock` uses a 0.4-second hold, the other buttons 0.08 seconds. Lock can toggle the side-button state and was not tested in this task. A barrier is a transport fence, not an assertion that the UI changed.

JSON receipts identify `backend: coredevice-ipb`, the requested device, resolved UUID, operation, and `verified: false`. Helper diagnostics go to stderr. Observing the result with a fresh screenshot or other app check is still required for each action. Existing handoff mutation pause applies. The native backend does not accept idevice pairing files, create trust, or initiate Wi-Fi pairing.

MCP `tap`, `drag`, and `press_button` accept optional `backend: coredevice`; omitting it preserves existing behavior. Other input tools retain their current backends. Native text, keys, moving multitouch, and pinch are not exposed by this adapter yet. The native path uses Apple's existing CoreDevice pairing/tunnel rather than the independent usbmuxd software tunnel.

## Physical verification

With the user-selected iPhone 13 mini awake, unlocked, and UI Automation enabled, fresh screenshots showed native Home leaving Settings, native tap reopening Settings, and native drag scrolling its list. The integrated Swift CLI was used for tap, drag, and a subsequent Home press. No setting was toggled, app installed, clipboard changed, or text entered. This verifies those operations over the observed USB/CoreDevice connection, not all devices, transports, orientations, buttons, or typing.

The idevice path returned dispatch receipts but showed no visible Home or tap effects in these checks. Its root cause remains unresolved. An exploratory barrier read was removed because the pinned library's receive API filters empty dictionaries, preventing that test from observing the documented empty reply. That timeout did not prove a device refusal. See [verification records](VERIFICATION.md).
