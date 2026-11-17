# Apple TV, Apple Watch and iPhone Duo simulators

The simulator commands in [simulator input](simulator-input.md) also run on tvOS, watchOS and the foldable iPhone Duo; [the research](other-families-research.md) recorded what worked unchanged. This page covers what was added for those families and what each addition was checked against. Evidence is in [verification](verification.md#other-simulator-families).

## Displays (iPhone Duo)

An iPhone Duo simulator has two integrated displays: the outer `LCD` (screen ID 1, device name `primary`, 466 × 678 points at 3×), which the simulator marks primary, and the inner `LCD-1` (screen ID 3, `primary-1`, 669 × 951 points). It also lists `TVOut`, `Wireless` (CarPlay) and `Resizable`, which have no framebuffer until something is connected. `simctl io screenshot` and `recordVideo` refuse to choose between the two integrated displays.

```sh
manzanero displays --simulator <UUID>                       # every display, with id, size, backlight, active, primary
manzanero screenshot tmp/outer.png --simulator <UUID>       # the display the interface is on
manzanero screenshot tmp/inner.png --simulator <UUID> --display LCD-1
manzanero screen ocr --simulator <UUID> --display 3
manzanero record tmp/inner.mp4 5 --simulator <UUID> --display primary-1
```

- `displays` reads the simulator's display information (the same read-only `dtdeviceinfod` request touch uses) and prints each display's `id`, `name`, `deviceName`, `type`, pixel and point size, `backlightState`, `active`, `currentOrientation`, `primary` and `capturable`, plus `defaultCaptureDisplay` and `interfaceDisplay`.
- **The interface display** is the display marked primary, except when that display is not awake and exactly one other integrated display with a framebuffer is `activeOn`: then it is that one. Only an unfolded iPhone Duo is in that case (the primary flag stays on the outer `LCD` while the interface is on `LCD-1`). With both integrated displays awake, which happens for a moment while folding and after a fresh boot, it is the primary one. A display without a framebuffer (`Resizable`) is never chosen, so a phone whose display is off is still refused as `display-off`.
- `screenshot`, `screen` and simulator `record` take `--display <name|device name|screen ID>`; names ignore case. Without it a simulator with one capturable display gets exactly the `simctl` invocation it got before, and a simulator with several gets `--display=<screen ID>` of the interface display. An unknown display, or one without a framebuffer, is refused with `ambiguous-or-missing-target` before anything is captured. Manzanero always passes the numeric screen ID to `simctl`.
- On a physical device `--display` is refused as `unsupported-operation` before any device contact; `displays` is simulator-only.
- `screen` reads the accessibility tree only for the interface display. With another display, `auto` describes the image by OCR and says why in `diagnostics`, and `tree` is refused before capture.
- Trees, waits, selector actions and touch follow the interface display. They take no display option. See [the inner display](#the-inner-display-unfolded) for what that changes on an unfolded Duo.

MCP: `list_displays`, and an optional `display` field on `screenshot`, `get_screen` and `record_screen`.

## Fold (iPhone Duo)

```sh
manzanero fold --simulator <UUID>          # hinge 0: outer display LCD
manzanero unfold --simulator <UUID>        # hinge 180: inner display LCD-1, landscape
manzanero hinge 110 --simulator <UUID>     # any angle 0...180, no display promised
manzanero hinge --simulator <UUID>         # read the angle (no input)
```

Each sends one `IndigoVendorDefinedEvent` to the simulator's `com.apple.coredevice.feature.remote.hid.vendordefined` service: usage page `0xFF61`, usage `0x5B`, version 0, and as data a binary `IOCFSerialize` of `{source: "hinge-slider-control", type: "range", value: <degrees>}`, the event Device Hub's hinge control sends ([research](duo-fold-research.md)). It goes through the same input path as buttons and keys: readiness barrier, the event (the service sends no reply), completion barrier and the input drain before the connection closes. The research lost the event when the connection closed at once; the drain keeps it open long enough. The simulator animates to the angle itself (0 to 180 in about 0.3 s).

- **`fold` and `unfold` wait for the display.** After sending 0 or 180 they read the display information every 250 ms, at most 40 times and 10 s, until the expected integrated display is `activeOn` and the other is `off`: the primary one (`LCD`) for `fold`, the other one (`LCD-1`) for `unfold`. The receipt has `expectedDisplay`, `activeDisplay` (the one integrated display awake at the last read, or null when none or both are), `displayObserved` and `displayReads`. When the display was not observed in time the command still exits 0 and says so in `note`; nothing is resent. On the iOS 27.2 runtime unfolding was observed after 3 reads and folding after 11 (about 2.7 s), with both displays reading awake in between.
- **`hinge <degrees>` promises no display.** Whether an intermediate angle swaps the display depends on how the hinge got there: 0 → 110 in one step unfolded, 0 → 45 → 70 → 110 in steps did not, and 180 → 90 stayed unfolded. So `hinge` reads the display information once right after sending and reports it with `displayObserved: false`.
- **Reading the angle.** `hinge` without an angle sends the CoreDevice action `com.apple.coredevice.action.streamhingeangle` to the simulator's `com.apple.coredevice.feature.monitormotion` service (in `dtdeviceinfod`), takes the first pushed sample, which is the current state, within 3 s, and cancels the connection, which ends the stream. It prints `angle`, `mechanicalAngle`, `minAngle` (0), `maxAngle` (180), `velocity` (degrees per second) and `isAngleValid`, with `activeDisplay` from the display information. `angle` and `mechanicalAngle` differ slightly at rest and depend on the direction: mechanical 90 read as 94.62 coming from 180 and as 85.38 coming from 0, mechanical 120 as 113.84, while 0 and 180 read exactly. It is an observation: no lease, no handoff pause, no input.
- **Posture, derived.** `hinge` (read) and `displays` on a foldable simulator also give `posture`: `closed` up to 5 degrees, `flat` from 175, `partially-open` between (`unknown` when the sample says the angle is invalid). Manzanero derives it from `angle` with these thresholds of its own; the simulator does not report it (the device-motion stream other tools read posture from was not found), and they are not Apple's `UIHinge` boundaries, which depend on velocity. `postureSource` says so in every result. `displays` adds a `hinge` object (`angle`, `isAngleValid`, `posture`, `postureSource`) only for foldable simulators, so other simulators send exactly the one request they sent before; a failed angle read appears as `hinge.error` and the displays are still listed.
- **Foldable only.** A simulator is foldable when its display information lists exactly two integrated displays with a framebuffer, one of them primary; no device-type key marks a foldable. Others are refused as `unsupported-operation` after that read-only request and before any input; a physical device is refused before any contact.
- **Cancellation.** SIGINT during the wait stops it (exit 130); the hinge connection has already closed, and each display read opens and closes its own. The event itself was sent, so the device may end up folded or unfolded.
- `fold`, `unfold` and `hinge <degrees>` take the simulator lease like other input, and hold the command service for their whole duration, wait included, so a second call to the same CLI or MCP server cannot run between the event and the display check.

MCP: `fold_device` (`state`: `fold` or `unfold`), `set_hinge_angle` (`degrees`) and `get_hinge_angle` (read-only).

### The inner display (unfolded)

Unfolded, `LCD-1` reports `nativeOrientation: rot0`, `currentOrientation: rot90`, 2007 × 2853 pixels at 3× (669 × 951 points), and the interface is landscape, 951 × 669 points; the device reports `landscapeRight`. What follows the interface display there, all measured on the iOS 27.2 runtime with the [probe app](probe-app.md) launched with `-ProbeAllowRotation YES` (its view reported 951 × 669):

- **Touch goes to LCD-1's own Universal HID touchscreen.** Indigo digitizer events (`hid.digitizer`) never reached `LCD-1`: a raw tap with the payload's `target` 0, 1, 2, 3, 4 or 5 left the probe at zero touches. The Universal HID service lists one touchscreen per display, `CoreDevice touchscreen(<uniqueId>)`, and the one named after `LCD-1`'s unique identifier delivers. So on a non-primary interface display, `tap`, `long-press`, `swipe`, `drag`, `pinch` and two-path `multi-drag` send their usual samples as Universal HID complete-state reports to that touchscreen (`route: universal-hid` and `frameCount` in the receipt; schedules longer than the bridge's 512 frames, such as a 10 s long press, are thinned evenly). `multi-tap`, `gesture` and three-to-five-path `multi-drag` already used Universal HID and now pick that display's touchscreen. Coordinates map as on a phone in landscape right: interface (x, y) is the touchscreen's (y, 1 − x).
- **Accessibility hit tests name the display.** Trees worked unchanged (the frontmost-application request answered), but every hit test failed with error 8 until it carried `LCD-1`'s screen ID: hit and frontmost requests now send `displayId` 3 instead of 0, with the point mapped to `LCD-1`'s native portrait points (interface (475.5, 563) is (563, 475.5)). Display 0, 1 or 2, or unmapped interface points, were refused. On the primary display the requests are unchanged (`displayId` 0).
- **Geometry.** Trees, waits and actions use the interface size 951 × 669 and `rot90`; the result's `screen` object gives `LCD-1`'s native size and adds a `display` object (`id`, `name`, `deviceName`, `primary: false`). On the primary display `screen` keeps its shape.
- **Captures** default to `LCD-1` (`--display=3`), so `screenshot`, `screen` and `record` without `--display` show the interface; `screen` reads the tree for it.

Observed working unfolded: `tree`, `press` (by label and by identifier), `scroll --id` (Settings' StandBy row, `postcondition-verified`), `wait`, `set-value`, `type` into a focused field, `tap` (landed at 0.2499, 0.7499 for 0.25, 0.75), `long-press` (held 1.502 s for 1.5), `swipe`, `drag`, `pinch`, two-path `multi-drag`, `multi-tap` with 3 and 5 contacts, `screen`, `screenshot` and `record`; folded, the same commands ran on `LCD` by the old route (Indigo for one and two contacts, no `route` key), and on an `iPhone 17e` the requests and the `simctl` invocation were unchanged.

Not working or not tried:

- The Home Screen tree fails unfolded as it does folded on this runtime (no snapshot data at full depth or depth 10); unrelated to the display.
- Right after `simctl launch` of Settings unfolded, the frontmost request still named the previous app for a few seconds while Settings drew a blank window; a later `tree` read Settings. In its two-column layout `press --label General` is refused as ambiguous (sidebar row and detail title); `press --id com.apple.settings.general` worked.
- `gesture`, three-to-five-path `multi-drag` and the hit-test fallback for a simulator that reports no frontmost application were not run on `LCD-1`. Only `rot90` was seen; whether `LCD-1` turns to other orientations, and whether the mapping holds then, is unknown.

## Siri Remote (Apple TV)

```sh
manzanero remote <select|menu|home|play-pause|up|down|left|right> --simulator <UUID>
```

| Button | Sent | Observed effect (tvOS 27.2 simulator) |
| --- | --- | --- |
| `up`, `down`, `left`, `right` | Keyboard usage 82, 81, 80, 79 on `hid.keyboard` (as `key up` …) | Focus moved between Settings rows and between the probe's buttons; SwiftUI's `onMoveCommand` received each direction |
| `select` | Keyboard usage 40 (Return) | Opened the focused Settings row; triggered the focused SwiftUI button |
| `menu` | Consumer usage 0x46 (Menu Escape) on `hid.button` | Settings went back one level; SwiftUI's `onExitCommand` fired |
| `home` | Consumer usage 0x40 (as `button home`) | Went to the Home Screen |
| `play-pause` | Consumer usage 0xCD | SwiftUI's `onPlayPauseCommand` fired once per press |

Buttons are held 80 ms, like the phone's. `remote` takes the simulator lease, sends no touch and is refused as `unsupported-operation` before any input on a simulator whose CoreSimulator product family is not Apple TV, and before any device contact with `--device`. The product family comes from the simulator's device type.

Apple TV has no touch screen: `tap`, `long-press`, `swipe`, `drag`, `pinch`, `multi-tap`, `multi-drag` and `gesture` on an Apple TV simulator are refused as `unsupported-operation` with a pointer to `remote`, before the display is read. Swipes on the remote's touch surface are [not implemented](#remote-touch-surface-not-built). `key`, `type`, `button home`, trees, waits and `press` work as on a phone.

MCP: `press_remote`.

### Focus in the tree and in waits

On an Apple TV simulator, `tree` (and `screen`'s tree) asks the application for its focused element once more after the snapshot and marks that node `"focused": true`; the result also has `"focus": {"read": true, "attribute": 19, "nodeId", "label", "identifier"}`, with nulls when the focused element is not among the snapshot's nodes. No existing field changes, and other families send no extra request and get no `focus` key.

`wait … --until focused` is met when exactly one visible element matches and its live focused attribute is true; the reason is `not-focused` or `focus-unknown` otherwise. It reads the focused attribute together with the enabled and visible attributes it already reads; other conditions send exactly the requests they did before. It is accepted on every platform, but has only been checked on the Apple TV simulator. On tvOS, `remote` moves focus and `select` activates the focused item, so a `wait --until focused` between them confirms the target before the click.

How the attributes were found: the snapshot's attributes and the traits of the focused and unfocused buttons were identical. `-[AXPMacPlatformElement _attributeTypeForMacAttribute:]` in AccessibilityPlatformTranslation maps `AXFocused` to attribute 28 and `AXFocusedUIElement` to 19 (`AXFrame` 21, `AXIdentifier` 25, `AXEnabled` 27 and `AXValue` 53 match the attributes Manzanero already used). On the tvOS probe, 28 answered true for the focused button and false for the others, and 19 on the application answered the focused button's element.

### Remote touch surface: not built

Swipes on the Siri Remote's touch surface (and its clickpad ring) are not implemented. What was tried on the tvOS 27.2 simulator, with a scratch copy of the research probe sending raw XPC to the simulator's `dtuhidd`, and what is missing:

- `com.apple.coredevice.feature.remote.universalhidservice` (the route multi-touch uses on phones) lists only `mainTouchscreen` (`CoreDevice touchscreen(nil)`, usage page 13/4), `mainKeyboard`, `mainScreenButtons` and `avpCustom`. Its `Request` enum has no `connect`, `report` or `supportedDevices` case: each was refused as `DecodingError.typeMismatch … Request … Invalid number of keys found`.
- A second feature, `com.apple.coredevice.feature.remote.universalhid` (logged as `LegacyUniversalHIDServer`), does have them. `{supportedDevices: {}}` answered six device kinds, beginning `appleTVRemote`, `digitizer`, `mouse`. Its decoding errors gave the request shapes: `connect: {_0: {vendorID: Int, productID: Int, product: String, usages: [{page: UInt16, code: UInt16}]}}` and `report: {_0: UInt64 service ID, _1: Data}` (a raw HID report).
- `connect` with usages page 12/1 (consumer control) or page 13/5 (touch pad) created and activated a virtual HID service, named `unknown(0x0)` in the log, but the reply failed on the daemon's side (`NSCocoaErrorDomain` 4866, "The source for an in-place encode must encode to a dictionary at the top level"), so the new service's ID never came back, and the service was cancelled when the connection closed.
- Missing: which usages make the daemon create an `appleTVRemote` (or `trackpad`) service rather than `unknown`, the service ID to address (the reply cannot carry it; it might be discoverable on the same connection), and the raw report layout the remote's descriptor expects. Each needs its own experiment; until then there is no verified swipe. The `com.apple.coredevice.feature.remote.hid.tvremote` service accepted button events in the research but was not explored for touches. XCUITest's `XCUIRemote` is Apple's supported alternative for scripted remote input and would need a test runner.

## Digital Crown and side button (Apple Watch)

```sh
manzanero crown <units> [--events <n>] --simulator <UUID>   # negative: crown --simulator <UUID> -- -200
manzanero button side --simulator <UUID>
manzanero button action --simulator <UUID>                  # Apple Watch Ultra's Action button
```

`crown` sends `IndigoScrollEvent` messages to the simulator's `com.apple.coredevice.feature.remote.hid.scroll` service, which only watchOS runtimes publish: `{point: {x: 0, y: <units>, z: 0}, phase: 0, momentum: 0, target: 0}`. Target 0 is the Digital Crown (target 1 is refused as `No dial service found for scroll event`).

Calibration on the watchOS 27.2 simulator, with a SwiftUI probe whose `digitalCrownRotation` value (low sensitivity, continuous) was read through the tree, and with Watch Settings' list:

- **Units are integers.** `y: 1` moved the value by 0.005, `1.5` by 0.005, `0.5` not at all: the daemon drops fractions. So 200 units are 1.0 of a low-sensitivity SwiftUI binding; positive values increase it and scroll lists toward later content, negative ones back.
- **Single events are exact, at any size** (`y: 1000` moved it by 5.000). **Fast events are accelerated**, like a crown turned quickly: five 20-unit events 16 ms apart moved the value by 4.8 instead of 0.5, 100 ms apart by 2.6, 200 ms apart by exactly 0.5.
- **Lists move by rows per event, not by units.** In Watch Settings one event of 100 units or more moved the list one row (24 points for the first, then 60), whatever its size (100, 300 and 1000 alike); events below 100 (20 or 50 units, even repeated) moved nothing. Two 100-unit events 250 or 500 ms apart moved it more than four rows, 800 or 1200 ms apart exactly two.
- **Phase and momentum.** Phases 1 (began), 2 (changed) and 4 (ended) each delivered their delta like phase 0, but a began–changed–changed–ended sequence of 30 units moved the value by 40 units' worth, so the ended phase adds an inertial step. Momentum 1 or 2 made no difference. Manzanero sends phase 0 and momentum 0.

So `crown` sends the units as the fewest events of at most 1000 units, one second apart, and `--events <n>` (1...20) splits them evenly: `crown 200` moves a SwiftUI crown binding by 1.0, and `crown 300 --events 3` moved Settings three rows. The receipt lists `unitsPerEvent`. Several events take one second each. Another family is refused as `unsupported-operation` before input, and a physical device before any contact.

**Side button.** DeviceKit's watch chrome (`/Library/Developer/DeviceKit/Chrome/watch*.devicechrome/…/chrome.json`) gives the side button as consumer page 12, usage 149 (0x95), and the crown press as 64 (the existing `button home`). `button side` sends 0x95 on the button service; on the watch face it opened Control Center, and a second press closed it. It is refused on other families. `button lock` (0x30) still does nothing on the watch.

**Action button.** The `watch6` chrome, the Apple Watch Ultra's, also lists a `left-side-button` (image `StingButton`) on the vendor page 0xFF01, usage 512 (0x200). `button action` sends that pair on the button service, held 80 ms. On an Apple Watch Ultra 4 simulator's watch face it opened the Action button's setup ("Choose Action"); on a Series 12 simulator, which has no such button, the same event changed nothing. It is sent to any Apple Watch simulator and refused on other families; the receipt and the dry-run plan give `usagePage` and `usage`.

**No keyboard input.** `key` and `type` are refused on an Apple Watch simulator as `unsupported-operation`, before any input. The keyboard service accepts the events, but nothing arrives: `key down`, `key return` and `type 12` changed nothing in Calculator, and with the system text entry sheet of a SwiftUI `TextField` open, `type 'Hola 12'`, `key backspace` and `key return` left the field empty and the sheet open. `set-value` on that field was acknowledged and changed the text the field shows and reports, but the app's bound string stayed empty, so on watchOS it is not a way to enter text either. The sheet's own keys can be tapped.

MCP: `rotate_crown`; `press_button` accepts `side` and `action`.
