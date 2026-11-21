# Status at a glance

One table of what works where, for a reader who wants the answer before the detail. It is a summary of [feature status](feature-status.md), which has the limits, and of [verification](verification.md), which has the evidence; when they disagree, they are right and this page is stale. Last brought up to date on 2026-11-21, after v0.1.0-beta.2.

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
| **Touch**: `tap`, `long-press`, `swipe`, `pinch`, `multi-tap`, `multi-drag`, `gesture` | works, one to five contacts | works; on an iPad a four-path `multi-drag` is cancelled by iPadOS | refused: no touch screen | refused: no touch screen | works (contacts beyond one not countable) | works |
| **Buttons and keys**: `button`, `key`, `wake` | works | works; `wake` refused | works (`key`, `button home`, `button lock`) | works | partly: `home`, `side` and the Ultra's `action` work, `lock` does nothing, `key` refused | works; `wake` refused |
| **Text**: `type`, `detect-layout`, `paste`, `set-value` | works | works; `paste` refused | works (`type`, `set-value`) | works | partly: `type` and `detect-layout` refused, `set-value` does not reach the app | works; `paste` refused |
| **Apple TV remote**: `remote` | — | — | works: all eight buttons, held keys, swipes, `sleep` and `wake`; a held Home is refused | works, with holds and swipes; `sleep` and `wake` refused | — | — |
| **Watch crown**: `crown` | — | — | — | — | works | — |
| **Fold**: `fold`, `unfold`, `hinge`, `displays` | — | — | — | — | — | works |
| **Accessibility, read**: `tree`, `wait` | works, portrait and landscape | works | works, see the routes below | works | works | partly: Home Screen tree is empty |
| **Accessibility, act**: `press`, `scroll`, `set-value` | works, portrait and landscape | works | works, see the routes below | works | works | works, a letterboxed app too since 2026-11-21 |
| **Accessibility, search a long list**: `scroll --search` | works downward; the other directions not run | works in four directions (iPhone, iPad) | works in four directions | works in four directions | partly: up and down on the Series 12; fails on the Ultra | works in four directions |
| **Pictures**: `screenshot`, `screen`, `ocr` | works | works | works | works | works | works, with `--display` |
| **Video**: `record`, `frames` | works with `--backend coredevice`, with sound by `--audio`; the default backend fails on this phone | `record` works; `frames` is for devices | works since 2026-11-20, up to a minute, with sound by `--audio` | `record` works | `record` works | works, with `--display` |
| **Apps**: `apps`, `launch`, `terminate`, `install`, `uninstall`, `open-url` | works | works | works | works | works (Ultra) | works; a first URL after its prompt was lost once |
| **Files and reports**: `files`, `reports` | works | — | works | — | — | — |
| **Settings**: `rotate`, `settings`, `location`, `status-bar`, `clipboard` | `rotate`, `location`, `clipboard` work; `status-bar` refused (a device does not support it); `settings` not run | works (iPhone, 2026-11-21) | not run | not run | not run | not run |
| **Build and run**: `build-run` | works | works | works | not run | not run | not run |
| **App output**: `console`, `last-crash`, `logs` | works | works | `console` and `last-crash` work; `logs` not run | not run | works | works |
| **A person's step**: `handoff` | works | works | works | works | works (`--until`) | works (`--until`) |
| **Several commands at once**: `batch` | works | works | works | works | works | works |
| **From an AI agent**: `mcp` | works | works | works | works | not run | works |

## The routes

A route is the way a command reaches the device. Most commands have one. Accessibility on a device has three, which is where the recent work has been.

| What | Route | Used for | State |
| --- | --- | --- | --- |
| Apps, files, reports, details, screenshots | Apple's own tools, `devicectl` for devices and `simctl` for simulators | Every platform | Settled |
| Touch, buttons, keys, the remote | Apple's input services, called in process | Devices and simulators | Settled |
| Video | Apple's media stream, decoded in process | Devices | Works on the phone and, since 2026-11-20, on the Apple TV |
| Logs | The device's log relay, on the tool's own tunnel or Apple's | `logs` on a device | Works on the phone since 2026-11-20, on both tunnels; not run on the Apple TV |
| Accessibility, route 1: **the tool's own tunnel** | A tunnel the tool opens itself, through the Mac's `usbmuxd` | A device `manzanero devices` shows as `ownTunnel: cable` or `network`, the iPhone and iPads; and an Apple TV after `manzanero pair`, which pairs the tool itself with it (PIN on the television) | The default since 2026-11-19. Works on the iPhone and, since 2026-11-20, on the Apple TV, with no side effect on the Mac |
| Accessibility, route 2: **Apple's tunnel** | The tunnel macOS keeps, plus a second connection of the tool's own to the device's list of services | The fallback, and the one an Apple TV uses until the tool is paired with it | Works. Side effect: the device resets the Mac's own connection to it, and now and then that connection does not come back until it is replaced |
| Accessibility, route 3: **the Inspector's way** | Through the Mac's `remoted`, as Apple's Accessibility Inspector does | `press` on the Apple TV, after the tool's own tunnel and before Apple's | Works with no side effect and without moving the focus. Rows inside lists, a full tree, `scroll` and `set-value` have no way there and use route 2 |
| Accessibility on a simulator | Apple's simulator framework | Every simulator | Settled |

A result says which accessibility route a command took: `serviceDirectory: own-tunnel` is route 1, `opened`, `reused-port` or `reused-saved-port` are route 2, and `route: inspector` is route 3. A press on an Apple TV that passed a route by says why: `ownTunnelUnavailable` for route 1 and `inspectorUnavailable` for route 3.

## What is open, in order

The same order as the roadmap's [next list](roadmap.md#next-in-the-order-suggested).

1. **`launch` with arguments, and `terminate` by bundle identifier**: done, on a simulator and the iPhone, 2026-11-21.
2. **The new `press` order on the Apple TV**: built and unit-tested, not yet run there.
3. **Selectors that are not exact**: built as `--match contains|regex` and run on a simulator on 2026-11-21.
4. **Small checks on the iPhone**: `open-url` from another app, an action in flight when the cable is pulled, an agent session over the network.
5. **Sound in a recording, the rest**: picture and sound in step, a long recording, and the Apple TV with something playing.
6. **Recording recovery**: a restart of the stream after a loss; [built](recording-recovery.md) on 2026-11-21 for recordings without sound, not yet run on a device.
7. **An install on a tester's Mac**: v0.1.0-beta.2 is installed on the development Mac only.
8. **Apple TV, loose ends**: the pairing after a restart and over days, `remote sleep` from a screen saver, `logs` there, a recording of several minutes.
9. **Hardware never used**: an iPad, an Apple Watch, an iPhone Duo.

## Done later on 2026-11-21 (not released)

- **`launch` options** and **`terminate` by bundle**; **`--match contains|regex`** for selectors; **`rotate`, `settings`, `location`, `status-bar`, `clipboard`**; **`double-tap`**; **`create-simulator`**: all run on simulators.
- **A phone in landscape** accepted by the accessibility commands, and **recording recovery** for recordings without sound: built and unit-tested, owed on the iPhone.
- **A completeness run** on iPad, iPhone Duo and Apple Watch simulators filled most of their columns above; a letterboxed app on the Duo can now be pressed, and `detect-layout` is refused on a watch.

## Done on 2026-11-21

- **v0.1.0-beta.2** published and in the Homebrew tap: one Apple silicon archive with everything below and since 2026-11-18.
- **`press` on an Apple TV** goes by the tool's own tunnel first, then the Inspector's cursor, then Apple's tunnel (built and unit-tested; not yet run there).
- **`logs` on a device**: entries at every level, debug included, from the device's log relay, of one process (until it ends), a group or every process, with filters; checked on the iPhone on both routes.
- **On the iPhone**: a plain table row pressed; a moving screen streamed whole, so the phone does not need the Apple TV's video fix; `open-url` against the probe.

## Done on 2026-11-20

- **Apple TV, video**: `record` and `frames` work. The tool was offering the Apple TV a feature its decoder cannot follow; without it the picture is right.
- **Apple TV, the remote's swipes**: all four work on the device, and a swipe's length and duration can be chosen there too.
- **Apple TV, sleep and wake**: `remote sleep` and `remote wake`, each one command that looks before it presses; sleep presses Power Off by accessibility, in any language and with any app in front.
- **Apple TV, accessibility with no side effect**: `manzanero pair` pairs the tool itself with the Apple TV, and `tree`, `wait`, `scroll`, `set-value` and every press then go over a tunnel of the tool's own.
- **`open-url` on the Apple TV**, against a URL scheme both probes now have.
- **Sound in a recording**: `record --backend coredevice --audio`, on the iPhone and the Apple TV.
- **Apple TV, a minute of a moving screen** recorded whole, and the movie no longer has black rows at the bottom.
- **Apple TV, `press` without the side effect**: by Apple's Inspector cursor, with the focus left where it was.
- **Plain table rows** can be pressed, found with a new list screen in the iOS probe on a new phone simulator.
- **Two tests that failed under load** are fixed.
