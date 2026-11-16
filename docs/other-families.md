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

Apple TV has no touch screen: `tap`, `long-press`, `swipe`, `drag`, `pinch`, `multi-tap`, `multi-drag` and `gesture` on an Apple TV simulator are refused as `unsupported-operation` with a pointer to `remote`, before the display is read. Swipes on the remote's touch surface are not implemented. `key`, `type`, `button home`, trees, waits and `press` work as on a phone.

MCP: `press_remote`.
