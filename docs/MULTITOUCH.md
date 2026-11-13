# Coordinated physical gestures

The Swift CLI supports simultaneous taps and linear movement of two to five contacts through in-process Apple APIs. No extra helper installation is required:

```sh
# Two contacts spread horizontally, over half a second:
appledevicescmd physical <UDID> multi-drag 0.5 0.25 0.5 0.1 0.5 0.75 0.5 0.9 0.5
# A spread expressed as center and full horizontal spans:
appledevicescmd physical <UDID> pinch 0.5 0.5 0.5 0.8 0.5
# Pinch inward by decreasing the end span:
appledevicescmd physical <UDID> pinch 0.5 0.5 0.8 0.5 0.5
# Explicit native CoreDevice backend:
mise run cli --physical-backend coredevice physical <device> pinch 0.5 0.4 0.2 0.6 0.5
```

`multi-drag` takes duration first, followed by two to five groups of `start-x start-y end-x end-y`. Every coordinate is normalized 0...1 with the origin at the top left. All paths start together, move linearly for the same duration, and release together. Each identity is included in every frame. Duration must be 0.03...10 seconds. A stationary path is allowed. For sampled curves or independently timed arrivals/lifts, use the native [gesture sequence](GESTURE-SEQUENCES.md) operation instead.

`pinch` takes `center-x center-y start-span end-span seconds`. Spans are full horizontal separations expressed as fractions of screen width. They must be positive, different, and fit on screen around the center. Smaller end spans pinch inward; larger ones spread outward. Both contacts must remain distinct and move after conversion to the backend's 16-bit coordinates. No coordinate clipping occurs. This generates a gesture; an app decides whether it zooms or handles it differently.

`multi-tap` takes two to five normalized `x y` pairs, presses all contacts together, and releases them after 80 ms. MCP exposes the same operation as `multi_tap` with a flat `coordinates` array. MCP `multi_drag` takes `device`, flat `paths` (four numbers per contact), and `seconds`; `pinch` takes `device`, `center_x`, `center_y`, `start_span`, `end_span`, and `seconds`. The default backend is direct CoreDevice; pairing files are unsupported and the idevice backend is disabled. A pending human handoff pauses these mutations within that server process.

## Backend and cleanup

The [direct CoreDevice backend](NATIVE-INPUT.md#moving-multitouch) keeps two-path movement on the previously verified Indigo implementation. It refuses overlapping/crossing two-path input. Three-to-five-path movement and all standalone multi-taps use the same in-process Universal HID engine as [complete-state gesture schedules](GESTURE-SEQUENCES.md). Swift validates the full schedule, checks the primary awake display twice, transforms current-interface coordinates, and discovers one touchscreen surface before dispatch. Movement has an initial frame, 30 linear samples including the exact endpoint at the requested duration, and release 1 ms later (at most 10,001 ms total). JSON gesture schedules retain their separate 10,000 ms bound.

Universal HID schedules use absolute monotonic offsets and finish with a barrier. Failure stops future movement and attempts release at the last attempted positions; connection loss, cancellation or process termination can interrupt cleanup. A receipt reports dispatch only and retains `verified: false` and `releaseVerified: false`.

## Historical helper implementations (disabled)

The former native backend used a patched ipb helper. The Rust implementation below is also retained for research only; neither helper is a runtime backend.

The Rust bridge uses `UniversalHidServiceClient.send_multitouch` from the [pinned idevice source](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/core_device/hid.rs). The library encodes 58-byte mainTouchscreen reports, with identities 0...4 and a release flag for each contact. Its contract requires all active contacts in every frame and explicit release with the same identities. No proprietary binary is used.

The bridge sends an initial contact frame, 30 coordinated movement frames, and a release frame. Movement uses absolute monotonic offsets over the requested duration. Scheduling and transport latency affect actual delivery; this is not a real-time timing guarantee. Dispatch has an internal deadline of duration plus five seconds. After normal completion, a send failure, or that deadline, the bridge attempts to release every contact at its last attempted position, with a three-second cleanup deadline. A failed send may already have reached the phone. Release failure prevents a success receipt and preserves any dispatch error.

The existing display-stream authentication setup and teardown still apply. The overall 60-second backend deadline, abrupt process termination, or connection loss can interrupt cleanup. No promise is made that a timed-out or killed process leaves the screen unchanged or contacts released. See [backend setup and stream limits](DEPENDENCIES.md).

## Verification limits

On 2026-11-13, a standalone two-contact `multi_tap` through real MCP visibly zoomed Maps out on the USB iPhone 13 mini. Three-path `multi_drag` through MCP and five-path `multi-drag` through CLI completed direct dispatch/barriers. The three-path result showed a place card rather than proving the intended spread; the five-path screenshot also does not establish independent tracking of all contacts. Treat these as transport checks, not proof of three/five-contact gesture recognition. Four-contact hardware behavior, timing and interruption cleanup remain unverified. No helper was built or invoked.

Current direct tests verify two-to-five-slot multi-tap encoding, rotation and balanced release, three-to-five-path interpolation at minimum/maximum durations, exact endpoints, strict timing, input rejection before device queries, and default direct routing. Historical helper tests do not establish direct runtime cleanup or hardware behavior.

On 2026-11-12, the native CoreDevice CLI's two-contact `pinch` spread visibly zoomed in Apple Maps on the awake/unlocked USB iPhone 13 mini. A subsequent inward two-contact `multi-drag` visibly zoomed out. Separate screenshots confirmed both effects, and Home returned to the Home Screen afterward. This establishes scoped two-contact native behavior; three-to-five-contact effects, exact delivery timing, device-side cleanup after failure, other apps/orientations, Wi-Fi, and the idevice backend's gesture effects remain unverified. Individual receipts retain `verified: false`. See [verification records](VERIFICATION.md).

Simulator pinch/moving multitouch is not implemented by these commands.
