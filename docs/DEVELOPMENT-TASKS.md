# Development tasks

Executable Bash task files live under `mise/tasks/`. `mise.toml` selects that directory and keeps shared Swift/Rust environment templates and the pinned Rust version. No task commands remain inline in that file.

| Files | Task names |
| --- | --- |
| `mise/tasks/build`, `mise/tasks/cli` | `build`, `cli` |
| `mise/tasks/test/_default` | `test` |
| `mise/tasks/test/mcp-*` | `test:mcp-*` |
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
