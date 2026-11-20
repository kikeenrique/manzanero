# Status at a glance

One table of what works where, for a reader who wants the answer before the detail. It is a summary of [feature status](feature-status.md), which has the limits, and of [verification](verification.md), which has the evidence; when they disagree, they are right and this page is stale. Last brought up to date on 2026-11-20.

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
| **Apple TV remote**: `remote` | — | — | partly: all eight buttons and held keys work; held Home and swipes refused | works, with holds and swipes | — | — |
| **Watch crown**: `crown` | — | — | — | — | works | — |
| **Fold**: `fold`, `unfold`, `hinge`, `displays` | — | — | — | — | — | works |
| **Accessibility, read**: `tree`, `wait` | works, portrait only | works | works, see the routes below | works | works | partly: Home Screen tree is empty |
| **Accessibility, act**: `press`, `scroll`, `set-value` | works, portrait only | works | works, see the routes below | works | works (`press`) | partly: `press` fails in a letterboxed app |
| **Accessibility, search a long list**: `scroll --search` | not run | not run | works in four directions | works in four directions | not run | not run |
| **Pictures**: `screenshot`, `screen`, `ocr` | works | works | works | works | not run | works, with `--display` |
| **Video**: `record`, `frames` | works with `--backend coredevice`; the default backend fails on this phone | `record` works; `frames` is for devices | refused: the picture arrives blank; a fix is a pending task | `record` works | not run | works, with `--display` |
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
| Video | Apple's media stream, decoded in process | Devices | Works on the phone, blank on the Apple TV |
| Accessibility, route 1: **the tool's own tunnel** | A tunnel the tool opens itself, through the Mac's `usbmuxd` | A device `manzanero devices` shows as `ownTunnel: cable` or `network`: the iPhone and iPads, never an Apple TV | The default since 2026-11-19. Works on the iPhone, with no side effect on the Mac |
| Accessibility, route 2: **Apple's tunnel** | The tunnel macOS keeps, plus a second connection of the tool's own to the device's list of services | The fallback, and the only one in use for the Apple TV | Works. Side effect: the device resets the Mac's own connection to it, and now and then that connection does not come back until it is replaced |
| Accessibility, route 3: **the Inspector's way** | Through the Mac's `remoted`, as Apple's Accessibility Inspector does | Nothing yet: an experiment | Opens on the Apple TV with no side effect. A press worked on it; a full tree, `scroll` and `set-value` have no way there |
| Accessibility on a simulator | Apple's simulator framework | Every simulator | Settled |

A result says which accessibility route a command took: `serviceDirectory: own-tunnel` is route 1, and `opened`, `reused-port` or `reused-saved-port` are route 2.

## What is open, in order

1. **Push** the local commits.
2. **A test that failed once** (`aCancelledQueuedCallGivesUpItsPlace`) and could fail a CI run.
3. **Apple TV, accessibility without the side effect**: route 3 was tried in full on 2026-11-20. It pressed a button with no side effect and without moving the focus. It cannot give a tree: no positions, no focus, lists skipped. To decide: build `press` on it and leave the rest on route 2, or leave it as an experiment.
4. **Apple TV, video**: start an audio stream beside the video, as Apple's Device Hub does. Not started; it changes the code that owns a stream and its cleanup.
5. **Apple TV, the remote's swipes**: a lead to look at, the `universalhidservice` Apple's Device Hub uses with it.
6. **`logs` for devices**: the way in is proven, the command is not built.
7. **Small checks on the iPhone**: an action in flight when the cable is pulled, an agent session over the network, and `build-run` since it learned other platforms.
8. **Hardware never used**: an iPad, an Apple Watch, an iPhone Duo.
