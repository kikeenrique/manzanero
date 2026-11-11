# Coordinated physical gestures

With the optional idevice bridge installed, the Swift CLI supports linear movement of two to five contacts:

```sh
# Two contacts spread horizontally, over half a second:
appledevicescmd physical <UDID> multi-drag 0.5 0.25 0.5 0.1 0.5 0.75 0.5 0.9 0.5
# A spread expressed as center and full horizontal spans:
appledevicescmd physical <UDID> pinch 0.5 0.5 0.5 0.8 0.5
# Pinch inward by decreasing the end span:
appledevicescmd physical <UDID> pinch 0.5 0.5 0.8 0.5 0.5
```

`multi-drag` takes duration first, followed by two to five groups of `start-x start-y end-x end-y`. Every coordinate is normalized 0...1 with the origin at the top left. All paths start together, move linearly for the same duration, and release together. Each identity is included in every frame. Duration must be 0.03...10 seconds. A stationary path is allowed, but curved paths and independently timed finger lifts are not supported.

`pinch` takes `center-x center-y start-span end-span seconds`. Spans are full horizontal separations expressed as fractions of screen width. They must be positive, different, and fit on screen around the center. Smaller end spans pinch inward; larger ones spread outward. Both contacts must remain distinct and move after conversion to the backend's 16-bit coordinates. No coordinate clipping occurs. This generates a gesture; an app decides whether it zooms or handles it differently.

MCP exposes `multi_drag` (`device`, `paths`, `seconds`) and `pinch` (`device`, `center_x`, `center_y`, `start_span`, `end_span`, `seconds`). `paths` is a flat numeric array with four numbers per contact. Both accept an optional existing `pairing_file`. They use the same Swift planner and physical readiness preflight as the CLI. A pending human handoff pauses these mutations within that server process.

## Backend and cleanup

The Rust bridge uses `UniversalHidServiceClient.send_multitouch` from the [pinned idevice source](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/core_device/hid.rs). The library encodes 58-byte mainTouchscreen reports, with identities 0...4 and a release flag for each contact. Its contract requires all active contacts in every frame and explicit release with the same identities. No proprietary binary is used.

The bridge sends an initial contact frame, 30 coordinated movement frames, and a release frame. Movement uses absolute monotonic offsets over the requested duration. Scheduling and transport latency affect actual delivery; this is not a real-time timing guarantee. Dispatch has an internal deadline of duration plus five seconds. After normal completion, a send failure, or that deadline, the bridge attempts to release every contact at its last attempted position, with a three-second cleanup deadline. A failed send may already have reached the phone. Release failure prevents a success receipt and preserves any dispatch error.

The existing display-stream authentication setup and teardown still apply. The overall 60-second backend deadline, abrupt process termination, or connection loss can interrupt cleanup. No promise is made that a timed-out or killed process leaves the screen unchanged or contacts released. See [backend setup and stream limits](DEPENDENCIES.md).

## Verification limits

Synthetic tests verify Swift/MCP argument conversion, input bounds, bridge parsing, two-to-five-contact wire frames, stable identities, increasing/decreasing interpolation, exact endpoints, release attempts on errors/timeouts, and cleanup failure reporting. The bridge builds against the locked dependency. No gesture from this task was sent to hardware; physical effects, app zoom behavior, timing, and device-side release remain unverified. Simulator pinch/moving multitouch is not implemented by these commands; AXe's installed command help did not establish a coordinated multicontact API.
