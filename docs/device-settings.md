# Orientation, settings, location, status bar and clipboard

Five commands that change or read a target's state through Apple's `devicectl`, which addresses a booted simulator by its UUID exactly as it addresses a device. Built on 2026-11-21 and run on an iPhone simulator (`manzanero-research-phone`, iOS 27.2); on the iPhone 13 mini the same evening `rotate`, `location`, `clipboard` and `settings` (read, changed and put back exactly) worked, and `status-bar` is not supported by a device ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)). On a device each command but `clipboard` changes the human owner's device, so ask first.

```sh
manzanero rotate landscape-left --simulator <UUID>          # portrait, portrait-upside-down, landscape-left, landscape-right
manzanero settings --appearance dark --text-size accessibility-large --increase-contrast on --reduce-motion off --simulator <UUID>
manzanero location 40.4168,-3.7038 --simulator <UUID>
manzanero location --simulator <UUID> -- -33.8688,151.2093  # a coordinate that begins with '-' goes after --
manzanero location --clear --simulator <UUID>
manzanero status-bar --time 9:41 --battery-level 100 --battery-state charged --wifi-bars 3 --simulator <UUID>
manzanero status-bar --clear --simulator <UUID>
manzanero clipboard --simulator <UUID>                       # read-only
```

MCP: `device_settings` (`operation`: `rotate`, `settings`, `location`, `status-bar`, with the same values as fields) and `read_clipboard`, which is read-only.

| Command | devicectl | Notes |
| --- | --- | --- |
| `rotate` | `device orientation set` | The interface turns only as far as the app in front allows: read the tree afterwards (its `screen.orientation` on a simulator). Accessibility commands follow the turn on a simulator; on a phone they accept it since 2026-11-21 and have not run there ([accessibility](direct-accessibility.md#current-native-tree-route)) |
| `settings` without options | `device info appearance` | Read-only: the current `userInterfaceStyle`, `textSize` (written "Extra Small", "Large"…), `increaseContrast`, `reduceMotion`, `reduceTransparency`, `largerAccessibilitySizesEnabled` and others, so a change can be put back exactly. Read on the iPhone 13 mini and a simulator on 2026-11-21; on the simulator a change to dark and Small read back as such and was put back to light and Large. MCP `read_settings` |
| `settings` | `device settings appearance` | `--appearance light\|dark`, `--text-size` (the twelve sizes, from `extra-small` to `accessibility-extra-extra-extra-large`), `--increase-contrast on\|off`, `--reduce-motion on\|off`; an accessibility text size also turns Larger Accessibility Sizes on, which devicectl requires for those sizes |
| `location` | `device simulate location coordinate` / `clear` | Decimal degrees, latitude −90…90 and longitude −180…180 |
| `status-bar` | `device simulate statusBar override` / `clear`, simulators only: the iPhone 13 mini answered that the capability is not supported, so a device is refused before it is contacted | `--time` (text), `--battery-level 0…100`, `--battery-state draining\|charging\|charged`, `--wifi-bars 1…3`, `--cellular-bars 1…5` (each also sets its mode to active), `--data-network` (hide, wifi, hotspot, 1x, GPRS, Edge, UMTS, 4G, LTE, LTEA, LTEPlus, 5G, 5GPlus, 5GUWB, 5GUC) |
| `clipboard` | `device pasteboard paste` | The first item's text, at most 1 MiB, with `contentType` and `bytes`; `empty: true` when there is nothing. devicectl writes the text to its stdout and its JSON to a file of the run, which is deleted afterwards |

Every command has a `--dry-run` plan, the invocation above, and each value is checked before any device is contacted. On a device, each first checks Developer Mode as `launch` does.

## Observed on the simulator

2026-11-21, `manzanero-research-phone`: `rotate landscape-right` made the tree report `rot90` and `rotate portrait` `rot0`; through `devicectl orientation set` directly, `landscapeLeft` gave `rot270` with an 874×402 interface, and in that orientation a `press` of a list row of the probe was accepted and recorded by the probe. `settings --appearance dark --text-size accessibility-large --increase-contrast on` read back from `simctl ui` as `dark`, `accessibility-large` and `enabled`, and the reverse as `light`, `large` and `disabled`. `location` with a negative longitude and `--clear` succeeded. `status-bar --time 9:41 --battery-level 100 --wifi-bars 3` and later a battery level of 7 while draining read back from `simctl status_bar list`; `--clear` removed them. `clipboard` returned the text a `devicectl pasteboard copy` had put there (`hola café`, 10 bytes, `public.utf8-plain-text`).

The same route put text on the simulator's clipboard, which `simctl pbcopy` never did ([simulator paste](simulator-input.md)): simulator `paste`, refused today, may be possible through it.
