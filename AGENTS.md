# Repository instructions

Prefix shell commands with `rtk`. Use `rtk proxy` when unfiltered output is needed.

## Project

- Build `manzanero`, a Swift CLI for Apple-device inspection and control, with optional MCP support sharing the same operations.
- Open-source third-party libraries such as `idevice` are permitted. Preserve licenses and attribution. Do not use proprietary device-control binaries as runtime dependencies.
- Keep platform-specific and private interfaces behind backend boundaries. Distinguish implemented features from verified device behavior.

## Commands

Tasks are Bash scripts under `mise/tasks/` (directory namespaces become `group:task`); see `docs/development-tasks.md`.

```sh
mise run build                      # swift build through xcsift; a compiler warning fails it
mise run test                       # all Swift tests through xcsift; a compiler warning fails it
mise run cli -- --help              # run .build/debug/manzanero; does NOT build first
mise run cli tap 0.5 0.5 --device <UDID> --dry-run   # print the planned invocation, touch nothing
mise tasks validate                 # after editing task definitions
```

- The `test` task takes no arguments. Run one suite or test directly, keeping the task's cache path and formatter:
  `swift test --cache-path tmp/swift-cache --filter ToolRunnerTests 2>&1 | xcsift -f toon --warnings`
  (`--filter ToolRunnerTests/nonzeroExitIncludesDiagnostic` for one test). Tests use Swift Testing (`@Test`, `#expect`), not XCTest.
- Hosted runners have about three cores, so the test suite shares a three-thread cooperative pool. Do not spin-wait (`while … { await Task.yield() }`), bound waits with short wall-clock limits, or block a pool thread while another task must make progress; use `TestSignal`, `ManualTestClock` and `.dedicatedThread` from `Tests/ManzaneroTests/TestConcurrency.swift`. Reproduce starvation locally with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 mise run test`.
- CI runs exactly `mise tasks validate`, `build` and `test`. Run those before committing.
- `test:mcp-*`, `test:media-*`, `test:rsd-*`, `test:native-tunnel`, `test:cli-interrupt` and `test:probe-touch` need a real device or a named booted simulator and are opt-in; several send input or record. Read `mise run <task> --help` first and never run one against a device the user has not named.
- `mise run release <version>` pushes a tag that publishes through CI. Do not run it unless explicitly asked.
- The toolchain must be Swift 6.4+ (the resolved dependency graph requires it) even though the manifest's tools floor is 6.2.

## Architecture

One SwiftPM package, three targets: the `Manzanero` executable, the Objective-C `AppleDeviceBridge` target linked into it, and `ManzaneroTests`. `docs/dependencies.md` is the authoritative description.

- **One parser for both front ends.** The grammar is `manzanero <operation> [operands] (--device <UDID> | --simulator <UUID>)`, defined with Swift Argument Parser in `CLI.swift` (root, shared option groups, target resolution with `MANZANERO_DEVICE`/`MANZANERO_SIMULATOR`) and `CLICommands.swift` (one `ParsableCommand` per operation, with its help). `main.swift` calls `CLI.parse`, never the library's `main()`, and keeps the exit path: usage errors exit 64, other failures 1. `MCPServer.swift`/`MCPTools.swift` (stdio MCP) build a new-grammar argument array per tool and run it through the same parser with `CommandService.run`. An MCP tool is a hand-written schema plus that mapping, so a new operation is a command type plus its execution in `CommandService`, then exposed by both adapters. Generated help is the command reference; give each command an abstract and, where a caveat matters, a discussion.
- **`CommandService.execute` is an ordered chain of parsers.** Each parsed command converts itself into an argument vector (`legacyOperation`) that `execute` reads. Each `X.parse(args)` returns `nil` when the arguments are not its command, and the first match wins: native media status, `CoreDeviceInput` (in-process physical input and AX), `SimulatorInput` (in-process simulator input and AX), `HandoffCommand`, `ScreenCommand`, readiness, `RecordingCommand`, `BuildRunCommand`, then the generic `DeviceCommand` wrappers around `devicectl`/`simctl`. Order matters when adding a command.
- **`coredevice` is the only physical backend.** `CoreDeviceInput.selectDefaultBackend` marks native operations with an internal `--physical-backend coredevice` prefix; the CLI has no backend option.
- **Simulators share the physical code, not a fork of it** (`docs/simulator-input.md`). Input sends the same Indigo dictionaries through the same bridge schedulers over host XPC to the simulator's `dtuhidd` (`AppleSimulatorBridge.m`, `DirectSimulatorInput`). Trees, selector actions and waits run the physical `DirectAccessibilityAction`, `AccessibilitySelector`, `AccessibilityWait` and `DirectPhysicalAccessibility.capture` over the `AccessibilityExchange` protocol, implemented by the DTX `AccessibilitySession` and by `SimulatorAccessibilitySession` (CoreSimulator `sendAccessibilityRequestAsync:`). Per-platform result wording lives in `AccessibilityPlatform`; its physical values must stay the strings physical commands print. `SimulatorEnvironment` injects the simulator lookup, display information and bridge calls for tests. Touch maps the current interface with the simulator's display orientation exactly as physical touch does. Simulator paste and wake are refused; Unicode entry is the simulator-only `set-value`.
- **Every branch has a `--dry-run` plan** that returns JSON describing the invocation without querying or touching a device. Add one with each new operation; most unit tests assert on these plans and on parsers/encoders rather than on live devices.
- **Process execution goes through `ToolRunner` (synchronous) or `StreamingToolRunner` (async, Swift Subprocess).** Both call `DeviceExecutablePolicy.validate`, which rejects anything outside Apple system binary directories (plus `remotectl`, and `xcsift` for build logs). This is the runtime enforcement of the dependency rule below; do not widen it to make a helper work.
- **In-process native paths** (`DirectPhysical*`, `DirectSimulator*`, `Simulator*`, `Native*`, `Accessibility*`, `Media*`, `RSD*`) implement input scheduling, AX DTX encoding/parsing, RSD discovery, and RTP/HEVC assembly and encoding in Swift. Anything that needs private Apple symbols, sockets or owner lifetimes goes through the C functions declared in `Sources/AppleDeviceBridge/include/AppleDeviceBridge.h` (prefix `ADC`); keep private-interface use behind that header.
- **Cancellation and cleanup are part of the contract.** `CLIInputSignals` turns SIGINT/SIGTERM into cancellation with owned release (exit 130/143); `MCPToolOperations` closes admissions, cancels and drains on EOF with a 30-second forced-exit deadline. A pending handoff pauses non-observation commands for that device via `checkHandoffPause`.
- **The retired helper backends (AXe, the Rust idevice bridge, ipb helpers) are gone**, together with their CLI routes, sources, patches and build tasks; git history has them. Do not keep unreachable code as reference. `DeviceExecutablePolicy` still refuses those binaries.
- Temporary process output is written under `./tmp` relative to the current working directory, including by tests.

`docs/feature-status.md` and `docs/verification.md` record what has actually been observed on a device; update them rather than implying coverage from a passing build.

## Dependencies

- Device operations must communicate with Apple frameworks/APIs from this project's code or use Apple-provided executables. Do not invoke non-Apple device-control executables, including AXe, idevice, or ipb helpers.
- Use third-party device projects as implementation references. Prefer existing Apple frameworks and maintained general-purpose libraries over custom infrastructure where appropriate.
- Ask the user before adding third-party dependencies that have not already been authorized. Preserve licenses and attribution.

## Workflow

- Commit each completed task separately with a descriptive message. Verify the change before committing. If Git writes fail, report the error and do not claim a commit exists.
- Keep research, plans, protocol notes, and verification records in `docs/`. Keep the root README as the entry point and maintain its links.
- Put downloads, extracted binaries, temporary tools, caches, and generated investigation artifacts under the visible local `tmp/` directory. Do not use `.tmp/` or `/tmp` for task artifacts. Keep `tmp/` out of version control.
- Never commit credentials, local device data, or downloaded commercial app binaries.

## Implementation and validation

- Use Swift 6.2 or later and preserve strict concurrency checking.
- Invoke external tools with argument arrays, without shell interpolation of user input. Keep CLI stdout suitable for the documented machine-readable format and diagnostics on stderr.
- Run applicable build checks through `xcsift`; use meaningful tests for protocol encoding, parsing, and process behavior.
- Check installed tool help or authoritative sources before relying on Apple tool flags or private protocol details.
- Record OS/tool versions and limitations for device integration checks. A successful build or dry run does not prove live-device functionality.
