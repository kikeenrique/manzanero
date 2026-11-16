# Timed touch sequences

Use `gesture` when a linear drag or simultaneous multi-tap is insufficient: sampled curves, repeated strokes, stationary holds, and independently arriving/lifting contacts can be expressed in one complete-state schedule.

## Current direct implementation

CLI `gesture <JSON> --device <UDID>` and MCP `perform_gesture` use Apple's Universal HID service in process. No helper is required.

```sh
# Two taps at one point; inspect the target before sending this sequence.
manzanero gesture '{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]},{"ms":180,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":240,"touches":[]}]}' --device <UDID>
```

MCP takes `device` and `sequence`, where `sequence` is the same JSON string, and an optional `platform` (default physical).

A booted simulator takes the same sequence: `manzanero gesture '<JSON>' --simulator <UUID>`, or `perform_gesture` with `platform: simulator`. The frames, validation and 58-byte reports are the physical ones; they go to the simulator's `dtuhidd` Universal HID service and its primary display's touchscreen ([simulator input](simulator-input.md)). On one iPhone 17e simulator, a one-finger double tap and a two-contact sequence with staggered arrival and lift arrived as scheduled in 10 of 10 runs ([runner results](probe-touch-runner.md#simulator-runs)).

## Input contract

| Field or limit | Requirement |
| --- | --- |
| JSON | At most 65536 UTF-8 bytes |
| Frames | `2...512` |
| `ms` | Integer milliseconds; first is 0, then strictly increasing, last at or before 10000 |
| First/last state | First has at least one touch; last has `touches: []` |
| Contacts | Each frame lists every active contact as `{id,x,y}` |
| IDs | Unique within a frame, integers `0...4`; all used IDs form a contiguous set starting at zero |
| Coordinates | Finite normalized `0...1`, origin at the top left |

Omitting an active ID releases it at its last position. A released ID may be used again at a new position. Stable ID slots remain in the encoded report even when inactive.

Every supplied frame is sent at its requested offset. The host does not interpolate missing waypoints. App recognizers and OS scheduling determine the effect; millisecond offsets do not guarantee device delivery times.

## Validation and execution

The whole schedule is validated before querying the device. Fresh identity/Developer Mode and two matching awake-display observations precede dispatch. Coordinates are rotated into portrait digitizer space and encoded as 16-bit HID coordinates.

Native service discovery must find exactly one touchscreen with a nonzero surface ID. The C boundary independently validates the 58-byte complete-state reports, slots, contact flags, reserved fields, times and final all-up state before opening the dispatch path.

Absolute monotonic offsets avoid accumulating each sleep/send delay. Overdue frames may be sent late; the schedule is not restarted or automatically retried. Failure or cancellation stops future movement and attempts an all-up report at the last attempted positions, then a completion barrier. See [cancellation and signals](native-input.md#task-cancellation-and-release-attempts).

Receipts include counts, requested duration, display rotation and `coordinateSpace: normalized-current-interface`. `verified` and `releaseVerified` remain false. A dispatch error is not proof that nothing reached the device.

## Verification

On iPhone 13 mini, a sampled swipe moved Home to App Library, repeated taps zoomed Maps, and a seven-frame two-contact spread with staggered arrivals/lifts visibly zoomed Maps. These establish scoped effects, not delivered timestamps or every individual contact transition.

Five-slot encoding and independent contact timing have local test coverage. Three-to-five-contact recognition, failure release, other orientations/devices and general unattended behavior remain hardware-unverified.

```sh
mise run test:mcp-gesture <UDID> <local-sequence.json>
```

This opt-in test sends the supplied sequence, saves a receipt/screenshot and checks MCP shutdown. Inspect the image for the effect; the harness does not choose a target or approve prompts.

## Related commands and history

[Multitouch](multitouch.md) generates linear two-to-five-path schedules. Generated drags may release at 10001 ms to preserve a full ten-second movement interval; user-supplied JSON remains capped at 10000 ms.

The earlier patched-helper implementation is disabled. Its source is a migration reference, not required setup or proof of the current engine's hardware behavior.
