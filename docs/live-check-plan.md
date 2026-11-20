# Next live check plan

This page lists what still has to be run on hardware. It is a plan, not a record: results go in [verification](verification.md), and items are removed from here once they are recorded there. The [roadmap](roadmap.md#pending) puts these runs in order with the work that is not about hardware.

Done on the iPhone 13 mini so far: wake, the command service queue, the device lease across two processes, interruption, the accessibility tree, press, scroll and every wait condition except `focused`, touch delivery measured with the probe app (one to five contacts), keys and buttons, app lifecycle, files, reports, `build-run` with signing, native recording, `frames` in portrait, app console output and the last crash, system-prompt handling through the tree, the operation-first grammar, `set-value` and Spanish – ISO typing and detection in the probe's field, live MCP sessions, and on 2026-11-17 recording and `frames` after the bridge change, a killed `long-press` with quarantine, `set-value` in Settings, pipelined MCP calls, bounded `console` output, a web page in Chrome read and filled with `--index`, `wake` and the lock screen with a passcode, and `handoff` at a terminal, from an MCP host and watching the device; and that night and on 2026-11-18 the last handoff runs with the owner, a screenshot of the sleeping phone, a recording whose offer asked for RTCP feedback, and a bounded read of the log relay. Done on one Apple TV 4K on 2026-11-18: `readiness`, `screenshot`, `screen`, trees with focus, focus waits, `press`, `set-value`, `type`, every `remote` button against the tvOS probe, and sleep. See [verification](verification.md).

The test phone has had a passcode since the evening of 2026-11-17 and its default browser is Safari; before that it had no passcode and links opened in Chrome. Most records were made without a passcode.

Run from the repository root with the device paired and unlocked. Replace `<UDID>` with the hardware UDID from `mise run cli devices`. If the display is off, `mise run cli wake --device <UDID>` turns it on. Take a screenshot before choosing where to touch, and inspect the screen after every action; a receipt is not an effect. Do not replay an input automatically.

If every query to a connected device times out, read the state of Apple's device services before restarting them: a wide `log stream` or `log show` window for `CoreDeviceService` and `remotepairingd`, and a `sample` of each process (`mise run diagnose:device-services` collects them), and write what they show into [verification](verification.md). On 2026-11-16 restarting them fixed the hang, but nothing was read first and the cause is unknown.

## Not yet run on hardware

- With the passcode now set on the test phone: `wake` and `readiness` after a restart before the first unlock, and whether setting or removing a passcode always drops the pairing (it did once: [record](verification.md#a-passcode-on-the-phone-pairing-handoff-and-the-lock-screen)). The passcode keypad is in the tree ([record](verification.md#the-last-handoff-runs-on-the-phone)).
- `handoff` is finished on this phone and host ([record](verification.md#the-last-handoff-runs-on-the-phone)). What would need other equipment: a second MCP host, and a real Face ID or purchase prompt (the phone has no Face ID set up; the passcode gate of Settings › Face ID y código ran in its place). Reconnect an MCP server after a rebuild, or it keeps running the old binary.
- The tool's own tunnel (the default since 2026-11-19, [state](transport.md#a-tunnel-of-the-tools-own)): more changes of link with `remoted`'s log read (a `tree` or a `wait` in flight now answers with `retriedAfter`, three times of three; one change of link in about twelve logged an interruption of `remoted`, recovered in two seconds, cause unknown), an action in flight when the cable is pulled, a `batch` or MCP session across a change of link or over the network (one MCP session ran on the cable), and a second device. The Apple TV 4K, which the tunnel cannot reach, fell back and said why.
- `tree` and the selector commands refuse a phone in landscape ("requires portrait geometry"), seen after that handoff; touch, keys and captures in landscape on a phone are still unrun.
- A held `key` or `button` whose sender is killed, and a hold during which the cable or network path is lost rather than the process: a killed `long-press` ended by itself on the phone ([session](verification.md#phone-session-of-2026-11-17)), these did not run.
- `tree`, `wait`, `press` and `scroll` with a web page in front in Safari and in an app's own `WKWebView`; a page with frames. In Chrome the page's tree reads and `press` works ([record](verification.md#web-content-on-the-phone)); `scroll` did not run. Count how often the first read after a page load selects the browser instead of the page.
- `--index` through the MCP `index` field against a device; on the phone it ran from the CLI on a web form only ([record](verification.md#web-content-on-the-phone)).
- Setting the value of a SwiftUI field that has a label or identifier. A UIKit text field and a secure field in Settings ran. The Settings search field has neither label nor identifier: select it by its placeholder with `--with-value`, which has run on a simulator only.
- Built on 2026-11-17 and unit-tested only: a secure field's receipt (`readBack: masked`), `press` on a web field wider than the display, and `press --pid <browser>` on a browser's own control while a page is in front. The categories of errors that are not the tool's own are unit-tested too; none has been provoked on a device.
- Once physical `logs` is built on the log relay ([record](verification.md#the-log-relay-on-the-phone)): records with long or unusual fields, a stream of every process (`Pid: -1`), streams of minutes, a relaunch during a PID stream, and whether closing the socket ends the subscription on the phone.
- `frames` with the display rotated, on another device, for a long run (minutes, toward the 1000-frame and 1 GiB limits), and with a second process trying to capture or send input meanwhile. Portrait runs on the iPhone 13 mini are [recorded](verification.md#frames-on-the-phone).
- `detect-layout` on another phone or with another layout set on this one (it found Spanish – ISO on the iPhone 13 mini: [verification](verification.md#layout-detection)), in a field other than the probe's (one with autocorrection or auto-capitalisation on, to see `no-match` and the hints), and through MCP against a phone.
- Typing in keyboard layouts other than Spanish – ISO, which the iPhone 13 mini uses on its own and which typed exactly ([verification](verification.md#keyboard-layouts-on-the-phone)). The runs below remain for other layouts, each needing the phone's layout changed by hand ([physical typing](physical-typing.md#layouts); simulator results in [verification](verification.md#keyboard-layouts-on-the-simulator)). The phone's layout cannot be read, so set it by hand first in Settings › General › Keyboard › Hardware Keyboard (if that section appears without a real keyboard attached, which is itself unknown), then confirm it with `detect-layout --id probe.text.field --device <UDID>`, and focus `probe.text.field` (`set-value --id probe.text.field x --device <UDID>`, `key backspace`). Read the result from `probe.text.value` in `tree`. Suggested runs, each with its own layout set on the phone:
  - `type 'Ab9!z;[ ~"<>? mañana café über ß €' --device <UDID>` with the phone on US: US ASCII plus Option dead keys, which were only seen on a simulator.
  - `type --layout spanish-iso 'Año Ñandú ¿Qué? ¡Sí! €5 ç <º> @#' --device <UDID>`.
  - `type --layout german 'Grüße, Straße! @ € ê ÄÖÜ y<z>' --device <UDID>`.
  - `type --layout latin-american '<>≤ |°¬' --device <UDID>`, or another of the 13 layouts whose key left of 1 and key left of Z differ between the ISO and ANSI keyboard types: the simulator used ISO; whether a phone's Indigo keyboard does is the main open question.
  - The same once through MCP: `mise run test:mcp-type <UDID> 'Año ¿qué?' spanish-iso`.
  - Record whether Settings shows a Hardware Keyboard section while nothing but Manzanero's events have been sent, and whether the layout chosen there changes the result without relaunching the app.
- Landscape on a phone, an iPad, and anything on a second device. The simulator side of rotation and iPad is measured. On 2026-11-17 the Mac listed other iPhones, iPads and Apple TVs as paired and available; none has been used, and none is to be until the owner names it.
- The 200 ms input drain on another device and with the Mac under load (on the iPhone 13 mini, 50 ms lost short gestures and 100 ms did not).
- An output above 64 KiB through `console` (a 1 KiB bound on 4.6 kB was kept correctly; the probe has no bulk trigger).

## Not yet run on Apple TV, Apple Watch or iPhone Duo hardware

One Apple TV 4K has been driven; everything else in [other families](other-families.md) has run on simulators only, and on those real devices nothing is known, including whether the commands apply at all:

- Duo: `displays`, `screenshot` with and without `--display`, `record --display`. `fold`, `unfold` and `hinge` are simulator-only (a physical device's hinge is moved by hand); on hardware, check what the display information reports in each fold state.
- Apple TV 4K, where trees with focus, focus waits, `press`, `set-value`, `type`, the touch refusal and every `remote` button have run ([guide](other-families.md#a-physical-apple-tv)). Tell the human owner before the first command: a sleeping Apple TV and its television can come on. Still to run there:
  - Before each accessibility command in a run, read `/usr/libexec/remotectl dumpstate`: `State: attached` for the device's connection means it has gone stale. Stop sending then, because every command keeps the stale tunnel alive; it clears when the tunnel is replaced, or with a restart of the two services on the human owner's word ([guide](other-families.md#a-physical-apple-tv)). One `remote home` wakes the device, and the television comes on with it.
  - A held Home shorter than 1.5 s: held select, arrows, Menu and Play/Pause ran, and a 1.5 s hold of Home failed on the device's button service, so it is refused ([record](verification.md#held-remote-buttons-on-the-apple-tv-4k)). The probe's current build is on the device.
  - `open-url`, with an address the human owner chooses. The other commands, `reports get` among them, ran on 2026-11-20 ([record](verification.md#the-commands-that-had-not-run-on-the-apple-tv)).
  - Through the accessibility shim ([record](verification.md#the-inspectors-cursor-the-whole-hierarchy-and-a-press-through-the-shim)): the cursor put on an element with `deviceInspectorFocusOnElement:`, a press of a row inside a list, a screen other than the probe's, and why one walk of ten entered the lists. Attributes, the hierarchy, the walk and one press ran, and `press` by the cursor ran from the command ([record](verification.md#press-by-the-inspectors-cursor-on-the-apple-tv-4k)).
  - The error a query gives in the stale state, which was built after the last stale period and has only run in unit tests.
  - The video stream after its first pictures (recording and `frames` are refused meanwhile): the device changes the picture's scale without a key frame and the decoder shows damage ([record](verification.md#the-apple-tvs-video-stream-read-packet-by-packet)). The capture of the tvOS probe's still screen with the stream kept ran on 2026-11-20 ([record](verification.md#the-same-stream-from-a-still-screen-kept-and-read-again)). To run: `record`, and whatever is built to follow the change. The audio stream beside the video was tried and changes nothing.
  - Not the Apple TV HD paired with the same Mac: it runs tvOS 26.6, cannot take 27, and the human owner discarded it for this tool on 2026-11-18.
- Apple Watch: `crown` against a list and a crown-bound value (scale, one row per event), `button side`, and `button action` on an Apple Watch Ultra.

## Not yet run on simulators

These need no hardware and no owner decision; they were left out of the simulator runs.

- On the Duo's inner display: the centre-hit fallback when no frontmost application is reported; only the `rot90` orientation was seen. Four- and five-path `multi-drag` are [recorded](verification.md#the-duos-inner-display).
- Follow-up to a run already [recorded](verification.md#the-duos-inner-display): a portrait-only app is letterboxed on the Duo's inner display, where `press` fails at the hit test, the tree's frames are window-relative and touch coordinates are the display's. Find where the window's origin can be read before changing anything.
- `fold` on the Duo straight after boot: with one other simulator running (not one of this project's), the first fold after boot was not observed within its 10 s bound and the next four were, as were five unfolds ([record](verification.md#the-duos-inner-display)). Earlier, one of five was missed with three others running and none with two. So the miss may belong to a simulator that has just booted, not to load; fold once more after a pause to tell. It has still not run with nothing else booted.
- `scroll --search` on an iPad simulator, and on a list whose rows do not share an edge. It ran in four directions on an Apple TV simulator ([record](verification.md#apple-tv-simulator-power-off-held-keys-searches-in-four-directions-and-swipes)) and, on 2026-11-20, on an iPhone simulator against the probe's [list screen](probe-app.md#list-probe) ([record](verification.md#a-search-on-an-iphone-simulator-and-a-table-rows-two-objects)).
- On an Apple TV simulator, whether anything other than a restart wakes it after Power Off: every button and key the tool sends, a swipe and a System Wake Up usage were tried, and none did.
- On an Apple TV simulator, a click of the remote's touch surface; the four swipes ran, and so did swipes of chosen lengths and durations ([record](verification.md#a-swipe-of-a-chosen-length-and-duration)), once each and downward only.

## Questions still open

- Why did one tap on the Settings search field have no effect, when the next 36 taps there did?
- What made Apple's device services stop answering for the phone on 2026-11-16?
- What do apps' gesture recognizers make of three or more contacts?
- Which keyboard type (ANSI or ISO) does a phone apply to Indigo keyboard events, and does a phone's iOS version ship the same layouts as the Mac?
- Was the firewall also behind the earlier intermittent recording startup failures?
- Why does a subscription stop sometimes go unconfirmed? Three of about thirty selector commands on 2026-11-17; each time the socket closed 2 to 3 ms into the stop exchange, after one cleanup frame.
- Does a phone keep a key or button held when the process sending it is killed? It ended a contact itself, as a simulator did.
- Does a web input ever take `set-value`, for example after it has focus?
- Does setting or removing a passcode always drop the pairing?
- What makes the Mac's connection to the Apple TV go stale, three times on 2026-11-18, and why does `remoted` not reconnect?
- What wakes a sleeping Apple TV, and why did observation alone switch it on the first time?
- Which values does Apple's AVConference give VideoToolbox's resolution adaptation for the Apple TV's stream, and where does it learn each frame's size?
- Does a host remove a form that the server withdraws? If it does, a watching handoff could keep a form up as its "I will not do it" button.

## Stop conditions

Stop and record the state if an input returns an error after a contact may be down, or the screen does not match what the step expects. Take a screenshot and a tree before doing anything else. A system prompt is no longer a reason to stop by itself: the tree shows it, and its buttons can be pressed by label, but deciding a permission is still the owner's call.
