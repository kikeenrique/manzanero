# Development tasks

`mise run test:mcp-shutdown <UDID> <x> <y> <seconds> <EOF|SIGINT|SIGTERM>` stops an owned MCP process after two seconds of an explicit 8...10-second physical long-press. It checks normal exit 0/130/143 before eight seconds, absence of a late ordinary tool response and non-use of the force-exit path, then captures a separate screenshot. It preserves the runtime's cleanup grace before force-killing a stalled test child. Results and private images remain under ignored `tmp/`; process exit does not verify device-side contact release.

`mise run test:cli-interrupt <UDID> <x> <y> <seconds> <SIGINT|SIGTERM>` starts one owned CLI process with an 8...10-second physical long-press, sends the selected signal after two seconds and checks normal exit 130/143, early completion and empty stdout. It waits through the CLI's own cleanup grace before force-killing a stalled test child. Artifacts remain under `tmp/`; no release guarantee follows from process exit.

`mise run test:mcp-long-press <UDID> <x> <y> <seconds> --cancel` requests cancellation after two seconds of an 8...10-second Indigo long-press, then queues a readiness request through the same command actor. It checks that this reply arrives before eight seconds and that no ordinary cancelled-call response precedes it. A subsequent screenshot is timed separately. This is an explicit live action; it does not prove device-side contact release. Without `--cancel`, the task retains its normal full-hold verification behavior.

`mise run test:ax-socket <UDID> --remote-uuid <remote-UUID> --browse` explicitly compares Apple's one-shot discovery path with the existing direct RSD lookup. It verifies hardware identity and opens only the exact AX endpoint if advertised; it sends no subscription or input. `--browse` without a remote UUID is rejected. A failed probe remains a failure, not a capability result.

`mise run test:mcp-cancel-gesture <UDID> <local-sequence.json>` sends one 8...10-second direct gesture through real MCP, requests cancellation after two seconds, then queues a readiness request through the same command actor. It checks that the follow-up response arrives before eight seconds and that no ordinary response for the cancelled request precedes it. A subsequent screenshot is timed separately; artifacts remain under `tmp/`. This mutates the device; it does not establish device-side release or prove when the first contact arrived.

`mise run test:mcp-multitouch <UDID> <multi-tap|multi-drag> <comma-separated-operands>` sends one standalone direct multitouch command through the real MCP stdio server and saves a receipt and screenshot under `tmp/`. For `multi-drag`, the operands start with seconds, followed by three to five groups of start-x, start-y, end-x, end-y. For `multi-tap`, supply two to five x,y pairs. This is a live device mutation, not a dry run.

Executable Bash task files live under `mise/tasks/`. `mise.toml` selects that directory and keeps shared Swift/Rust environment templates and the pinned Rust version. No task commands remain inline in that file.

| Files | Task names |
| --- | --- |
| `mise/tasks/build`, `mise/tasks/cli` | `build`, `cli` |
| `mise/tasks/test/_default` | `test` |
| `mise/tasks/test/mcp-*` | `test:mcp-*` |
| `mise/tasks/test/ax-*` | `test:ax-*` (opt-in accessibility transport diagnostics) |
| `mise/tasks/coredevice/*` | `coredevice:*` |
| `mise/tasks/idevice/*` | `idevice:*` |

Run the same commands as before:

```sh
mise run build
mise run test
mise run cli -- --help
mise run cli -- --dry-run physical fixture key backspace
mise run test:mcp-key --help
mise tasks validate
```

`#MISE` headers declare description, template, dependencies and environment. `#USAGE` headers declare positional arguments and flags. Bash scripts use `set -e -o pipefail`, including build/test output piped through xcsift. The CLI task forwards literal arguments with `"$@"`. Rust scripts receive the configured pin as `APPLEDEVICES_RUST_VERSION`; they do not duplicate the version in their command bodies. All tasks run from the project root, including when invoked from a child directory.

Physical MCP verification tasks retain their explicit targets and device effects. Read their argument help before running them. Historical helper build tasks remain research material; moving them does not enable third-party device executables in the product.

The layout follows mise's [file task documentation](https://mise.jdx.dev/tasks/file-tasks.html), including namespace directories and `_default` for a task with subtasks. The refactor was validated with installed mise 2026.10.20: all 23 names, descriptions, dependencies, argument declarations, existing environment entries and command bodies were compared against the previous definitions. Shell syntax, task discovery, argument help, literal CLI forwarding, Swift build/tests and native sender tests were checked. This organizational change adds no device capability or new hardware-verification claim.
