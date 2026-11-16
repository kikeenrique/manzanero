# Next live check plan

This page lists what still has to be run on a physical iPhone. It is a plan, not a record: results go in [verification](verification.md), and steps are removed from here once they are recorded there.

Done so far on the iPhone 13 mini: the guarded wake, the command service queue, the device lease across two processes, interruption, the accessibility wait, native recording (after a firewall rule), a wide run of the input, app and report commands, and touch delivery measured with the probe app. See [verification](verification.md).

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices physical`. If the display is off, `mise run cli physical <UDID> wake` turns it on. Take a screenshot before choosing where to touch, and inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

## Not yet run on hardware

- `uninstall`, and `files` and `push` against a real app container (`install`, through `build-run`, and `pull` have run).
- `handoff` with a real prompt, and the `disabled` and `value` wait conditions.
- `wake_device`, `wait_for_element`, the inline image options and the JSON error object through a live MCP session.
- Buttons and keys measured after the connection-drain fix; only touch was measured.
- App console output and the last crash on the phone: `physical <UDID> console` with the probe app's log probe, and `last-crash` after `-probeCrash abort` (see [app logs](app-logs.md); the probe now prints known lines).
- Landscape, an iPad, and anything on a second device.

## Questions still open

- How short can the 400 ms connection drain be before short gestures are lost again? It is a margin, not a measured minimum, and it adds to every input call.
- Does the container hit test also select the right process when a system prompt is showing?
- What do apps' gesture recognizers make of three or more contacts?
- Was the firewall also behind the earlier intermittent recording startup failures?
- What makes the pairing daemon's browse occasionally fail to select the device? The error now names the cause; it has not recurred.
- Why did one wait report its subscription stop as unconfirmed?

## Stop conditions

Stop and record the state if a system prompt appears, an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else.
