# Apple TV, Apple Watch and iPhone Duo simulators

The simulator commands in [simulator input](simulator-input.md) also run on tvOS, watchOS and the foldable iPhone Duo; [the research](other-families-research.md) recorded what worked unchanged. This page covers what was added for those families and what each addition was checked against. Evidence is in [verification](verification.md#other-simulator-families).

## Displays (iPhone Duo)

An iPhone Duo simulator has two integrated displays: the outer `LCD` (screen ID 1, device name `primary`, 466 × 678 points at 3×), which the simulator marks primary, and the inner `LCD-1` (screen ID 3, `primary-1`, 669 × 951 points). It also lists `TVOut`, `Wireless` (CarPlay) and `Resizable`, which have no framebuffer until something is connected. `simctl io screenshot` and `recordVideo` refuse to choose between the two integrated displays.

```sh
manzanero displays --simulator <UUID>                       # every display, with id, size, backlight, active, primary
manzanero screenshot tmp/outer.png --simulator <UUID>       # the primary display (LCD)
manzanero screenshot tmp/inner.png --simulator <UUID> --display LCD-1
manzanero screen ocr --simulator <UUID> --display 3
manzanero record tmp/inner.mp4 5 --simulator <UUID> --display primary-1
```

- `displays` reads the simulator's display information (the same read-only `dtdeviceinfod` request touch uses) and prints each display's `id`, `name`, `deviceName`, `type`, pixel and point size, `backlightState`, `active`, `currentOrientation`, `primary` and `capturable`, plus `defaultCaptureDisplay`.
- `screenshot`, `screen` and simulator `record` take `--display <name|device name|screen ID>`; names ignore case. Without it a simulator with one capturable display gets exactly the `simctl` invocation it got before, and a simulator with several gets `--display=<screen ID>` of the primary display. An unknown display, or one without a framebuffer, is refused with `ambiguous-or-missing-target` before anything is captured. Manzanero always passes the numeric screen ID to `simctl`.
- On a physical device `--display` is refused as `unsupported-operation` before any device contact; `displays` is simulator-only.
- `screen` reads the accessibility tree only for the primary display. With another display, `auto` describes the image by OCR and says why in `diagnostics`, and `tree` is refused before capture.
- Trees, waits, selector actions and touch follow the display the simulator marks primary, as before. They take no display option: with the device folded the inner display captures black, so nothing could be checked on it. The fold itself is separate work.

MCP: `list_displays`, and an optional `display` field on `screenshot`, `get_screen` and `record_screen`.

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
```

`crown` sends `IndigoScrollEvent` messages to the simulator's `com.apple.coredevice.feature.remote.hid.scroll` service, which only watchOS runtimes publish: `{point: {x: 0, y: <units>, z: 0}, phase: 0, momentum: 0, target: 0}`. Target 0 is the Digital Crown (target 1 is refused as `No dial service found for scroll event`).

Calibration on the watchOS 27.2 simulator, with a SwiftUI probe whose `digitalCrownRotation` value (low sensitivity, continuous) was read through the tree, and with Watch Settings' list:

- **Units are integers.** `y: 1` moved the value by 0.005, `1.5` by 0.005, `0.5` not at all: the daemon drops fractions. So 200 units are 1.0 of a low-sensitivity SwiftUI binding; positive values increase it and scroll lists toward later content, negative ones back.
- **Single events are exact, at any size** (`y: 1000` moved it by 5.000). **Fast events are accelerated**, like a crown turned quickly: five 20-unit events 16 ms apart moved the value by 4.8 instead of 0.5, 100 ms apart by 2.6, 200 ms apart by exactly 0.5.
- **Lists move by rows per event, not by units.** In Watch Settings one event of 100 units or more moved the list one row (24 points for the first, then 60), whatever its size (100, 300 and 1000 alike); events below 100 (20 or 50 units, even repeated) moved nothing. Two 100-unit events 250 or 500 ms apart moved it more than four rows, 800 or 1200 ms apart exactly two.
- **Phase and momentum.** Phases 1 (began), 2 (changed) and 4 (ended) each delivered their delta like phase 0, but a began–changed–changed–ended sequence of 30 units moved the value by 40 units' worth, so the ended phase adds an inertial step. Momentum 1 or 2 made no difference. Manzanero sends phase 0 and momentum 0.

So `crown` sends the units as the fewest events of at most 1000 units, one second apart, and `--events <n>` (1...20) splits them evenly: `crown 200` moves a SwiftUI crown binding by 1.0, and `crown 300 --events 3` moved Settings three rows. The receipt lists `unitsPerEvent`. Several events take one second each. Another family is refused as `unsupported-operation` before input, and a physical device before any contact.

**Side button.** DeviceKit's watch chrome (`/Library/Developer/DeviceKit/Chrome/watch*.devicechrome/…/chrome.json`) gives the side button as consumer page 12, usage 149 (0x95), and the crown press as 64 (the existing `button home`). `button side` sends 0x95 on the button service; on the watch face it opened Control Center, and a second press closed it. It is refused on other families. The `watch6` chrome also lists a `left-side-button` (page 0xFF01, usage 512), which was not tried. `button lock` (0x30) still does nothing on the watch.

MCP: `rotate_crown`; `press_button` accepts `side`.
