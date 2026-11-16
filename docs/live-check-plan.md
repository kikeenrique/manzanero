# Next live check plan

This page lists what still has to be run on a physical device. It is a plan, not a record: results go in [verification](verification.md), and items are removed from here once they are recorded there.

Done on the iPhone 13 mini so far: wake, the command service queue, the device lease, interruption, the accessibility tree, press, scroll and every wait condition, touch delivery measured with the probe app, keys and buttons, app lifecycle, files, reports, `build-run` with signing, native recording, `frames` in portrait, app console output and the last crash, system-prompt handling through the tree, and a live MCP session. See [verification](verification.md).

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices`. If the display is off, `mise run cli wake --device <UDID>` turns it on. Take a screenshot before choosing where to touch, and inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

If every query to a connected device times out, capture the state of Apple's device services before restarting them: a wide `log stream` or `log show` window for `CoreDeviceService` and `remotepairingd`, and a `sample` of each process. On 2026-11-16 restarting them fixed the hang, but nothing was captured first and the cause is unknown.

## Not yet run on hardware

- `handoff` with a real prompt. Wait for the owner to say when.
- Setting an element's value in apps other than the probe (SwiftUI, secure, search and web fields), and through the MCP tool.
- `frames` with the display rotated, on another device, for a long run (minutes, toward the 1000-frame and 1 GiB limits), and with a second process trying to capture or send input meanwhile. Portrait runs on the iPhone 13 mini are [recorded](verification.md#frames-on-the-phone).
- `detect-layout` on another phone or with another layout set on this one (it found Spanish – ISO on the iPhone 13 mini: [verification](verification.md#layout-detection)), in a field other than the probe's (one with autocorrection or auto-capitalisation on, to see `no-match` and the hints), and through MCP against a phone.
- Typing in keyboard layouts other than Spanish – ISO, which the iPhone 13 mini uses on its own and which typed exactly ([verification](verification.md#keyboard-layouts-on-the-phone)). The runs below remain for other layouts, each needing the phone's layout changed by hand ([physical typing](physical-typing.md#layouts); simulator results in [verification](verification.md#keyboard-layouts-on-the-simulator)). The phone's layout cannot be read, so set it by hand first in Settings › General › Keyboard › Hardware Keyboard (if that section appears without a real keyboard attached, which is itself unknown), then confirm it with `detect-layout --id probe.text.field --device <UDID>`, and focus `probe.text.field` (`set-value --id probe.text.field x --device <UDID>`, `key backspace`). Read the result from `probe.text.value` in `tree`. Suggested runs, each with its own layout set on the phone:
  - `type 'Ab9!z;[ ~"<>? mañana café über ß €' --device <UDID>` with the phone on US: US ASCII plus Option dead keys, which were only seen on a simulator.
  - `type --layout spanish-iso 'Año Ñandú ¿Qué? ¡Sí! €5 ç <º> @#' --device <UDID>`.
  - `type --layout german 'Grüße, Straße! @ € ê ÄÖÜ y<z>' --device <UDID>`.
  - `type --layout latin-american '<>≤ |°¬' --device <UDID>`, or another of the 13 layouts whose key left of 1 and key left of Z differ between the ISO and ANSI keyboard types: the simulator used ISO; whether a phone's Indigo keyboard does is the main open question.
  - The same once through MCP: `mise run test:mcp-type <UDID> 'Año ¿qué?' spanish-iso`.
  - Record whether Settings shows a Hardware Keyboard section while nothing but Manzanero's events have been sent, and whether the layout chosen there changes the result without relaunching the app.
- Landscape on a phone, an iPad, and anything on a second device. The simulator side of rotation and iPad is measured.
- Debug-level log lines and a large output through `console`.

## Not yet run on Apple TV, Apple Watch or iPhone Duo hardware

Everything in [other families](other-families.md) has run on simulators only. On real devices nothing is known, including whether the commands apply at all:

- Duo: `displays`, `screenshot` with and without `--display`, `record --display`. `fold`, `unfold` and `hinge` are simulator-only (a physical device's hinge is moved by hand); on hardware, check what the display information reports in each fold state.
- Apple TV: every `remote` button against an app that reacts to play-pause, touch refused, focus in the tree, `wait --until focused`.
- Apple Watch: `crown` against a list and a crown-bound value (scale, one row per event), and `button side`.

## Questions still open

- On the Duo simulator's inner display: `gesture`, three-to-five-path `multi-drag`, and the centre-hit fallback when no frontmost application is reported were not run; only the `rot90` orientation was seen.
- Does the per-device [MCP call order](mcp.md#calls-sent-without-waiting) hold for pipelined `fold_device` and `set_hinge_angle` on the Duo, and for a physical device? Checked so far on `iPhone 17e` with taps, a long press and trees only.

- Does the 200 ms connection drain hold on other devices and under load? On the iPhone 13 mini, 50 ms lost short gestures and 100 ms did not.
- Why did one tap on the Settings search field have no effect, when the next 36 taps there did?
- What made Apple's device services stop answering for the phone on 2026-11-16?
- What do apps' gesture recognizers make of three or more contacts?
- Which keyboard type (ANSI or ISO) does a phone apply to Indigo keyboard events, and does a phone's iOS version ship the same layouts as the Mac?
- Was the firewall also behind the earlier intermittent recording startup failures?
- Why did one wait report its subscription stop as unconfirmed?

## Stop conditions

Stop and record the state if an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else. A system prompt is no longer a reason to stop by itself: the tree shows it, and its buttons can be pressed by label, but deciding a permission is still the owner's call.
