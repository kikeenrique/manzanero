# Manzanero

Manzanero lets you inspect and control Apple devices from your Mac, either through terminal commands or an AI agent. Use it to capture screens, read on-screen controls, tap, swipe, type, manage apps and record test sessions. Its command-line interface and optional MCP server share the same operations, using Apple developer tools and frameworks.

The project is in beta.

Physical iPhone control is the current priority, and reliable unattended testing is still unfinished. iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope, with support varying by device and operation.

Most live evidence comes from one iPhone 13 mini; see [feature status](docs/feature-status.md) before relying on another device or operation.

<img src="docs/assets/manzanero-clay.png" alt="A cheerful orchard worker biting an apple beside a tree growing a phone, a foldable iPhone Duo, a tablet, a watch and an Apple TV with its remote." width="560">

*Manzanero* is Spanish for an apple tree or a person who grows or gathers apples—a fitting name for a tool that tends to your Apple devices.

## Build and start

You need macOS 15+, a full selected Xcode installation, Swift 6.4+, [mise](https://mise.jdx.dev/) and xcsift. The package declares Swift 6.2 language support, but its pinned dependency graph currently requires a Swift 6.4 toolchain. Native physical video requires macOS 26+.

```sh
mise run build
mise run cli -- --help
mise run cli devices
mise run cli devices --simulators
mise run cli doctor
```

`mise run cli` runs the built executable; it does not build it. In the guides below, substitute `mise run cli` for bare `manzanero` when working from this checkout, or run `.build/debug/manzanero` directly. A source build does not install a global command. `manzanero <command> --help` describes one command; `mise run completions` writes shell completion scripts under `tmp/completions`.

Commands name the operation first and the target as an option: `--device <UDID>` for a physical device or `--simulator <UUID>` for a simulator. Set `MANZANERO_DEVICE` or `MANZANERO_SIMULATOR` to use one target for a whole session; an explicit option always wins. Replace angle-bracket placeholders with your values. For physical commands, choose the hardware UDID from the physical inventory, rather than a simulator UUID. Create output parent directories before capturing or copying files.

There is no published beta release or Homebrew formula yet. See [beta installation](docs/beta-testing.md), [release preparation](docs/releasing.md) and the [public-readiness review](docs/public-readiness.md).

## Prepare a physical device

Pair and trust the Mac using Apple's normal setup. Enable Developer Mode and **Settings → Developer → Enable UI Automation** on the device. Keep it awake and unlocked for the verified UI flows.

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
| Buttons, tap, swipe, drag, long press | [Physical input](docs/native-input.md) |
| Pinch or coordinated contacts | [Multitouch](docs/multitouch.md), [timed sequences](docs/gesture-sequences.md) |
| Text entry | [Typing in a named keyboard layout](docs/physical-typing.md) ([layout research](docs/keyboard-layouts.md), [finding the device's layout](docs/physical-typing.md#finding-the-layout-detect-layout)), [Unicode paste](docs/native-input.md#direct-unicode-paste) |
| Screen, hierarchy, OCR | [Screen inspection](docs/screen-understanding.md), [accessibility](docs/direct-accessibility.md) |
| Exact accessibility press or scroll | [Selector actions](docs/direct-accessibility.md#current-guarded-native-press) |
| Video, or many screenshots in a row | [Recording](docs/recording.md), [frames](docs/recording.md#frames-repeated-screenshots-from-one-stream) |
| Build, install and launch an iOS app | [Build & Run](docs/build-run.md) |
| A step that needs a person | [Human handoff](docs/handoff.md) |
| The same on a booted simulator | [Simulator input and accessibility](docs/simulator-input.md) |
| Apple TV, Apple Watch and iPhone Duo simulators: displays, fold, remote, Digital Crown | [Other simulator families](docs/other-families.md) |
| Why the app misbehaved: its unified log (simulator), stdout/stderr, last crash | [App logs, console and crashes](docs/app-logs.md) (`logs`, `console`, `last-crash`; physical console unverified) |

Physical input, accessibility and native video need no separate device helper. The CLI has no routes to AXe, idevice or ipb executables, and the process runners refuse them at runtime. Simulator app/lifecycle/capture commands use `simctl`; simulator trees, element actions, waits, single-contact touch, Home/lock, keys and typing run in process on a booted simulator ([simulator input](docs/simulator-input.md)).

## Apps, files and reports

These commands use the selected Xcode's `devicectl`:

```sh
mise run cli apps --device <device>
mise run cli processes --device <device>
mise run cli launch com.example.app --device <device>
mise run cli terminate <positive-PID> --device <device>
mise run cli install 'tmp/My App.app' --device <device>
mise run cli files list com.example.app Documents --device <device>
mise run cli files pull com.example.app Documents/data.json tmp/data.json --device <device>
mise run cli reports list --device <device>
mise run cli reports get 'My App.ips' 'tmp/My App.ips' --device <device>
```

Container paths are relative; `.` means the selected domain's root. Listings are nonrecursive. Access depends on the app/device's authorization. Copies can overwrite destinations; these commands do not provide `.xcappdata` export, symbolication or whole-container replacement. Physical termination takes a PID; simulator termination takes a bundle identifier.

Add `--dry-run` to a planned command to inspect its arguments without executing it. Most physical wrappers preserve `devicectl` JSON; some simulator commands return plain text. A failure prints its message on stderr and exits 1, or 64 when the call itself is wrong; with `--error-format json` (or `MANZANERO_ERROR_FORMAT=json`) it prints one JSON object instead, with a category, whether input may have reached the device, and whether a retry is safe. See [errors](docs/errors.md).

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

Host configuration formats vary. Set a suitable working directory: relative files and temporary artifacts are created there. The host controls approvals; the server has no approval UI of its own. See [MCP tools and lifecycle](docs/mcp.md).

## Limits that matter

- Native input and AX actions are experimental. Successful transport acknowledgements are not UI assertions.
- Native video has scoped CLI/MCP verification, including one five-minute capture and one recording with AX inspection and Home control. Startup remains intermittent; keyframe, crash and disconnect recovery are unfinished.
- SIGINT/SIGTERM and MCP EOF attempt owned cleanup. Forced exits and failed transports do not have a release guarantee. A second `manzanero` process is refused input to a device another one is controlling.
- Live screen mirroring, stable reusable element handles, broad Apple-family coverage and several simulator/diagnostic paths remain incomplete.
- Screenshots, app lists, logs, clipboard data and artifacts under `tmp/` can contain private information. Do not commit or share them without review.

## For contributors

Run `mise run test` for local checks and `mise tasks validate` for task definitions. Device tests are opt-in and may mutate the selected device; read their help first.

Start with [architecture and dependencies](docs/dependencies.md), [development tasks](docs/development-tasks.md), [roadmap](docs/roadmap.md) and [verification](docs/verification.md). Protocol and implementation references are collected in [accessibility notes](docs/accessibility-protocol.md), [transport notes](docs/transport.md) and the [AXe review](docs/axe-physical-review.md). The [probe app](docs/probe-app.md) is a fixture iOS app for measuring physical touch delivery, driven by the [touch measurement runner](docs/probe-touch-runner.md), and for checking [app log capture](docs/app-logs.md) against known lines ([research](docs/app-logs-research.md)). Repository workflow rules are in [AGENTS.md](AGENTS.md).


## License

Manzanero is available under the [MIT license](license). Third-party components retain their respective licenses and notices in `ThirdParty/`.
