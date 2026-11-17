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
- `test:mcp-*` (`test:mcp-live` takes a simulator), `test:media-*`, `test:rsd-*`, `test:native-tunnel`, `test:cli-interrupt` and `test:probe-touch` need a real device or a named booted simulator and are opt-in; several send input or record.
- `--dry-run` prints a device command's plan without contacting it; `devices`, `doctor`, `keyboard-layouts`, `ocr` and `mcp` refuse it with exit 64. Read `mise run <task> --help` first and never run one against a device the user has not named.
- `mise run release <version>` pushes a tag that publishes through CI. Do not run it unless explicitly asked.
- The toolchain must be Swift 6.4+ (the resolved dependency graph requires it) even though the manifest's tools floor is 6.2.

## Architecture

One SwiftPM package, three targets: the `Manzanero` executable, the Objective-C `AppleDeviceBridge` target linked into it, and `ManzaneroTests`. `docs/dependencies.md` is the authoritative description.

- **One parser for both front ends.** The grammar is `manzanero <operation> [operands] (--device <UDID> | --simulator <UUID>)`, defined with Swift Argument Parser in `CLI.swift` (root, shared option groups, target resolution with `MANZANERO_DEVICE`/`MANZANERO_SIMULATOR`) and `CLICommands.swift` (one `ParsableCommand` per operation, with its help). `main.swift` calls `CLI.parse`, never the library's `main()`, and keeps the exit path: usage errors exit 64, other failures 1. `MCPServer.swift`/`MCPTools.swift` (stdio MCP) build a new-grammar argument array per tool and run it through the same parser with `CommandService.run`. An MCP tool is a hand-written schema plus that mapping, so a new operation is a command type plus its execution in `CommandService`, then exposed by both adapters. Generated help is the command reference; give each command an abstract and, where a caveat matters, a discussion.
- **`CommandService.execute` dispatches on a typed `CommandRequest`** (`CommandRequest.swift`). Each command type builds its request in `request(_ target:)`, which is where operands are validated by the operation's own type: `CoreDeviceInput.validated` (in-process physical input and AX), `SimulatorInput` (in-process simulator input and AX), `HandoffCommand`, `ScreenCommand`, `RecordingCommand`, `BuildRunCommand`, `AppDiagnosticsCommand`, and `DeviceOperation`/`DeviceCommand.plan` for the `devicectl`/`simctl` wrappers. The request also says whether a command is read-only (`isReadOnly`), which device the handoff pause sees (`addressed`) and whether it runs under the signal scope (`signalContext`). No code recognises argument arrays below the parser.
- **`coredevice` is the only physical backend for input and AX.** They have no backend option and always run in process. Recording is the one exception: `record --backend devicectl` (the default, which the test phone refuses) or `coredevice`; `frames` uses the same in-process stream as `coredevice` recording.
- **Simulators share the physical code, not a fork of it** (`docs/simulator-input.md`). Input sends the same Indigo dictionaries through the same bridge schedulers over host XPC to the simulator's `dtuhidd` (`AppleSimulatorBridge.m`, `DirectSimulatorInput`). Trees, selector actions and waits run the physical `DirectAccessibilityAction`, `AccessibilitySelector`, `AccessibilityWait` and `DirectPhysicalAccessibility.capture` over the `AccessibilityExchange` protocol, implemented by the DTX `AccessibilitySession` and by `SimulatorAccessibilitySession` (CoreSimulator `sendAccessibilityRequestAsync:`). Per-platform result wording lives in `AccessibilityPlatform`; its physical values must stay the strings physical commands print. `SimulatorEnvironment` injects the simulator lookup, display information and bridge calls for tests. Touch maps the current interface with the simulator's display orientation exactly as physical touch does. Simulator paste and wake are refused. Unicode entry is `set-value` on both platforms (`DirectAccessibilitySetValue` over `AccessibilityValueSetting`).
- **Other simulator families** add to the same route rather than fork it: `SimulatorRemote` (Apple TV), `SimulatorCrown` (Apple Watch), `SimulatorHinge` and `SimulatorDisplays` (iPhone Duo fold, display choice and the interface display that touch, trees and captures follow). See `docs/other-families.md`.
- **Typing in a named layout** builds its tables from the Mac's own keyboard layouts (`KeyboardLayout.swift`; every Text Input Sources and `UCKeyTranslate` call runs under one lock, because concurrent calls crashed); `detect-layout` is `LayoutDetection.swift`. A phone's layout cannot be read.
- **Ownership.** `DeviceLease` takes a per-device advisory file lock for input, AX actions, native recording and `frames`, shared within one process and refused to another. The registry also keeps the quarantine mark: after a touch, button or key input with an unknown outcome, or an input owner that exited without releasing, input is refused as `device-quarantined` until `clear-quarantine` (`DeviceQuarantine`, `docs/native-input.md#quarantine-after-an-uncertain-release`); it is host-side only and sends the device nothing. In MCP, `MCPSessionTransport` holds requests behind `initialize` and `MCPCallOrdering` runs each device's mutations in arrival order (`docs/mcp.md#calls-sent-without-waiting`).
- **`doctor`'s private-interface table** (`Sources/AppleDeviceBridge/AppleInterfaceAvailability.m`) lists every dynamically resolved interface per capability; when an operation's guard changes, update the table and `docs/dependencies.md`.
- **Every branch has a `--dry-run` plan** that returns JSON describing the invocation without querying or touching a device. Add one with each new operation; most unit tests assert on these plans and on parsers/encoders rather than on live devices.
- **Process execution goes through `ToolRunner` (synchronous) or `StreamingToolRunner` (async, Swift Subprocess).** Both call `DeviceExecutablePolicy.validate`, which rejects anything outside Apple system binary directories (plus `remotectl`, and `xcsift` for build logs). This is the runtime enforcement of the dependency rule below; do not widen it to make a helper work.
- **In-process native paths** (`DirectPhysical*`, `DirectSimulator*`, `Simulator*`, `Native*`, `Accessibility*`, `Media*`, `RSD*`) implement input scheduling, AX DTX encoding/parsing, RSD discovery, and RTP/HEVC assembly and encoding in Swift. Anything that needs private Apple symbols, sockets or owner lifetimes goes through the C functions declared in `Sources/AppleDeviceBridge/include/AppleDeviceBridge.h` (prefix `ADC`); keep private-interface use behind that header.
- **Cancellation and cleanup are part of the contract.** `CLIInputSignals` turns SIGINT/SIGTERM into cancellation with owned release (exit 130/143); `MCPToolOperations` closes admissions, cancels and drains on EOF with a 30-second forced-exit deadline. A pending handoff pauses non-observation commands for that device via `checkHandoffPause`.
- **Handoff has three ways to end** (`HandoffCommand.swift`, `docs/handoff.md`). With `--until` (`HandoffCondition`), `CommandService.watchHandoff` polls the device read-only for `unlocked`, `paired` or a `wait` condition and ends by itself; prefer it, and add a condition there when a new kind of step can be seen on the device. Otherwise a person answers: at a terminal (`TerminalHandoff`), or in an MCP host's form (`MCPHandoffChannel`), which has no fields because hosts add their own Accept and Decline, and whose message is three lines because one host shows no more. Do not add a field or a line to that form without seeing how a host draws it.
- **Selectors are exact, with `--index` for ties** (`AccessibilitySelector` in `DirectAccessibilityAction.swift`): the nth distinct match in node order, carried as a trailing `--index <n>` operand and shared by `press`, `scroll`, `set-value` and `wait`. A hosted process, such as web content inside a browser, answers its snapshot rooted at the host's `AXRemoteElement`; `AccessibilitySnapshot.normalize` accepts that one shape (`docs/direct-accessibility.md#web-content`).
- **Physical input receipts say whether the device was locked.** `CommandService.executePhysical` passes each receipt through `DeviceUIReadiness.annotateInput`, one lock-state query after the input (`passcodeRequired`, `lockNote`). Input is gated on the display being on, not on the lock.
- **The retired helper backends (AXe, the Rust idevice bridge, ipb helpers) are gone**, together with their CLI routes, sources, patches and build tasks; git history has them. Do not keep unreachable code as reference. `DeviceExecutablePolicy` still refuses those binaries.
- Temporary process output is written under `./tmp` relative to the current working directory, including by tests.
- **The probe app** (`Fixtures/ProbeApp/`, `docs/probe-app.md`) is the ground truth for touch delivery, log capture and text entry, and raises a real permission prompt on demand (`probe.permission.request`); `mise run probe-app:test` runs its tests on macOS, and `test:probe-touch` drives its measurement runner.

`docs/verification.md` records what has actually been observed on a device; `docs/feature-status.md`, `docs/roadmap.md` (achieved and pending) and `docs/live-check-plan.md` (hardware runs still owed) summarise it and must agree with each other. Update them rather than implying coverage from a passing build.

## Dependencies

- Device operations must communicate with Apple frameworks/APIs from this project's code or use Apple-provided executables. Do not invoke non-Apple device-control executables, including AXe, idevice, or ipb helpers.
- Use third-party device projects as implementation references. Prefer existing Apple frameworks and maintained general-purpose libraries over custom infrastructure where appropriate.
- Ask the user before adding third-party dependencies that have not already been authorized. Preserve licenses and attribution.

## Workflow

- Commit each completed task separately with a descriptive message. Verify the change before committing. If Git writes fail, report the error and do not claim a commit exists.
- Keep research, plans, protocol notes, and verification records in `docs/`. Keep the root README as the entry point and maintain its links.
- Put downloads, extracted binaries, temporary tools, caches, and generated investigation artifacts under the visible local `tmp/` directory. Do not use `.tmp/` or `/tmp` for task artifacts. Keep `tmp/` out of version control.
- Never commit credentials, local device data, or downloaded commercial app binaries.
- Record standing instructions and lessons in this file (or a file under `docs/` linked from here when they grow), not in an agent's private memory.

### Delegated agents and git history

- Agents that change the repository work one at a time, directly in the main checkout on `main`. Do not give an agent its own git worktree or side branch, and do not run two writing agents at once; run them one after the other. A read-only research agent that writes only under `tmp/` may run beside one writer.
- Keep `main` a single line: no merge commits.
- Do not rewrite history (rebase, cherry-pick onto a new line, moving a branch) without asking the owner first, even for commits that were never pushed.
- If a stray worktree or branch exists, remove it once its work is on `main`, and say what a git viewer will show until then.
- Why: on 2026-11-16 parallel agent worktrees, a merge commit and a later history rewrite left the day's commits showing twice in the owner's git viewer, as if the work were at risk.

### Stuck Apple device services

- When every query to a connected device times out, capture evidence before restarting `CoreDeviceService` or `remotepairingd`: a wide `log show` (or `log stream`) window for both and a `sample` of each process, saved under `tmp/`. `mise run diagnose:device-services` does exactly that. Then ask before restarting them. On 2026-11-16 a restart fixed such a hang but nothing had been captured, so the cause is unknown.

## Implementation and validation

- Use Swift 6.2 or later and preserve strict concurrency checking.
- Invoke external tools with argument arrays, without shell interpolation of user input. Keep CLI stdout suitable for the documented machine-readable format and diagnostics on stderr.
- Run applicable build checks through `xcsift`; use meaningful tests for protocol encoding, parsing, and process behavior.
- Check installed tool help or authoritative sources before relying on Apple tool flags or private protocol details.
- Record OS/tool versions and limitations for device integration checks. A successful build or dry run does not prove live-device functionality.
- Look before you say what a device shows. Take a screenshot or a tree before telling the owner that something is on the screen, and again after an action; on 2026-11-17 a prompt was reported as "should now be on the phone" without a look, and the owner had to ask for the check.
- A device session covers the device and the apps the owner named. Ask before opening a third-party website, another of the owner's apps, or changing a setting; on 2026-11-17 a browser and two public sites were used without asking.
- An MCP host keeps running the server binary it started. After a rebuild, have the owner reconnect the server before testing a change through the host.
