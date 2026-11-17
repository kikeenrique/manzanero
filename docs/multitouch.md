# Coordinated contacts and pinch

`multi-tap`, `multi-drag` and `pinch` generate simple physical multi-contact schedules. They use in-process Apple APIs by default, with no helper installation.

## Commands

```sh
# Two simultaneous taps:
manzanero multi-tap 0.25 0.5 0.75 0.5 --device <UDID>

# Two paths moving apart over half a second:
manzanero multi-drag 0.5 0.25 0.5 0.1 0.5 0.75 0.5 0.9 0.5 --device <UDID>

# Horizontal spread, then inward pinch:
manzanero pinch 0.5 0.5 0.5 0.8 0.5 --device <UDID>
manzanero pinch 0.5 0.5 0.8 0.5 0.5 --device <UDID>
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

`platform` is optional and defaults to physical, which uses the in-process CoreDevice route. With `platform: simulator` and a booted simulator's UUID, the same schedules go to the simulator's `dtuhidd`: `pinch` and two-path `multi_drag` to its digitizer service, `multi_tap` and three-to-five-path `multi_drag` to its Universal HID service ([simulator input](simulator-input.md)). The CLI form is `manzanero multi-tap|multi-drag|pinch … --simulator <UUID>`. A pending handoff pauses mutations for that device within the same server process.

## What has been verified

Two-contact spread and inward movement visibly zoomed Maps on iPhone 13 mini; a direct MCP simultaneous multi-tap also changed Maps zoom. With the [probe app](probe-app.md) on that phone, two-, three-, four- and five-contact actions each arrived as that many simultaneous contacts (part of the 70 of 70 built-in-plan actions in [verification](verification.md#touch-delivery-measured-with-the-probe-app)). That measures delivery to a UIKit view; what an app's gesture recognizers make of three or more contacts is not established.

On one iPhone 17e simulator the probe app recorded every two-contact pinch and two-path drag as two simultaneous contacts (20 of 20 over five rounds), and every three-, four- and five-contact multi-tap and three-path drag as that many simultaneous contacts (20 of 20 over five rounds of the built-in plan) ([runner results](probe-touch-runner.md#simulator-runs)).

Local tests cover two-to-five-slot encoding, rotation, interpolation, endpoint/timing bounds and input rejection before device queries. Broad gesture semantics, release after a hardware failure (the Mac [quarantines](native-input.md#quarantine-after-an-uncertain-release) the device; nothing is released on it), other apps, landscape on a phone and other Apple families' hardware remain unverified.

Earlier ipb/idevice implementations have been removed (git history keeps them). Their tests and receipts do not establish behavior of the current direct backend.
