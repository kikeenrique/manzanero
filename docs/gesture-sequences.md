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

Five-slot encoding and independent contact timing have local test coverage. The probe app's measurement runner sent its two timed sequences on that phone and they arrived as scheduled, within the built-in plan's 70 of 70 actions ([verification](verification.md#touch-delivery-measured-with-the-probe-app)). Three-to-five-contact recognition in apps, failure release, other orientations/devices and general unattended behavior remain hardware-unverified.

```sh
mise run test:mcp-gesture <UDID> <local-sequence.json>
```

This opt-in test sends the supplied sequence, saves a receipt/screenshot and checks MCP shutdown. Inspect the image for the effect; the harness does not choose a target or approve prompts.

## Presets

`double-tap <x> <y>` (MCP `double_tap`) is one sequence of two 60 ms taps 160 ms apart, on the same route as `gesture`, physical or simulator. On `manzanero-research-phone` on 2026-11-21 the probe counted two gestures of one contact each, 0.060 s and 0.061 s long. On the iPhone 13 mini the same evening the probe counted two gestures too, from the CLI and through MCP `double_tap` ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)).

System gestures are not presets. On the same simulator a swipe up from the bottom edge (from y 0.995, 0.999 and 1.0 to 0.6, 0.5 and 0.3, over 250 to 500 ms) never reached the system: over the probe, which keeps the screen edges for itself, the probe recorded the swipe, and over Settings the list scrolled and Settings stayed in front. So a touch sequence from this route is the app's, not SpringBoard's, on a simulator; Home is `button home`. Whether a phone's system takes such a sequence from its edge is not known.

## Holding a contact across steps

A `gesture` is computed before it is sent. When a later touch depends on what the screen shows after an earlier one, a precomputed plan can be wrong: on 2026-11-22 a gesture that held contact 0 in the probe while contact 1 opened Control Centre and tapped Wi-Fi tapped the wrong place twice. Two `batch` steps hold a contact instead, so each later step comes from a fresh look:

- `["hold","<x>","<y>"]` puts contact 0 down at normalized current-interface coordinates and keeps it down while the following steps run.
- `["release"]` lifts it. The end of the batch, a step that fails and an interrupt (SIGINT/SIGTERM, MCP cancellation) also release it. A batch that ends while holding is allowed; its receipt says so (`holdNote`, and `releasedBy: end-of-batch` in `holds`).

```sh
# Hold in the probe, open Control Centre, wait for Wi-Fi, press it, then lift.
manzanero batch --device <UDID> '[["hold","0.5","0.6"],["swipe","0.9","0.0","0.9","0.15","0.25"],["wait","--label","Wi-Fi","--until","visible"],["press","--label","Wi-Fi"],["release"]]'
```

Pressing in Control Centre by accessibility may also need the tool to act in that system process, which `press` does not do today (its `--pid` rules are unchanged); until then the `press` step there may be refused.

How it runs:

- The hold is one live Universal HID stream on one connection (`ADCPerformLiveDigitizerReports`, on a thread of its own). Contact 0's complete-state report is sent again every 250 ms while nothing else moves. The stream lasts at most ten minutes; past that it stops and releases like an interrupt.
- Touch steps inside a hold (`tap`, `double-tap`, `long-press`, `swipe`, `drag`, `pinch`, `multi-tap`, `multi-drag`, `gesture`) are not sent on their own: their frames, built by the same planners as when they run alone, join the stream as contacts 1 and up beside the held one. The digitizer takes five contacts, so a step inside a hold may use at most four. Each such step first reads the display again and is refused if it changed since the hold began.
- Accessibility steps (`tree`, `wait`, `press`, `scroll`, `set-value`), screenshots and captures run as usual; they do not use the digitizer.
- `button`, `key`, `type`, `paste` and `wake` are allowed inside a hold: they go to the button and keyboard usages on a connection of their own and carry no digitizer state, so they cannot lift the held contact. Whether a phone handles a button press with a contact held as expected has not been tried.
- The device lease is taken at `hold` and kept until the release; the handoff pause applies to `hold` and to every step inside it, and the batch runs under the signal scope.
- Outcomes follow other input: a connection that fails, a barrier that is not confirmed or an interrupt while holding is `input-outcome-unknown`, and the device is quarantined. A step that fails for another reason ends the batch and the hold is released normally.

Refused when the batch is built, before anything runs: `hold` while a hold is down, `release` without a hold, a touch step of five contacts inside a hold, `hold` on a simulator (`unsupported-operation`: the simulator's digitizer path has no live stream in this tool yet), and `hold` or `release` on their own outside a batch. MCP has no tool of their own; `run_batch` takes them as steps. `--dry-run` prints every step's plan and, under `holds`, each hold's stream: its contacts per report, the steps inside it and the steps merged into it.

Built and covered by unit tests (the live scheduler with a local sink, merged contacts, refreshes, release on end, stop and transport failure); not yet run on a device ([live checks](live-check-plan.md)).

## Related commands and history

[Multitouch](multitouch.md) generates linear two-to-five-path schedules. Generated drags may release at 10001 ms to preserve a full ten-second movement interval; user-supplied JSON remains capped at 10000 ms.

The earlier patched-helper implementation has been removed (git history keeps it). Its results are not proof of the current engine's hardware behavior.
