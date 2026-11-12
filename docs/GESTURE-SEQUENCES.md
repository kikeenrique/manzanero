# Timed physical touch sequences

The native backend accepts a finite schedule of complete contact states. This supports sampled curved paths, stationary holds, independently arriving/lifting fingers, and repeated taps within one helper connection.

```sh
# Two taps at the same normalized point; all four frames belong to one command:
mise run cli --physical-backend coredevice physical <device> gesture '{"frames":[{"ms":0,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":60,"touches":[]},{"ms":180,"touches":[{"id":0,"x":0.5,"y":0.4}]},{"ms":240,"touches":[]}]}'
```

MCP `perform_gesture` accepts `device` and `sequence`, a JSON string with the same shape. It always uses the [native CoreDevice backend](NATIVE-INPUT.md); the default idevice and simulator paths do not expose this operation. Existing linear [multi-drag and pinch](MULTITOUCH.md) remain available.

## Input contract

- JSON is limited to 65536 UTF-8 bytes and decoded with Foundation into `frames`.
- Supply 2...512 frames. Each frame has an integer `ms` and an array `touches` of `{id,x,y}` objects.
- The first frame must have `ms: 0` and at least one touch. Times must strictly increase; the last frame must be at or before 10000 ms and have `touches: []`.
- Each frame lists **all active contacts**. Omitting a previously active ID releases it at its last position. A released ID can become active again at a new position for another stroke or tap.
- IDs are integers 0...4, unique within a frame. Across the whole sequence, used IDs must form a contiguous set starting at zero. At most five contact slots are used.
- Coordinates are finite normalized 0...1 numbers with the origin at the top left. They are rounded to the existing 16-bit HID coordinate range; nothing is clipped.

Every supplied frame is sent at its requested offset. The host adds no intermediate path samples. Supply enough waypoints to express the desired path; the OS/app decides how to interpret movement and gesture thresholds. Integer milliseconds and host scheduling do not guarantee exact device delivery times.

## Dispatch and cleanup

The Swift adapter validates the whole sequence before identity lookup or input. It resolves a fresh matching CoreDevice identity, checks Developer Mode, discovers exactly one touchscreen, and builds reports using the same encoder as linear native multitouch. Each report retains a fixed set of identity slots; inactive contacts retain their last position with contact flags cleared.

The staged native extension independently validates every timestamp, frame, contact flag, inactive position, reserved field, and final all-up state before sending any contact. It reuses ipb's Apple HIDReport bridge. The pinned upstream checkout stays unchanged; [the repository patch](../Backends/CoreDevice/multitouch.patch) adds the sequence dispatch entry point.

Scheduling uses absolute offsets against a monotonic clock, avoiding accumulated sleep and send latency. Late frames are sent without restarting or replaying the sequence. A scheduling or send failure stops further planned frames and attempts an all-contact release at the last attempted positions, followed by a barrier. A final all-up cleanup report is also sent after ordinary completion. Cleanup errors prevent helper success. This is a bounded release attempt, not a guarantee that contacts were released after transport loss, blocked framework calls, or process termination. The existing 40-second per-helper host deadline applies.

Receipts identify `operation: gesture`, `frameCount`, `contactSlots`, requested `durationMilliseconds`, `coordinateSpace: normalized-top-left`, `verified: false`, and `releaseVerified: false`. A dispatch error reports unknown effect/release and is never automatically retried. Dry runs only show the plan. Existing human-handoff mutation pause applies.

## Verification

Swift tests cover schedule/size/frame/identity/coordinate bounds, contact arrivals/lifts, repeated IDs, shared report encoding, literal MCP routing, dry-run, no replay, and handoff pause. Standalone native tests inject a clock and transport to check absolute offsets, interrupted/failed waits, partial send failure, cleanup failure, complete prevalidation, and release at the last attempted position.

On the selected awake/unlocked USB iPhone 13 mini, a six-frame CLI path with changing x/y and nonuniform offsets moved Home to App Library. Screenshots confirmed the resulting navigation. This is evidence of that sampled gesture's effect, not exact physical trajectory or timing. Independently timed multi-contact effects, three-to-five-contact behavior, other apps/orientations, Wi-Fi, and device-side cleanup after failures remain unverified. See [verification records](VERIFICATION.md).

A real MCP four-frame sequence reused one contact for two taps at the same map point (down/up at 0/60 ms and 180/240 ms). From a clear full-map baseline, it visibly zoomed Maps while the search sheet stayed collapsed. Separate screenshots confirmed the zoom. An earlier run against a renewed location prompt supplied dispatch evidence only; the tool does not infer that its intended target is uncovered.

`mise run test:mcp-gesture <UDID> <file>` opts into one real MCP sequence read from a local JSON file. It captures the resulting screen and saves private artifacts beneath ignored `tmp/mcp-live-*/`. Its assertions check protocol/receipt/capture; inspect the PNG to verify the UI effect. It does not choose a target, approve prompts, or retry failed input.
