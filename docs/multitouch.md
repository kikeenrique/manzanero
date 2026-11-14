# Coordinated contacts and pinch

`multi-tap`, `multi-drag` and `pinch` generate simple physical multi-contact schedules. They use in-process Apple APIs by default, with no helper installation.

## Commands

```sh
# Two simultaneous taps:
manzanero physical <UDID> multi-tap 0.25 0.5 0.75 0.5

# Two paths moving apart over half a second:
manzanero physical <UDID> multi-drag 0.5 0.25 0.5 0.1 0.5 0.75 0.5 0.9 0.5

# Horizontal spread, then inward pinch:
manzanero physical <UDID> pinch 0.5 0.5 0.5 0.8 0.5
manzanero physical <UDID> pinch 0.5 0.5 0.8 0.5 0.5
```

All coordinates are normalized `0...1`, origin at the top left. Inspect fresh state before selecting them.

| Operation | Arguments and behavior |
| --- | --- |
| `multi-tap` | Two to five `x y` pairs; contacts press together and release after 80 ms |
| `multi-drag` | Seconds, then two to five groups of `start-x start-y end-x end-y`; all paths start/move/release together |
| `pinch` | `center-x center-y start-span end-span seconds`; generates two horizontal paths |

Movement accepts `0.03...10` seconds. A stationary multi-drag path is allowed. Pinch spans are full horizontal separations as fractions of screen width: positive, different and fully on screen around the centre. Pinch contacts must remain distinct after coordinate encoding. The two-path Indigo route also rejects crossing/coincident paths; Universal HID schedules require unique contact IDs rather than distinct coordinates. Coordinates are never clipped.

For curves, repeated strokes or independently timed contacts, use [complete-state gesture sequences](gesture-sequences.md).

## Execution and output

Two-path movement uses the Indigo digitizer route and rejects paths that coincide or cross, including between samples. Three-to-five-path movement and standalone multi-taps use Universal HID.

Fresh identity, awake display checks and service discovery precede input. Movement includes an initial contact frame, 30 linear samples and release 1 ms after the requested movement duration. Generated schedules therefore allow 10001 ms total; user JSON has a separate 10000 ms bound.

Receipts report dispatch, not application recognition: `verified: false` and `releaseVerified: false`. Cancellation/failure stops later movement and attempts release at the last attempted positions. [Input lifecycle limits](native-input.md) still apply.

## MCP mapping

- `multi_tap`: flat `coordinates` array, two numbers per contact.
- `multi_drag`: flat `paths` array, four numbers per contact, plus `seconds`.
- `pinch`: `center_x`, `center_y`, `start_span`, `end_span`, `seconds`.

Use a physical `device`; optional `backend: coredevice` selects the existing default. Pairing files and simulator moving multitouch are unsupported. A pending handoff pauses mutations for that device within the same server process.

## What has been verified

Two-contact spread and inward movement visibly zoomed Maps on iPhone 13 mini; a direct MCP simultaneous multi-tap also changed Maps zoom. Three- and five-path calls completed dispatch/barriers, but their screenshots did not establish independent tracking or the intended gesture. Four-contact effects remain unverified.

Local tests cover two-to-five-slot encoding, rotation, interpolation, endpoint/timing bounds and input rejection before device queries. Exact delivered timing, broad gesture semantics, hardware failure release, other apps/orientations and other Apple families remain unverified.

Earlier ipb/idevice implementations are disabled research references. Their tests and receipts do not establish behavior of the current direct backend.
