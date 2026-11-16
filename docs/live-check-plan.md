# Next live check plan

This page lists what still has to be run on a physical device. It is a plan, not a record: results go in [verification](verification.md), and items are removed from here once they are recorded there.

Done on the iPhone 13 mini so far: wake, the command service queue, the device lease, interruption, the accessibility tree, press, scroll and every wait condition, touch delivery measured with the probe app, keys and buttons, app lifecycle, files, reports, `build-run` with signing, native recording, app console output and the last crash, system-prompt handling through the tree, and a live MCP session. See [verification](verification.md).

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices`. If the display is off, `mise run cli wake --device <UDID>` turns it on. Take a screenshot before choosing where to touch, and inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

If every query to a connected device times out, capture the state of Apple's device services before restarting them: a wide `log stream` or `log show` window for `CoreDeviceService` and `remotepairingd`, and a `sample` of each process. On 2026-11-16 restarting them fixed the hang, but nothing was captured first and the cause is unknown.

## Not yet run on hardware

- `handoff` with a real prompt. Wait for the owner to say when.
- Setting an element's value on a phone. It is refused there today; the owner wants it enabled, which needs a small change first (see [simulator input](simulator-input.md)).
- The bridge's decoded-JPEG video mode. The owner wants it kept and tested; no command reaches it yet.
- Typing with a keyboard layout other than the US one, once `type` supports it.
- Landscape on a phone, an iPad, and anything on a second device. The simulator side of rotation and iPad is measured.
- Debug-level log lines and a large output through `console`.

## Questions still open

- Does the 200 ms connection drain hold on other devices and under load? On the iPhone 13 mini, 50 ms lost short gestures and 100 ms did not.
- Why did one tap on the Settings search field have no effect, when the next 36 taps there did?
- What made Apple's device services stop answering for the phone on 2026-11-16?
- What do apps' gesture recognizers make of three or more contacts?
- Was the firewall also behind the earlier intermittent recording startup failures?
- Why did one wait report its subscription stop as unconfirmed?

## Stop conditions

Stop and record the state if an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else. A system prompt is no longer a reason to stop by itself: the tree shows it, and its buttons can be pressed by label, but deciding a permission is still the owner's call.
