# Other simulator families: tvOS, watchOS and iPhone Duo

> **Status (2026-11-16):** quick research pass, kept as written; it changed no product code. Answers open question 8 of [the simulator research](simulator-input-research.md#open-questions-and-the-experiment-that-settles-each) for tvOS, watchOS and the foldable iPhone Duo. visionOS was not tried. Built from it the same day: Duo display choice, fold and hinge, tvOS `remote` and focus, watchOS `crown` and `button side`, and the hit-test fix behind the duplicate-label refusals; the Apple TV remote's touch surface is blocked. The current guide is [other simulator families](other-families.md); the folding route is in [the fold research](duo-fold-research.md).

The existing simulator commands were run unchanged against one new simulator per family to see what already works, what fails and what is missing. Where something was missing, the simulator's own daemons were probed with a throwaway program to find the likely route.

## Environment and labels

- Host: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), CoreDevice 651.32. `manzanero` was the debug build already in `.build/debug/` (commit `c100292`).
- Simulators, created for this work with `simctl create` and booted headless with `manzanero boot` (Simulator.app was not opened; Xcode 27 ships no Simulator.app, the device window lives in DeviceHub/DeviceKit):
  - `manzanero-research-tv`: Apple TV 4K (4th generation) (at 1080p), tvOS 27.2 (24K150), 1920 × 1080 points at 1×.
  - `manzanero-research-watch`: Apple Watch Series 12 (46mm), watchOS 27.2 (24S118), 208 × 248 points.
  - `manzanero-research-duo`: iPhone Duo (`iPhone19,4`), iOS 27.2 (24B91016s, the Duo-only runtime `iOS-27-2-iPhone19-4`).
- All three are shut down and left in place. No other simulator and no physical device was used.
- Scratch material is in `tmp/other-families/` (untracked): `m.sh` (runs a command and logs stdout, stderr and exit code under `logs/`), `probe.m` (sends raw XPC messages to the simulator's `dtuhidd`/`dtdeviceinfod` services through the same `_4sim` connection the bridge uses), screenshots, and string dumps of the injected daemons.

**[O]** observed (ran it, saw the result). **[I]** inferred (from strings, plists or analogy; not exercised).

## Summary

| | tvOS | watchOS | iPhone Duo |
| --- | --- | --- | --- |
| `boot`, `apps`, `launch`, `shutdown` | works [O] | works [O] | works [O] |
| `screenshot` | works [O] | works [O] | **fails**: two displays [O] |
| `screen` | works (tree) [O] | works (tree) [O] | **fails**: two displays [O] |
| `tree`, `wait` | work [O] | work [O] | work in apps [O]; Home Screen tree empty [O] |
| `press --label` | refused on duplicate labels [O] | works [O] | refused on duplicate labels [O] |
| `tap`, `swipe`, `multi-tap` | refused: no touch display [O] | work [O] | work on the outer display [O] |
| `key` (arrows, return, escape, tab, space, backspace) | **works as the remote's D-pad, select and back** [O] | dispatched; no visible effect in Calculator [O] | dispatched [O] |
| `type` | works into a text field [O] | dispatched; no text field tried [O] | not tried |
| `button home` | goes to the Home Screen [O] | goes to the watch face [O] | works [O] |
| Biggest gap | Play/Pause and the touch surface | Digital Crown | screenshot/screen display choice; no fold control found |

## tvOS

### Works today

- `boot`, `apps` (simctl's plist output: Settings, Xcode Previews, Shortcuts actions and a few system bundles), `launch com.apple.TVSettings`, `shutdown`. [O]
- `screenshot`: simctl picks the only display (`TVOut`). `screen` returned the tree. [O]
- `tree`: HeadBoard (the Home Screen, 34 nodes) and Settings (`display` 1920 × 1080, `pointScale` 1, `frontmost` selection). `wait --label "Video and Audio"` was met in 1.1 s. [O] The tree does not show which element has focus: the focused and unfocused rows carry the same traits. [O]
- `key` drives focus like the Siri Remote: `down`/`up` moved the focused row (screenshots before and after), `return` opened the focused row (select), `escape` went back one level (Menu). [O] `left`, `right`, `tab`, `space` and `backspace` were dispatched (exit 0) without an observed check. [O]
- `button home` (consumer usage 0x40) went from a Settings sub-page straight to HeadBoard, so it acts as the TV/Home button, not as Menu. [O]
- `type "Mz research"` entered text into the device-name field (Settings > General > About > Name): the field's value became `manzanero-research-tvMz research`. Escape left without saving. [O]

### Fails today

- `tap`, `swipe`, `multi-tap`: exit 1,
  `Expected one integrated primary display with valid typed geometry/orientation; no touch or capture started.`
  (`--error-format json`: `code: transport-failed`, `inputSent: none`). The display information lists one display, `TVOut`, `external: true`, so the physical touch check refuses it before any input. [O] Correct behaviour: tvOS has no touchscreen.
- `press --label "Video and Audio"`: exit 1,
  `Native AX press: target centre hit is another native element. AX press state=not-sent, stage=target-hit; UI effect unverified.`
  The label occurs on four nodes (cell and its static text, twice); the centre hit answers with another one. The same refusal happened on the Duo (below), so it is the selector meeting duplicate labels, not a tvOS problem. [O for the refusal; I for the cause]
- `set-value` was not tried: the text field has no label or identifier. [O]

### Missing, with the likely route

- **Remote buttons beyond home.** Indigo button events (`hid.button`, usage page 12) sent with the probe: 0x46 (Menu Escape) went back one level, 0x60 went home like 0x40, 0x41 (Menu Pick) and 0xCD (Play/Pause) were accepted with no visible change in Settings. [O] The same messages sent to tvOS's own `com.apple.coredevice.feature.remote.hid.tvremote` service also worked (0x46 went back). [O] Route: a tvOS-only `remote` command (`select`, `menu`, `home`, `play-pause`, `up/down/left/right`) mapped to keyboard usages and consumer button usages through the existing schedulers. Play/Pause needs an app that reacts to it before it can be called verified. **Size: small** (a table and a command, plus one live check with a media app).
- **Touch surface (swipes on the remote).** tvOS's Universal HID service lists only a `touchscreen(nil)`, keyboard, buttons and `avpCustom`, no remote. [O] Its `dtuhidd` knows device kinds `appleTVRemote`, `trackpad` and `touchSensitiveButton` and logs `Request to create HID service with primary usage page=… code=…`, so a Universal HID `connect` request that creates a virtual remote, then digitizer-style reports to it, is the likely route. [I] XCUIAutomation's `XCUIEventTypeTVRemote*` events are the Apple-supported alternative. [I] **Size: medium**; the report format must be found by experiment.
- **Focus in the tree.** Needed for a useful `press` analogue on tvOS (move focus, then select). AX attributes for focus were not looked for. **Size: small to medium.** [I]
- Touch commands should refuse with a tvOS-specific message instead of the physical display wording. **Size: small.**

## watchOS

### Works today

- `boot`, `apps` (Calculator, Settings, Messages, Maps, Contacts and others), `launch com.apple.NanoCalculator.watchkitapp`, `shutdown`. [O]
- `screenshot` (display `LCD`) and `screen`. [O]
- `tree`: the watch face (30 nodes) and Calculator (every key labelled; display 208 × 248). `wait --label 7` was met. [O]
- `press --label 7` entered 7 (result read back as `seven`). [O]
- `tap 0.5 0.6` landed on the `6` key twice (result `seven hundred sixty-six`); receipt `displayRotationDegrees: 0`. The display information lists one integrated primary display, so the physical display check passes. `swipe` was dispatched (exit 0). [O]
- `button home` returned from Settings to the watch face. Consumer 0x40 therefore acts as the Digital Crown press. [O]

### Fails today

- Nothing failed outright. `key` (down, return) and `type 12` were dispatched with exit 0 but did not change Calculator; no text field was tried, so keyboard input on watchOS is **unverified**. [O]
- `button lock` (consumer 0x30) was dispatched twice with no visible change and the backlight stayed `activeOn`. [O] It is not the side button.

### Missing, with the likely route

- **Digital Crown rotation.** watchOS's `dtuhidd` publishes `com.apple.coredevice.feature.remote.hid.scroll` (only on watchOS among the families tried) and its Universal HID service lists `CoreDevice digitalCrown` (usage page 0xFF0B). [O] The probe found the message shape from the daemon's decoding errors: `IndigoScrollEvent` with payload `{point: {x, y, z} (doubles), phase, momentum, target}`. With `target: 0`, ten events of `y: 20` scrolled Watch Settings' list down by 264 points and ten of `y: -20` scrolled it back up; `x` and `z` did nothing; `target: 1` was refused as `No dial service found for scroll event`; 2 and 4 are not valid targets. [O] Phase and momentum semantics and the points-per-unit scale were not measured. Route: a `crown <delta>` command on the existing `dtuhidd` connection with one new message builder in the bridge. **Size: small to medium** (most of it is calibration and a probe-app check).
- **Side button.** DeviceKit (Xcode's device window) has a "Side Button" control, so a route exists, but its HID usage was not found (0x30 does nothing visible). [I] **Size: small once the usage is known; unknown until then.**
- `wake` and `lock` semantics for the watch (wrist down, Always On) were not explored.

## iPhone Duo

The Duo profile declares two integrated displays, `LCD` (screen 1, `primary`, 1398 × 2034 pixels, 466 × 678 points at 3×) and `LCD-1` (screen 3, `primary-1`, 2007 × 2853 pixels, 669 × 951 points, `currentOrientation: rot90`), plus TVOut, Wireless (CarPlay) and a `Resizable` display, and the feature `com.apple.CoreSimulator.display.resizableScene`. [O] After a fresh boot both integrated displays reported `backlightState: activeOn`, but only `LCD` showed the interface; `LCD-1` captured black. [O]

### Works today

- `boot`, `apps`, `launch com.apple.Preferences`, `shutdown`. [O]
- `tree` of Settings used the primary display (466 × 678, `rot0`); `wait --label About` was met. [O]
- `tap 0.5 0.5` landed on Settings' General row and opened it (screenshot of `LCD`); `swipe`, `key escape` and `button home` were dispatched with exit 0. [O]
- `multi-tap` (two contacts) was dispatched after a fresh boot. Universal HID lists three touchscreens; manzanero chose the one matching the primary display's `uniqueId`, as on the iPhone. [O for dispatch; arrival not checked]

### Fails today

- `screenshot` and `screen`: exit 1,
  ```
  xcrun failed (22): An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):
  Cannot choose between 2 displays. Specify one with --display:
      --display=3  LCD-1 (primary-1) 2007x2853
      --display=1  LCD (primary) 1398x2034
  ```
  [O] `simctl io <UUID> screenshot --display=1` and `--display=3` both work. Route: pass `--display=<primary screen ID>` (from `simctl io enumerate` or the display information) whenever more than one display can be captured. `record` uses `simctl io … recordVideo` the same way and will probably fail likewise. [I] **Size: small.**
- `press --label About`: the same `target centre hit is another native element` refusal as on tvOS; the label is on the cell and on its static text. [O]
- `tree` on the Home Screen: exit 1 after about 15 s, `the simulator returned no snapshot data for this application, at full depth and at depth 10 for 12.0 seconds`. The iPhone 17e Home Screen worked at depth 10; the Duo's does not. [O]

### Fold state

- `simctl` has no fold, hinge or posture command (`simctl help`, `simctl ui`, `simctl io`). `simctl io screenConfig --display=<n> power on|off` and `geometry` exist. [O]
- Turning `LCD` off and `LCD-1` on with `screenConfig` did not unfold the device: `LCD-1` stayed black, and afterwards every display reported `backlightState: off`, so touch was refused as `display-off` (`The simulator's display is off or its state is unknown …`). A `button home` then marked `LCD-1` `activeOn` with `LCD` off, but `LCD-1` still captured black and the Home Screen tree failed. A reboot restored the original state. [O] **Do not use `screenConfig power` to emulate the fold.**
- `dtdeviceinfod` contains a `HingeAngleManager` over CoreMotion's `CMAngleManager`, and CoreDevice says `Hinge angle monitoring is not available on this device`, so the hinge angle is read-only monitoring on this side. [I] No writable fold control was found in CoreSimulator, SimulatorKit, CoreDevice or DeviceKit strings; DeviceKit's "resizable scene" mode (`adjustGeometry`, `commitResize`) resizes the `Resizable` display, which is a different feature. [I]
- Consequently, folded-versus-unfolded coordinates could not be compared. What is known: `screen`, `tree` and `tap` follow the display the display information marks `primary` (`LCD`). If the inner display ever becomes the interface, the primary-display choice in the touch, AX and screenshot paths will have to follow the active display rather than the `primary` flag. [I]
- Route: find how DeviceKit (Xcode's device window) folds the Duo, for example by watching the simulator's logs while folding it in Xcode's device window, which needs the owner. **Size: unknown until that experiment; the coordinate work after it is medium.**

## Recommended order of work

1. **Duo screenshot, screen and record display choice** (small): pass the primary screen ID to `simctl io`. Unblocks `screen` on the Duo. **Done:** `displays` and `--display` ([other families](other-families.md#displays-iphone-duo)).
2. **tvOS remote command** (small): select, menu, home, play-pause and the D-pad over the existing Indigo keyboard and button paths; replace the touch refusal wording on tvOS. Most of tvOS is then usable, since tree, wait, keys and type already work. **Done:** `remote`, every button verified including Play/Pause with a probe app; touch refused on tvOS ([other families](other-families.md#siri-remote-apple-tv)).
3. **watchOS Digital Crown** (small to medium): `IndigoScrollEvent` to `hid.scroll`, target 0; calibrate units and phases on a list. Then look for the side-button usage. **Done:** `crown`, calibrated (integer units, acceleration, rows per event), and `button side` (consumer 0x95, from DeviceKit's watch chrome) ([other families](other-families.md#digital-crown-and-side-button-apple-watch)).
4. **Press with duplicate labels** (small, all platforms): prefer the actionable element (button/cell) when a label matches a container and its static text, or report the duplicate. Seen on tvOS and Duo; worth checking on the iPhone. **Done, with a different cause:** the simulator bridge sent every hit test with client type 2, which answered a row's centre with an outer container on these two families; element hits now use type 0 as on a phone ([simulator input](simulator-input.md#observed-limits)).
5. **tvOS focus in the tree and the touch surface** (medium). **Focus done:** attribute 19 marks the focused node and `wait --until focused` reads attribute 28 ([other families](other-families.md#focus-in-the-tree-and-in-waits)). **Touch surface not built:** the legacy `universalhid` feature can create a virtual HID service, but its reply cannot carry the service ID and the remote's usages and report layout are unknown ([what was tried](other-families.md#remote-touch-surface-not-built)).
6. **Duo fold** (unknown): needs the owner to fold the device once in Xcode's device window while logs are captured. **Done without the owner:** a route was found ([fold research](duo-fold-research.md)), and `fold`, `unfold` and `hinge` are built ([other families](other-families.md#fold-iphone-duo)).

`docs/feature-status.md` and `docs/verification.md` were not updated; nothing here changes shipped behaviour.
