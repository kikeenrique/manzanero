# Manzanero

A Swift command-line tool for inspecting and automating Apple devices, with an optional MCP server for agents. It uses Apple developer tools and in-process Apple frameworks for device operations.

The project is in beta. Physical iPhone control is the current priority; complete feature parity and reliable unattended testing are still unfinished. iPhone, iPad, Apple Watch, Apple TV and iPhone Duo are in scope. Android is not. Most live evidence comes from one iPhone 13 mini; see [feature status](docs/PARITY-STATUS.md) before relying on another device or operation.

## Build and start

You need macOS 15+, a full selected Xcode installation, Swift 6.4+, [mise](https://mise.jdx.dev/) and xcsift. The package declares Swift 6.2 language support, but its pinned dependency graph currently requires a Swift 6.4 toolchain. Native physical video requires macOS 26+.

```sh
mise run build
mise run cli -- --help
mise run cli devices physical
mise run cli devices simulators
mise run cli doctor
```

`mise run cli` runs the built executable; it does not build it. In the guides below, substitute `mise run cli` for bare `manzanero` when working from this checkout, or run `.build/debug/manzanero` directly. A source build does not install a global command.

Replace angle-bracket placeholders with your values. For physical commands, choose the hardware UDID from the physical inventory, rather than a simulator UUID. Create output parent directories before capturing or copying files.

There is no published beta release or Homebrew formula yet. See [beta installation](docs/BETA-TESTING.md), [release preparation](docs/RELEASING.md) and the [public-readiness review](docs/PUBLIC-READINESS.md).

## Prepare a physical device

Pair and trust the Mac using Apple's normal setup. Enable Developer Mode and **Settings → Developer → Enable UI Automation** on the device. Keep it awake and unlocked for the verified UI flows.

```sh
mise run cli physical <hardware-UDID> readiness
```

The top-level readiness status covers CoreDevice prerequisites. Inspect its separate `ui` report for display power and passcode observations. Neither report verifies UI Automation permission or proves that the current UI is unlocked. [Readiness guidance](docs/READINESS.md) explains the fields and preparation steps.

## Observe, act, inspect again

```sh
mise run cli physical <UDID> screenshot tmp/before.png
mise run cli physical <UDID> tree
mise run cli physical <UDID> tap 0.5 0.5
mise run cli physical <UDID> screen auto
```

Physical touch coordinates are normalized `0...1`, with the origin at the top left. Accessibility frames use logical points; screenshot dimensions use pixels. A dispatch receipt does not verify an action's effect. Inspect fresh state after every action, especially after an error or interruption.

| Need | Command or guide |
| --- | --- |
| Buttons, tap, swipe, drag, long press | [Physical input](docs/NATIVE-INPUT.md) |
| Pinch or coordinated contacts | [Multitouch](docs/MULTITOUCH.md), [timed sequences](docs/GESTURE-SEQUENCES.md) |
| Text entry | [ASCII typing](docs/PHYSICAL-TYPING.md), [Unicode paste](docs/NATIVE-INPUT.md#direct-unicode-paste) |
| Screen, hierarchy, OCR | [Screen inspection](docs/SCREEN-UNDERSTANDING.md), [accessibility](docs/DIRECT-ACCESSIBILITY.md) |
| Exact accessibility press or scroll | [Selector actions](docs/DIRECT-ACCESSIBILITY.md#current-guarded-native-press) |
| Video | [Recording](docs/RECORDING.md) |
| Build, install and launch an iOS app | [Build & Run](docs/BUILD-RUN.md) |
| A step that needs a person | [Human handoff](docs/HANDOFF.md) |

Physical input, accessibility and native video need no separate device helper. AXe, idevice and ipb executables are blocked at runtime. Simulator app/lifecycle/capture commands use `simctl`; simulator input and hierarchy remain unavailable pending direct replacements.

## Apps, files and reports

These commands use the selected Xcode's `devicectl`:

```sh
mise run cli physical <device> apps
mise run cli physical <device> processes
mise run cli physical <device> launch com.example.app
mise run cli physical <device> terminate <positive-PID>
mise run cli physical <device> install 'tmp/My App.app'
mise run cli physical <device> files com.example.app Documents
mise run cli physical <device> pull com.example.app Documents/data.json tmp/data.json
mise run cli physical <device> reports
mise run cli physical <device> report 'My App.ips' 'tmp/My App.ips'
```

Container paths are relative; `.` means the selected domain's root. Listings are nonrecursive. Access depends on the app/device's authorization. Copies can overwrite destinations; these commands do not provide `.xcappdata` export, symbolication or whole-container replacement. Physical termination takes a PID; simulator termination takes a bundle identifier.

Use `--dry-run` before a planned command to inspect its arguments without executing it. Most physical wrappers preserve `devicectl` JSON; some simulator commands return plain text. CLI errors currently use stderr text and a nonzero exit code.

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

Host configuration formats vary. Set a suitable working directory: relative files and temporary artifacts are created there. The host controls approvals; the server has no approval UI of its own. See [MCP tools and lifecycle](docs/MCP.md).

## Limits that matter

- Native input and AX actions are experimental. Successful transport acknowledgements are not UI assertions.
- Native video has scoped CLI/MCP verification, including one five-minute capture and one recording with AX inspection and Home control. Startup remains intermittent; keyframe, crash and disconnect recovery are unfinished.
- SIGINT/SIGTERM and MCP EOF attempt owned cleanup. Forced exits, failed transports and multiple independent controllers do not have a release guarantee.
- Live screen mirroring, stable reusable element handles, broad Apple-family coverage and several simulator/diagnostic paths remain incomplete.
- Screenshots, app lists, logs, clipboard data and artifacts under `tmp/` can contain private information. Do not commit or share them without review.

## For contributors

Run `mise run test` for local checks and `mise tasks validate` for task definitions. Device tests are opt-in and may mutate the selected device; read their help first.

Start with [architecture and dependencies](docs/DEPENDENCIES.md), [development tasks](docs/DEVELOPMENT-TASKS.md), [roadmap](docs/ROADMAP.md) and [verification](docs/VERIFICATION.md). Protocol and implementation references are collected in [accessibility notes](docs/ACCESSIBILITY-PROTOCOL.md), [transport notes](docs/TRANSPORT.md) and the [AXe review](docs/AXE-PHYSICAL-REVIEW.md). Repository workflow rules are in [AGENTS.md](AGENTS.md).
