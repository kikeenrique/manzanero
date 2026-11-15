# Development tasks

Executable Bash tasks live under `mise/tasks/`. `mise.toml` selects that directory and defines shared environment templates; task names use directory namespaces.

```sh
mise run build
mise run test
mise run cli -- --help
mise run cli --dry-run physical fixture key backspace
mise tasks
mise tasks validate
```

`cli` forwards literal arguments to the built executable and does not build it. Swift build/test tasks use xcsift and pipefail, so a formatter's success cannot hide a failed compiler command.

## Task groups

| Task | Purpose |
| --- | --- |
| `build`, `test`, `cli` | Main executable and local regression checks |
| `package`, `test:package`, `release:formula` | [Beta packaging](releasing.md), archive smoke and tap formula generation |
| `release <version>` | Check version/worktree/tag, then push the tag to publish a beta through CI |
| `test:mcp-*` | Real stdio integration; some read only, others mutate the selected device |
| `test:media-*`, `test:native-tunnel`, `test:rsd-*` | Opt-in native transport/media diagnostics |
| `probe-app:test`, `probe-app:generate` | [Probe app](probe-app.md) core and measurement-runner tests on macOS; Tuist workspace generation under `tmp/probe-app/generated` |
| `test:probe-touch <UDID>` | Opt-in [touch measurement](probe-touch-runner.md) against the foreground probe app; `--dry-run` contacts no device |

Use the installed task's argument help rather than guessing flags:

```sh
mise run test:mcp-readiness --help
mise run test:mcp-recording-interaction --help
mise run test:mcp-shutdown --help
```

## Choose a live check deliberately

| Example | Device effect |
| --- | --- |
| `test:mcp-readiness <UDID>` | Display/passcode and prerequisite reads; no input |
| `test:mcp-physical <UDID> <pid>` | Native AX read for an explicit PID |
| `test:mcp-foreground <UDID>` | Foreground AX plus screen inspection |
| `test:mcp-press <UDID> <identifier|label> <text>` | One native press, screenshots |
| `test:mcp-scroll <UDID> <identifier>` | One scroll-to-visible action and observed postcondition |
| `test:mcp-type <UDID> <text>` | Types into the current focus |
| `test:mcp-gesture <UDID> <file>` | Sends the complete supplied touch sequence |
| `test:probe-touch <UDID> --dry-run` | Prints the measurement plan and commands; no device contact |
| `test:probe-touch <UDID>` | Resets the probe app through AX, sends the plan's touches and pulls its log; stops if the probe is not foreground |
| `test:mcp-recording <UDID>` | Two-second recording and subsequent screenshot |
| `test:mcp-recording-interaction <UDID>` | Launches Settings, records, reads AX and presses Home |
| `test:mcp-cancel-recording <UDID>` | Starts/cancels capture, then records again |
| `test:mcp-shutdown-recording <UDID> <mode>` | EOF/SIGINT/SIGTERM during recording, separate-process reuse |

Run these as `mise run <task> ...`. They use explicit targets and save private evidence under ignored `tmp/`. Passing receipt assertions is not a substitute for viewing the resulting UI where effect matters.

## Cancellation tests

`test:cli-interrupt` and `test:mcp-shutdown` send a signal or close an owned child during an explicit 8...10-second hold. The tests allow the runtime's cleanup grace before terminating a genuine stall. Expected normal exits are 0 for MCP EOF, 130 for SIGINT and 143 for SIGTERM.

`test:mcp-long-press ... --cancel` and `test:mcp-cancel-gesture` cancel a request after two seconds, then measure a follow-up readiness reply separately from screenshot latency. These test scoped interruption and service availability, not precise delivered hold duration or phone-side release.

## Task maintenance

`#MISE` headers declare descriptions, templates, dependencies and environment. `#USAGE` headers declare arguments. Scripts run from the repository root, including when invoked from a child directory.

`mise.toml` loads an optional, ignored `.env.local` from the repository root into every task. Use it for machine-local values such as `DEVELOPER_DIR` (to pin the Xcode the tasks use) and `DEVELOPMENT_TEAM` (for [probe app](probe-app.md) device signing). Never commit it.

Keep compiler/package caches, temporary tools and downloaded references under visible `tmp/`; build products use `.build/`. Never commit device artifacts or pairing records.

The main-push/pull-request CI runs task validation, the build and the Swift tests. It cancels superseded runs. CI and beta packaging share dependency and debug caches; release products have a separate cache. See [release workflows](releasing.md#ci-and-caching) for the paths and invalidation rules.

After editing task definitions, check Bash syntax, task discovery/help and `mise tasks validate`. Run the affected task when its behavior changed. The layout follows [mise file tasks](https://mise.jdx.dev/tasks/file-tasks.html).
