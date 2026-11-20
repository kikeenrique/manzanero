# Status at a glance

One table of what works where, for a reader who wants the answer before the detail. It is a summary of [feature status](feature-status.md), which has the limits, and of [verification](verification.md), which has the evidence; when they disagree, they are right and this page is stale. Last brought up to date at the end of 2026-11-20.

## How to read it

| Word | Meaning |
| --- | --- |
| **works** | Built, and seen working on that kind of device |
| **partly** | Works with a limit that matters; the cell says which |
| **refused** | The tool refuses it there on purpose, with a reason |
| **fails** | Built, tried there, and wrong |
| **not built** | No command does it |
| **not run** | Built, never tried there |
| — | Does not apply |

"Device" is real hardware and "simulator" is Xcode's simulator. The hardware used so far is one iPhone 13 mini (iOS 27.2.1) and one Apple TV 4K (tvOS 27.2). No iPad, Apple Watch or iPhone Duo hardware has been used, so those have simulator columns only; their devices are **not run** for everything.

## Commands by platform

| Commands | iPhone, device | iPhone and iPad, simulator | Apple TV, device | Apple TV, simulator | Apple Watch, simulator | iPhone Duo, simulator |
| --- | --- | --- | --- | --- | --- | --- |
| **Find and check**: `devices`, `details`, `readiness`, `processes`, `doctor`, `boot`, `shutdown` | works | works | works | works | works | works |
| **Touch**: `tap`, `long-press`, `swipe`, `pinch`, `multi-tap`, `multi-drag`, `gesture` | works, one to five contacts | works | refused: no touch screen | refused: no touch screen | works (`tap`; the rest not run) | works |
| **Buttons and keys**: `button`, `key`, `wake` | works | works; `wake` refused | works (`key`, `button home`, `button lock`) | works | partly: buttons work, `key` refused | not run |
| **Text**: `type`, `detect-layout`, `paste`, `set-value` | works | works; `paste` refused | works (`type`, `set-value`) | works | partly: `type` refused, `set-value` does not reach the app | not run |
| **Apple TV remote**: `remote` | — | — | works: all eight buttons, held keys and swipes; a held Home is refused | works, with holds and swipes | — | — |
| **Watch crown**: `crown` | — | — | — | — | works | — |
| **Fold**: `fold`, `unfold`, `hinge`, `displays` | — | — | — | — | — | works |
| **Accessibility, read**: `tree`, `wait` | works, portrait only | works | works, see the routes below | works | works | partly: Home Screen tree is empty |
| **Accessibility, act**: `press`, `scroll`, `set-value` | works, portrait only | works | works, see the routes below | works | works (`press`) | partly: `press` fails in a letterboxed app |
| **Accessibility, search a long list**: `scroll --search` | not run | works in four directions (iPhone) | works in four directions | works in four directions | not run | not run |
| **Pictures**: `screenshot`, `screen`, `ocr` | works | works | works | works | not run | works, with `--display` |
| **Video**: `record`, `frames` | works with `--backend coredevice`; the default backend fails on this phone | `record` works; `frames` is for devices | works since 2026-11-20, on a still screen | `record` works | not run | works, with `--display` |
| **Apps**: `apps`, `launch`, `terminate`, `install`, `uninstall`, `open-url` | works | works | works; `open-url` not run | works | not run | works |
| **Files and reports**: `files`, `reports` | works | — | works | — | — | — |
| **Build and run**: `build-run` | works | works | works | not run | not run | not run |
| **App output**: `console`, `last-crash`, `logs` | `console` and `last-crash` work; `logs` not built | works | `console` and `last-crash` work; `logs` not built | not run | not run | not run |
| **A person's step**: `handoff` | works | works | works | works | not run | not run |
| **Several commands at once**: `batch` | works | works | works | works | not run | not run |
| **From an AI agent**: `mcp` | works | works | works | works | not run | works |

## The routes

A route is the way a command reaches the device. Most commands have one. Accessibility on a device has three, which is where the recent work has been.

| What | Route | Used for | State |
| --- | --- | --- | --- |
| Apps, files, reports, details, screenshots | Apple's own tools, `devicectl` for devices and `simctl` for simulators | Every platform | Settled |
| Touch, buttons, keys, the remote | Apple's input services, called in process | Devices and simulators | Settled |
| Video | Apple's media stream, decoded in process | Devices | Works on the phone and, since 2026-11-20, on the Apple TV |
| Accessibility, route 1: **the tool's own tunnel** | A tunnel the tool opens itself, through the Mac's `usbmuxd` | A device `manzanero devices` shows as `ownTunnel: cable` or `network`: the iPhone and iPads, never an Apple TV | The default since 2026-11-19. Works on the iPhone, with no side effect on the Mac |
| Accessibility, route 2: **Apple's tunnel** | The tunnel macOS keeps, plus a second connection of the tool's own to the device's list of services | The fallback, and the only one in use for the Apple TV | Works. Side effect: the device resets the Mac's own connection to it, and now and then that connection does not come back until it is replaced |
| Accessibility, route 3: **the Inspector's way** | Through the Mac's `remoted`, as Apple's Accessibility Inspector does | `press` on the Apple TV, tried first | Works with no side effect and without moving the focus. Rows inside lists, a full tree, `scroll` and `set-value` have no way there and use route 2 |
| Accessibility on a simulator | Apple's simulator framework | Every simulator | Settled |

A result says which accessibility route a command took: `serviceDirectory: own-tunnel` is route 1, `opened`, `reused-port` or `reused-saved-port` are route 2, and `route: inspector` is route 3. A press that tried route 3 and went by route 2 says why in `inspectorUnavailable`.

## What is open, in order

1. **Push** the local commits: three days of work, none of it in a release.
2. **Two phone runs for changes made on simulators**: pressing a plain table row, and a recording of a moving screen to see whether the phone needs the Apple TV's video fix too.
3. **Apple TV, the rest of accessibility without the side effect**: `press` goes by route 3. `tree`, `wait`, `scroll`, `set-value` and a press inside a list still use route 2; route 3 cannot carry them, and the other way, a pairing of the tool's own, is not built.
4. **Apple TV, small ones**: a recording of a moving screen and a long one, `open-url`, a swipe of a chosen length, and a `remote power` command.
5. **`logs` for devices**: the way in is proven, the command is not built.
6. **Small checks on the iPhone**: an action in flight when the cable is pulled, an agent session over the network, and `build-run` since it learned other platforms.
7. **Hardware never used**: an iPad, an Apple Watch, an iPhone Duo.

## Done on 2026-11-20

- **Apple TV, video**: `record` and `frames` work. The tool was offering the Apple TV a feature its decoder cannot follow; without it the picture is right.
- **Apple TV, the remote's swipes**: all four work on the device, and a swipe's length and duration can be chosen.
- **Apple TV, `press` without the side effect**: by Apple's Inspector cursor, with the focus left where it was.
- **Plain table rows** can be pressed, found with a new list screen in the iOS probe on a new phone simulator.
- **Two tests that failed under load** are fixed.
