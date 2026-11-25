# Manzanero

Manzanero lets you inspect and control Apple devices from your Mac, either through terminal commands or an AI agent. Use it to capture screens, read on-screen controls, tap, swipe, type, manage apps and record test sessions. Its command-line interface and optional MCP server share the same operations, using Apple developer tools and frameworks.

The project is in beta.

Physical iPhone control is the current priority, and reliable unattended testing is still unfinished. iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope, with support varying by device and operation.

Most live evidence comes from one iPhone 13 mini; one Apple TV 4K runs almost every command too. One iPad, one Apple Watch and one iPhone Duo have run inside the project's own probe apps (the watch and the Duo every command family that stays in the probe; the Duo folded and unfolded). See [status at a glance](docs/status.md) for one table of what works where, [feature status](docs/feature-status.md) before relying on another device or operation, and the [roadmap](docs/roadmap.md) for what is achieved and what is pending.

<img src="docs/assets/manzanero-clay.png" alt="A cheerful orchard worker biting an apple beside a tree growing a phone, a foldable iPhone Duo, a tablet, a watch and an Apple TV with its remote." width="560">

*Manzanero* is Spanish for an apple tree or a person who grows or gathers apples—a fitting name for a tool that tends to your Apple devices.

## Install the beta

```sh
brew install kikeenrique/tap/manzanero
manzanero doctor
```

Betas are published as prereleases on [GitHub](https://github.com/kikeenrique/manzanero/releases), each with its notes, and the Homebrew tap follows the newest: `brew install kikeenrique/tap/manzanero`. Each is one Apple silicon archive that states the requirements below; from v0.1.0-beta.3 its binaries are signed with a Developer ID and notarized, so a hand-downloaded copy runs too. See [beta installation](docs/beta-testing.md), [release preparation](docs/releasing.md) and the [public-readiness review](docs/public-readiness.md).

## Build and start

You need an Apple silicon Mac with macOS 26.6 or later and Xcode 27 or later selected, plus [mise](https://mise.jdx.dev/) and xcsift to build. Every device operation goes through Xcode's tools and frameworks, and Xcode 27 has no Intel build, so there is no Intel version. The package declares Swift 6.2 language support, but its pinned dependency graph currently requires the Swift 6.4 toolchain that Xcode 27 ships. `manzanero doctor` checks the Xcode and macOS minimums.

```sh
mise run build
mise run cli -- --help
mise run cli devices
mise run cli devices --simulators
mise run cli doctor
```

`mise run cli` runs the built executable; it does not build it. In the guides below, substitute `mise run cli` for bare `manzanero` when working from this checkout, or run `.build/debug/manzanero` directly. A source build does not install a global command. `manzanero <command> --help` describes one command; `mise run completions` writes shell completion scripts under `tmp/completions`.

Commands name the operation first and the target as an option: `--device <UDID>` for a physical device or `--simulator <UUID>` for a simulator. Set `MANZANERO_DEVICE` or `MANZANERO_SIMULATOR` to use one target for a whole session; an explicit option always wins. Replace angle-bracket placeholders with your values. For physical commands, choose the hardware UDID from the physical inventory, rather than a simulator UUID. Create output parent directories before capturing or copying files.

## Prepare a physical device

Pair and trust the Mac using Apple's normal setup. Enable Developer Mode and **Settings → Developer → Enable UI Automation** on the device. Keep it awake and unlocked for the verified UI flows; most were run in portrait, and the accessibility commands accept a phone in landscape since 2026-11-21. A phone with a passcode works; `wake` stops at the lock screen and never enters a passcode, and [`handoff --until unlocked`](docs/handoff.md#watching-the-device---until) waits for a person to unlock it. Setting a passcode on an already paired phone dropped its pairing once, so pair again if `readiness` reports it unpaired.

```sh
mise run cli readiness --device <hardware-UDID>
```

The top-level readiness status covers CoreDevice prerequisites. Inspect its separate `ui` report for display power and passcode observations. Neither report verifies UI Automation permission or proves that the current UI is unlocked. [Readiness guidance](docs/readiness.md) explains the fields and preparation steps.

## Observe, act, inspect again

```sh
mise run cli screenshot tmp/before.png --device <UDID>
mise run cli tree --device <UDID>
mise run cli tap 0.5 0.5 --device <UDID>
mise run cli screen auto --device <UDID>
```

Physical touch coordinates are normalized `0...1`, with the origin at the top left. Accessibility frames use logical points; screenshot dimensions use pixels. A dispatch receipt does not verify an action's effect. Inspect fresh state after every action, especially after an error or interruption.

| Need | Command or guide |
| --- | --- |
| What works where, in one table | [Status at a glance](docs/status.md) |
| Buttons, tap, swipe, drag, long press | [Physical input](docs/native-input.md); `double-tap` is a [preset](docs/gesture-sequences.md#presets) |
| Pinch or coordinated contacts | [Multitouch](docs/multitouch.md), [timed sequences](docs/gesture-sequences.md) |
| Text entry | [Typing in a named keyboard layout](docs/physical-typing.md) ([layout research](docs/keyboard-layouts.md), [finding the device's layout](docs/physical-typing.md#finding-the-layout-detect-layout)), [Unicode text by set-value](docs/simulator-input.md#unicode-text-set-value), [Unicode paste](docs/native-input.md#direct-unicode-paste) |
| Screen, hierarchy, OCR | [Screen inspection](docs/screen-understanding.md), [accessibility](docs/direct-accessibility.md) |
| Accessibility press or scroll by identifier, label or current value (`--with-value`), exact or by part or pattern (`--match contains\|regex`), and choosing among elements that share one (`--index`) | [Selector actions](docs/direct-accessibility.md#current-guarded-native-press) |
| Rotation, appearance and text size, a simulated location, status bar overrides, reading the clipboard | [Device settings](docs/device-settings.md) |
| Launching an app with arguments, environment, language or locale; terminating it by bundle identifier | `manzanero launch --help`, `manzanero terminate --help` |
| Reading and pressing a web page | [Web content](docs/direct-accessibility.md#web-content) |
| Video, with the device's sound if asked (`--audio`), or many screenshots in a row | [Recording](docs/recording.md), [sound](docs/recording.md#sound), [frames](docs/recording.md#frames-repeated-screenshots-from-one-stream), [recovery after a lost stream](docs/recording-recovery.md) |
| Build, install and launch an iOS app | [Build & Run](docs/build-run.md) |
| A step that needs a person (unlock, pairing, a permission prompt) | [Human handoff](docs/handoff.md): `handoff --until` watches the device and ends by itself |
| Several commands in one call | [`batch`](docs/mcp.md#several-steps-in-one-call-run_batch): up to 30 steps in order, stopped at the first failure; on a device or a simulator, [`hold` and `release`](docs/gesture-sequences.md#holding-a-contact-across-steps) keep a contact down across steps |
| Input sent to a locked phone | [Lock state in receipts](docs/native-input.md#receipts-and-partial-effects) |
| The same on a booted simulator | [Simulator input and accessibility](docs/simulator-input.md) |
| Apple TV, Apple Watch and iPhone Duo simulators: displays, fold, remote, Digital Crown, typing on a watch's on-screen keyboard | [Other families](docs/other-families.md) |
| A physical Apple Watch: Digital Crown, side and Action buttons, typing by the on-screen keys, and recording its H.264 screen, checked inside the project's watchOS probe | [Other families](docs/other-families.md#digital-crown-and-side-button-apple-watch), [watchOS probe](docs/probe-app.md#watchos-probe) |
| A physical iPhone Duo: every command follows the display in use, folded or unfolded, with touch on each display's own touchscreen | [Other families](docs/other-families.md#a-physical-iphone-duo) |
| A new simulator of a named type and runtime | `manzanero create-simulator --help` |
| Restarting a device or a simulator | `manzanero reboot --help` (MCP `reboot_device`) |
| A device's installed profiles, such as Apple's watchOS logging profile | `manzanero profile list --help`, `manzanero profile remove --help` |
| A physical Apple TV: trees with focus, the Siri Remote and its swipes, recording, `remote sleep` and `remote wake` | [A physical Apple TV](docs/other-families.md#a-physical-apple-tv), [sleep and wake](docs/other-families.md#sleep-and-wake) |
| Seeking in Apple's player on an Apple TV: arrows, swipes and `scrub --to <time>` | [Seeking](docs/other-families.md#seeking-in-apples-player) |
| How a command reaches a device, and the tool's own tunnel | [Transport](docs/transport.md), [the services a device offers](docs/device-services.md) |
| A row further down a long list | [`scroll --search`](docs/direct-accessibility.md#searching-a-list-that-loads-its-rows---search) |
| Why the app misbehaved: its unified log, stdout/stderr, last crash | [App logs, console and crashes](docs/app-logs.md) (`logs` for one process, a group or all, with filters, on simulators and devices, debug lines included on a device, and on an Apple Watch with [Apple's logging profile](docs/app-logs.md#an-apple-watch); `console`; `last-crash`) |
| What a failure means and whether to retry | [Errors and exit codes](docs/errors.md) |
| An Apple TV: pair the tool with it once (`manzanero pair`); its accessibility commands need that pairing, because Apple's tunnel is not used for an Apple TV | [A pairing of the tool's own](docs/transport.md#a-pairing-of-the-tools-own) |
| Input refused as `device-quarantined` | [Quarantine and `clear-quarantine`](docs/native-input.md#quarantine-after-an-uncertain-release) |

Physical input, accessibility and native video need no separate device helper. The CLI has no routes to AXe, idevice or ipb executables, and the process runners refuse them at runtime. Simulator app/lifecycle/capture commands use `simctl`; simulator trees, element actions, waits, touch with one to five contacts, gesture sequences, buttons, keys, typing and `set-value` run in process on a booted simulator ([simulator input](docs/simulator-input.md)). Simulator `wake` and `paste` are refused.

## Apps, files and reports

These commands use the selected Xcode's `devicectl`:

```sh
mise run cli apps --device <device>
mise run cli processes --device <device>
mise run cli launch com.example.app --device <device>
mise run cli launch com.example.app --relaunch --env NAME=VALUE --device <device> -- -AppArgument YES
mise run cli terminate com.example.app --device <device>
mise run cli install 'tmp/My App.app' --device <device>
mise run cli files list com.example.app Documents --device <device>
mise run cli files pull com.example.app Documents/data.json tmp/data.json --device <device>
mise run cli reports list --device <device>
mise run cli reports get 'My App.ips' 'tmp/My App.ips' --device <device>
```

Container paths are relative; `.` means the selected domain's root. Listings are nonrecursive. Access depends on the app/device's authorization. Copies can overwrite destinations; these commands do not provide `.xcappdata` export, symbolication or whole-container replacement. `terminate` takes a bundle identifier on every platform, and a PID on a device; on a device the bundle must have exactly one running process. App arguments follow `--`, after every option of `manzanero`'s own.

Add `--dry-run` to a device command to print its plan as JSON without contacting the device; `devices`, `doctor`, `keyboard-layouts`, `ocr` and `mcp` refuse it as a usage error, although their help lists the option. Most physical wrappers preserve `devicectl` JSON; some simulator commands return plain text. A failure prints its message on stderr and exits 1, or 64 when the call itself is wrong; with `--error-format json` (or `MANZANERO_ERROR_FORMAT=json`) it prints one JSON object instead, with a category, whether input may have reached the device, and whether a retry is safe. See [errors](docs/errors.md).

## MCP

Configure your host to launch the executable by absolute path with argument `mcp`. The server shares the CLI's operations and backend limits.

```json
{
  "mcpServers": {
    "manzanero": {
      "command": "/absolute/path/to/manzanero",
      "args": ["mcp"]
    }
  }
}
```

Host configuration formats vary. Set a suitable working directory: relative files and temporary artifacts are created there. The host controls approvals; the server has no approval UI of its own. The server has 55 tools; see [MCP tools and lifecycle](docs/mcp.md).

## Limits that matter

- Native input and AX actions are experimental. Successful transport acknowledgements are not UI assertions.
- Native video has scoped CLI/MCP verification, including one five-minute capture and one recording with AX inspection and Home control. With the macOS firewall on, the executable needs an allow rule or recordings get no video; `doctor` reports it ([recording](docs/recording.md#the-macos-firewall-can-drop-the-video)). A recording without `--audio` restarts a lost stream up to three times and keeps one movie with its gaps listed, and one that cannot recover keeps what it captured as `status: partial`; it recovered across a pulled cable on the test phone. `frames` restarts the same way, and so does a recording with sound since 2026-11-22, checked on the test phone ([recovery](docs/recording-recovery.md)).
- SIGINT/SIGTERM and MCP EOF attempt owned cleanup. Forced exits and failed transports do not have a release guarantee: after one during an input, further input to that device is refused until you have looked at it and run `clear-quarantine` ([quarantine](docs/native-input.md#quarantine-after-an-uncertain-release)). A second `manzanero` process is refused input to a device another one is controlling.
- A recording carries the device's sound only with `--audio`, and an app may mute its own player while the screen is captured ([sound](docs/recording.md#sound)). Since 2026-11-21 the sound stays in step with the picture and lasts the whole recording; checked on the test phone, and for three quiet minutes on the Apple TV.
- `manzanero pair` leaves a pairing identity for the device under `~/Library/Application Support/manzanero/pairings/`. It is a private key: whoever can read it can open a tunnel to that device.
- A web page is read and pressed as a tree of its own, apart from the browser around it, and has been checked in Chrome, Safari and an app's own web view on the test phone ([web content](docs/direct-accessibility.md#web-content)). `set-value` does not change a web input; press it and `type`.
- Live screen mirroring, broad Apple-family coverage and several simulator/diagnostic paths remain incomplete.
- Screenshots, app lists, logs, clipboard data and artifacts under `tmp/` can contain private information. Do not commit or share them without review.

## For contributors

Run `mise run test` for local checks and `mise tasks validate` for task definitions. Device tests are opt-in and may mutate the selected device; read their help first.

Start with [architecture and dependencies](docs/dependencies.md), [development tasks](docs/development-tasks.md), the [roadmap](docs/roadmap.md) and [verification](docs/verification.md). The [live check plan](docs/live-check-plan.md) lists what still has to be run on hardware. Protocol and implementation references are collected in [accessibility notes](docs/accessibility-protocol.md), [transport notes](docs/transport.md) and the [AXe review](docs/axe-physical-review.md). The [probe app](docs/probe-app.md) is a fixture iOS app for measuring touch delivery, driven by the [touch measurement runner](docs/probe-touch-runner.md), and for checking [app log capture](docs/app-logs.md) and text entry against known values. Repository workflow rules are in [AGENTS.md](AGENTS.md); how the docs are kept consistent is in [documentation maintenance](docs/documentation-review.md), and CI history in the [CI review](docs/ci-review.md).

Research notes and proposals, kept as historical records with a status line at the top: [simulator input](docs/simulator-input-research.md), [app logs](docs/app-logs-research.md), [keyboard layouts](docs/keyboard-layouts.md), [other simulator families](docs/other-families-research.md), [folding the iPhone Duo](docs/duo-fold-research.md) and the [argument parser proposal](docs/cli-argument-parser-proposal.md).


## License

Manzanero is available under the [MIT license](license). Third-party components retain their respective licenses and notices in `ThirdParty/`.
