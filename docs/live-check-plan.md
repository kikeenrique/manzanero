# Next live check plan

This page lists what still has to be run on hardware. It is a plan, not a record: results go in [verification](verification.md), and items are removed from here once they are recorded there. The [roadmap](roadmap.md#pending) puts these runs in order with the work that is not about hardware.

Done on the iPhone 13 mini so far: wake, the command service queue, the device lease across two processes, interruption, the accessibility tree, press, scroll and every wait condition except `focused`, touch delivery measured with the probe app (one to five contacts), keys and buttons, app lifecycle, files, reports, `build-run` with signing, native recording, `frames` in portrait, app console output and the last crash, system-prompt handling through the tree, the operation-first grammar, `set-value` and Spanish – ISO typing and detection in the probe's field, live MCP sessions, and on 2026-11-17 recording and `frames` after the bridge change, a killed `long-press` with quarantine, `set-value` in Settings, pipelined MCP calls and bounded `console` output. See [verification](verification.md).

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices`. If the display is off, `mise run cli wake --device <UDID>` turns it on. Take a screenshot before choosing where to touch, and inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

If every query to a connected device times out, capture the state of Apple's device services before restarting them: a wide `log stream` or `log show` window for `CoreDeviceService` and `remotepairingd`, and a `sample` of each process (`mise run diagnose:device-services` saves all of it under `tmp/device-services/`). On 2026-11-16 restarting them fixed the hang, but nothing was captured first and the cause is unknown.

## Not yet run on hardware

- With the passcode now set on the test phone: `wake` and `readiness` after a restart before the first unlock, the passcode keypad in the tree, and whether setting or removing a passcode always drops the pairing (it did once: [record](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen)).
- `handoff` with an app's permission prompt (in an app the owner names) or the passcode gate of Settings › Face ID y código, (every terminal answer and an unlock are recorded), and `request_handoff` from an MCP host with form elicitation, with a mutation sent while it is pending. The terminal flow with a physical step is [recorded](verification.md#handoff-with-a-physical-step). The owner has to be present.
- `tree` and the selector commands refuse a phone in landscape ("requires portrait geometry"), seen after that handoff; touch, keys and captures in landscape on a phone are still unrun.
- A held `key` or `button` whose sender is killed, and a hold during which the cable or network path is lost rather than the process: a killed `long-press` ended by itself on the phone ([session](verification.md#phone-session-of-2026-11-17)), these did not run.
- `tree`, `wait`, `press` and `scroll` with a web page in front in Safari and in an app's own `WKWebView`; a page with frames. In Chrome the page's tree reads and `press` works ([record](verification.md#web-content-on-the-phone)); `scroll` did not run. Count how often the first read after a page load selects the browser instead of the page.
- `--index` on a simulator and through the MCP `index` field against a device; on the phone it ran from the CLI on a web form only ([record](verification.md#web-content-on-the-phone)).
- Setting the value of a SwiftUI field that has a label or identifier. A UIKit text field and a secure field in Settings ran; the Settings search field has neither label nor identifier and cannot be selected.
- `rtcp.negotiatedFeedback` in a second recording, to see whether `disabled` is constant.
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
- The 200 ms input drain on another device and with the Mac under load (on the iPhone 13 mini, 50 ms lost short gestures and 100 ms did not).
- An output above 64 KiB through `console` (a 1 KiB bound on 4.6 kB was kept correctly; the probe has no bulk trigger).

## Not yet run on Apple TV, Apple Watch or iPhone Duo hardware

Everything in [other families](other-families.md) has run on simulators only. On real devices nothing is known, including whether the commands apply at all:

- Duo: `displays`, `screenshot` with and without `--display`, `record --display`. `fold`, `unfold` and `hinge` are simulator-only (a physical device's hinge is moved by hand); on hardware, check what the display information reports in each fold state.
- Apple TV: every `remote` button against an app that reacts to play-pause, touch refused, focus in the tree, `wait --until focused`.
- Apple Watch: `crown` against a list and a crown-bound value (scale, one row per event), `button side`, and `button action` on an Apple Watch Ultra.

## Not yet run on simulators

These need no hardware and no owner decision; they were left out of the simulator runs.

- On the Duo's inner display: the centre-hit fallback when no frontmost application is reported, and four- and five-path `multi-drag` (three paths and `gesture` are [recorded](verification.md#the-duos-inner-display)); only the `rot90` orientation was seen.
- `fold` on the Duo with nothing else booted: one of five folds was not observed within its 10 s bound while three other simulators were running.
## Questions still open
- Why did one tap on the Settings search field have no effect, when the next 36 taps there did?
- What made Apple's device services stop answering for the phone on 2026-11-16?
- What do apps' gesture recognizers make of three or more contacts?
- Which keyboard type (ANSI or ISO) does a phone apply to Indigo keyboard events, and does a phone's iOS version ship the same layouts as the Mac?
- Was the firewall also behind the earlier intermittent recording startup failures?
- Why does a subscription stop sometimes go unconfirmed? Three of about thirty selector commands on 2026-11-17; each time the socket closed 2 to 3 ms into the stop exchange, after one cleanup frame.
- Does a phone keep a key or button held when the process sending it is killed? It ended a contact itself, as a simulator did.
- Does a web input ever take `set-value`, for example after it has focus?
- Would the phone accept an offer that asks for RTCP feedback? It negotiated `disabled` for the offer sent today.

## Stop conditions

Stop and record the state if an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else. A system prompt is no longer a reason to stop by itself: the tree shows it, and its buttons can be pressed by label, but deciding a permission is still the owner's call.
