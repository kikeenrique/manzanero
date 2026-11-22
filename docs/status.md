# Status at a glance

One table of what works where, for a reader who wants the answer before the detail. It is a summary of [feature status](feature-status.md), which has the limits, and of [verification](verification.md), which has the evidence; when they disagree, they are right and this page is stale. Last brought up to date on 2026-11-22; the work since v0.1.0-beta.2 (2026-11-21) is in no release yet.

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
| **Find and check**: `devices`, `details`, `readiness`, `processes`, `doctor`, `boot`, `shutdown`, `create-simulator` (simulators) | works | works | works | works | works | works |
| **Touch**: `tap`, `double-tap`, `long-press`, `swipe`, `pinch`, `multi-tap`, `multi-drag`, `gesture` | works, one to five contacts; `tap` in landscape too | works; on an iPad four moving contacts are cancelled by iPadOS, even with its gesture settings off | refused: no touch screen | refused: no touch screen | works (contacts beyond one not countable) | works |
| **Buttons and keys**: `button`, `key`, `wake` | works | works; `wake` refused | works (`key`, `button home`, `button lock`) | works | partly: `home`, `side` and the Ultra's `action` work, `lock` does nothing, `key` refused | works; `wake` refused |
| **Text**: `type`, `detect-layout`, `paste`, `set-value` | works | works; `paste` refused | works (`type`, `set-value`) | works | partly: `type` taps the on-screen keyboard (ASCII letters, digits, the numbers and symbols pages; no accents); `detect-layout` refused; `set-value` does not reach the app | works; `paste` refused |
| **Apple TV remote**: `remote` | — | — | works: all eight buttons, held keys, swipes, `sleep` and `wake`; a held Home is refused | works, with holds and swipes; `sleep` and `wake` refused | — | — |
| **Watch crown**: `crown` | — | — | — | — | works | — |
| **Fold**: `fold`, `unfold`, `hinge`, `displays` | — | — | — | — | — | works |
| **Accessibility, read**: `tree`, `wait` | works, portrait and landscape | works | works, see the routes below | works | works | partly: Home Screen tree is empty |
| **Accessibility, act**: `press`, `scroll`, `set-value` | works, portrait and landscape; web pages in Chrome, Safari and an app's own web view, `scroll` included (`set-value` does not change a web input) | works; a Safari page or an app's web view by `--pid <page>` | works, see the routes below | works | works | works, a letterboxed app too since 2026-11-21 |
| **Accessibility, search a long list**: `scroll --search` | works in four directions; downward in landscape too. Upward takes four times the steps of downward through a table | works in four directions (iPhone, iPad) | works in four directions | works in four directions | works, up and down (Series 12 and Ultra) | works in four directions |
| **Pictures**: `screenshot`, `screen`, `ocr` | works | works | works | works | works | works, with `--display` |
| **Video**: `record`, `frames` | works with `--backend coredevice`, with sound by `--audio`, in step and to the end since 2026-11-21; both recover across a pulled cable, `record` with its sound too since 2026-11-22; landscape gives sideways portrait pictures; an interrupt stops the device's stream and keeps the movie so far; the default backend fails on this phone | `record` works; `frames` is for devices | works since 2026-11-20, up to a minute, with sound by `--audio` (the sound fixes of 2026-11-21 not yet run here); a still screen sends no picture after five seconds, and since 2026-11-21 that no longer restarts a recording | `record` works | `record` works | works, with `--display` |
| **Apps**: `apps`, `launch`, `terminate`, `install`, `uninstall`, `open-url` | works | works | works | works | works (Ultra) | works |
| **Files and reports**: `files`, `reports` | works | — | works | — | — | — |
| **Settings**: `rotate`, `settings`, `location`, `status-bar`, `clipboard` | works; `status-bar` refused (a device does not support it) | works (iPhone, 2026-11-21) | not run | not run | not run | not run |
| **Build and run**: `build-run` | works | works | works | not run | not run | not run |
| **App output**: `console`, `last-crash`, `logs` | works | works | works (`logs` on the paired tunnel) | not run | works | works |
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
| Logs | The device's log relay, on the tool's own tunnel or Apple's | `logs` on a device | Works on the phone since 2026-11-20, on both tunnels, and on the Apple TV on its paired tunnel since 2026-11-21 |
| Accessibility, route 1: **the tool's own tunnel** | A tunnel the tool opens itself, through the Mac's `usbmuxd` | A device `manzanero devices` shows as `ownTunnel: cable`, `network` or `paired`: the iPhone and iPads; and an Apple TV after `manzanero pair`, which pairs the tool itself with it (PIN on the television) | The default since 2026-11-19. Works on the iPhone and, since 2026-11-20, on the Apple TV, with no side effect on the Mac |
| Accessibility, route 2: **Apple's tunnel** | The tunnel macOS keeps, plus a second connection of the tool's own to the device's list of services | The fallback on an iPhone or iPad; never for an Apple TV since 2026-11-21, by the human owner's decision (an Apple TV's accessibility needs `manzanero pair`) | Works. Side effect: the device resets the Mac's own connection to it, and now and then that connection does not come back until it is replaced |
| Accessibility, route 3: **the Inspector's way** | Through the Mac's `remoted`, as Apple's Accessibility Inspector does | `press` on the Apple TV, after the tool's own tunnel; nothing comes after it | Works with no side effect and without moving the focus. Rows inside lists, a full tree, `scroll` and `set-value` have no way there: on an Apple TV they need route 1 and are refused without it |
| Accessibility on a simulator | Apple's simulator framework | Every simulator | Settled |

A result says which accessibility route a command took: `serviceDirectory: own-tunnel` is route 1, `opened`, `reused-port` or `reused-saved-port` are route 2, and `route: inspector` is route 3. A press on an Apple TV that passed a route by says why: `ownTunnelUnavailable` for route 1 and `inspectorUnavailable` for route 3.

## What is open, in order

The same order as the roadmap's [next list](roadmap.md#next-in-the-order-suggested).

1. **A release** of the work of 2026-11-21 and 2026-11-22, which is in no beta yet.
2. **Apple TV, loose ends**: the pairing after a restart, and `remote sleep` from a screen saver (no screen saver started in 20 idle minutes on 2026-11-22). The pairing two days on and three quiet minutes with sound ran that day.
3. **An install on a tester's Mac**: v0.1.0-beta.2 is installed on the development Mac only; a tester needs Xcode 27, launched once.
4. **Watch typing**: a real watch; other keyboard languages work since 2026-11-22 (simulator), and accents will not be built (the human owner's decision).
5. **Hardware never used**: a second iPhone, an iPad, an Apple Watch, an iPhone Duo.

Still the human owner's to decide: signing and notarization.

## Done on 2026-11-22 (not released)

- **Recording, the two choices**: an interrupted recording keeps its movie as partial (exit 130/143, the path on stderr); another viewer taking the screen ends a recording with `stopCause: another-viewer`, with no wait.
- **Web pages**: an app's own web view inset from the screen's corner, and `scroll` on a page, work on the phone and a simulator (the iOS probe's new web screen), after two fixes; a field zoomed past the display's edge is pressed on the phone.
- **Sound in recording recovery**: a recording with `--audio` restarts after a lost stream, its sound stream started again; seen once on the phone across a pulled cable.
- **The phone checks owed**: keys, several contacts, `frames` and recording in both landscapes; `--with-value` on the Settings search field; a secure field's masked receipt; a cable pulled and a Wi‑Fi path lost during input, both ending in quarantine (the phone released a held contact at the screen's corner, `[0,0]`).

## Done on the night of 2026-11-21 (not released)

- **The iPhone cable checks**: an action in flight fails once and is not repeated; a `batch` stops at the step in flight; `frames` and `record` recover across a pulled cable.
- **Recording**: `frames` recovers as `record` does; an interrupt stops the device's stream; a still Apple TV screen no longer restarts a recording; Device Hub taking the screen ends a recording as `partial` and is left alone.
- **Sound**: in step with the picture and to the end of the recording (two faults fixed: a 1.7% drift and a stream that ended after 30 s); the iOS probe flashes with its beeps to measure it.
- **Web pages**: Safari on the phone works by label; on a simulator a Safari page is acted on with `--pid <page>`.
- **Smaller**: `devices` shows paired devices (`ownTunnel: paired`); the watch types its symbols page; searches run in four directions on the phone; iPadOS's four-contact cancel is a limit of iPadOS; the accessibility socket's failures have error categories.

## Done later on 2026-11-21 (not released)

- **New commands**: `launch` options and `terminate` by bundle, `--match contains|regex` for selectors, `rotate`, `settings`, `location`, `status-bar`, `clipboard`, `double-tap`, `create-simulator`. All ran on simulators, and on the iPhone all that apply to a phone (`status-bar` is refused there).
- **A phone in landscape**: accessibility, a tap and a screenshot work on the iPhone.
- **Recording recovery**: a recording on the iPhone survived a pulled cable as one movie with the gap listed; one that cannot recover keeps what it captured.
- **Watch typing**: `type` taps the watch's on-screen keyboard (simulator).
- **A completeness run** on iPad, iPhone Duo and Apple Watch simulators filled most of their columns above, with three fixes (Duo letterboxed press, watch list search, `detect-layout` refused on a watch).
- **On the iPhone too**: `batch` and an MCP session over the network, and a `wait` that survived a pulled cable.
- **Apple TV**: the `press` order (the tool's paired tunnel, then the Inspector's cursor) and `logs` ran on the device; the dead pairing was removed; Apple's tunnel is no longer used for an Apple TV, after it left the connection stale once more.

## Done on 2026-11-21

- **v0.1.0-beta.2** published and in the Homebrew tap: one Apple silicon archive with everything below and since 2026-11-18.
- **`press` on an Apple TV** goes by the tool's own tunnel first, then the Inspector's cursor (both run on the device on 2026-11-21); Apple's tunnel is no longer used for an Apple TV.
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
