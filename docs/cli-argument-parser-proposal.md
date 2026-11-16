# Proposal: adopt Swift Argument Parser and settle the command grammar

Status: accepted by the owner on 2026-11-16, with the choices recorded under [Decisions](#decisions). Nothing here is implemented yet; it is scheduled after the pending phone checks, with no other command work in flight.

## Recommendation

Adopt Apple's [Swift Argument Parser](https://github.com/apple/swift-argument-parser) for the CLI, and use the migration to change the grammar to **operation first, target as an option**:

```sh
manzanero tap 0.5 0.45 --device <UDID>
manzanero tap 0.5 0.45 --simulator <UUID>
manzanero press --label General --device <UDID>
manzanero wait --id probe.touch.summary --until gone --timeout 5 --simulator <UUID>
manzanero console com.example.app --seconds 10 --device <UDID> -- -someAppFlag
```

Keep every operation's behaviour, receipts, dry-run plans and error categories as they are. The work is in parsing, help and routing, not in what the commands do.

## Why now

- **The parsing is hand-written and growing.** There are 67 usage lines in a help string maintained by hand in `main.swift`, about 130 places that raise a usage error, and roughly 1,400 lines across `CommandService.swift`, `main.swift`, `CoreDeviceInput.swift`, `DeviceCommands.swift`, `SimulatorCommand.swift` and `MCPTools.swift` that exist partly to recognise arguments. The simulator work doubled the usage lines, because each platform spells its commands out again.
- **Parser order is implicit.** `CommandService.execute` tries a chain of parsers and the first match wins. Adding a command means knowing where in the chain it must go.
- **Nobody depends on the grammar yet.** The tool is unreleased, so changing how commands are spelled costs only our own docs, tasks and the measurement runner.
- **Things we would not write by hand come free:** per-command help, consistent messages for missing or malformed arguments, and shell completion.

## What was checked

A scratch program under `tmp/argparser-check/` tried both grammars against version 1.8.2 (revision `6a52f32`, Apache 2.0, Swift tools 6.0). Results:

| Question | Result |
| --- | --- |
| Can today's shape, a device positional before the operation, be expressed? | Yes. `physical <device> tap 0.5 0.5` and `physical <device> tree` parsed. So keeping the grammar is possible; changing it is a choice, not a necessity |
| Operation first with shared target options | Works, in any option order, through one shared option group |
| Arguments passed through to the app after `--` | Works with `@Argument(parsing: .postTerminator)` |
| Either `--id` or `--label`, exactly one | Works through `validate()` with our own message |
| Enumerated values such as `--until` | Rejected with a message listing the allowed values |
| Negative numbers as positionals | Accepted after `--`; our range check then rejects them |
| Parsing an argument array without exiting the process | `parseAsRoot(_:)` returns the typed command or throws; the exit code and message are available separately |
| Exit code for usage errors | 64, where the CLI uses 1 today |
| Generated help and zsh completion | Both produced |

Not checked: bash and fish completion, help output for deep subcommand trees, and how the library's own error wording reads for every one of our commands.

## Grammar options

**A. Keep today's grammar:** `manzanero physical <device> tap 0.5 0.5`.

- Least change to docs, tasks and the runner.
- Help reads awkwardly: the operation list hangs under `physical <device>`, and every operation exists twice, once per platform.
- The platform word is extra typing that the target option can carry.

**B. Operation first, one target option (recommended):** `manzanero tap 0.5 0.5 --device <UDID>` or `--simulator <UUID>`.

- One definition per operation. Its help says which targets it supports, and an unsupported target is one clear error instead of a missing command.
- The target is exactly one of `--device` or `--simulator`, so nothing has to guess a platform from the shape of an identifier.
- A default target can come from the environment (`MANZANERO_DEVICE`, `MANZANERO_SIMULATOR`), which suits scripts and agents that work on one device for a whole session. An explicit option always wins.
- Matches how Apple's own tools read (`devicectl device … --device`, `simctl <operation> <device>`).

**C. Operation first, platform inferred from the identifier.** Rejected: a CoreDevice identifier and a simulator identifier are both UUIDs, and resolving the difference costs a `devicectl` or `simctl` query on every call.

## Proposed command set under B

Operations that differ only by selector kind merge, since the option says which:

| Today | Proposed |
| --- | --- |
| `press-id`, `press-label` | `press (--id <id> \| --label <text>) [--pid <pid>]` |
| `scroll-id`, `scroll-label` | `scroll (--id \| --label) [--pid]` |
| `wait-id`, `wait-label` | `wait (--id \| --label) [--until …] [--value …] [--timeout …] [--interval …] [--pid]` |
| `set-value-id`, `set-value-label` | `set-value (--id \| --label) <text> [--pid]` |
| `swipe`, `drag` (same movement) | Both kept as names for one implementation |
| `tree [pid]` | `tree [--pid <pid>]` |
| `devices physical`, `devices simulators` | `devices [--simulators]` or two subcommands; see decisions |
| `physical <device> reports`, `report` | `reports list`, `reports get` |
| `files`, `pull`, `push` | `files list`, `files pull`, `files push` |
| `--physical-backend coredevice …` prefix | Dropped: there is one physical backend |
| `--recording-backend <devicectl\|coredevice> … record` | `record … --backend <devicectl\|coredevice>` |
| Global `--dry-run` and `--error-format` prefixes | Options accepted on every command, in any position |

Everything else keeps its name and operands: `tap`, `long-press`, `pinch`, `multi-tap`, `multi-drag`, `gesture`, `button`, `key`, `type`, `paste`, `wake`, `screenshot`, `screen`, `record`, `launch`, `terminate`, `install`, `uninstall`, `open-url`, `apps`, `processes`, `details`, `readiness`, `media-status`, `build-run`, `handoff`, `logs`, `console`, `last-crash`, `boot`, `shutdown`, `doctor`, `ocr`, `decode-ax-archive`, `mcp`.

## How it fits the code

- **Typed commands in front of the existing operations.** Each operation becomes a `ParsableCommand` struct that declares its arguments and converts itself into the request the operation code already takes (`CoreDeviceInput`, `AccessibilityWait`, `RecordingCommand`, and so on). `CommandService` then dispatches on a typed request instead of probing an argument array with a chain of parsers.
- **Domain validation stays where it is.** Range and shape checks with meaning (normalized coordinates, non-crossing two-contact paths, gesture JSON, selector rules) remain in the existing validators, called from each command's `validate()`. Their messages do not change. Only arity, unknown-option and type-conversion messages become the library's.
- **We call `parseAsRoot`, not the library's `main()`.** That keeps our own exit path: signal handling, the JSON error format, and exit codes 124, 130 and 143.
- **Errors.** A parse failure maps to the existing `usage` category with `inputSent: none` and `retry: no`. See the decision on its exit code.
- **MCP.** Tool schemas stay hand-written in `MCPTools.swift`; they are tuned for models and should not be generated from CLI metadata. Each tool's route changes from producing today's argument array to producing the new one, parsed by the same parser, so the CLI and MCP cannot drift apart. Building the typed command directly, without going through strings, is a later refinement.
- **Help.** The hand-written help string goes away. Each command carries a one-line abstract and, where a caveat matters at the point of use ("a receipt is not an effect", "replaces the clipboard"), a short discussion. Longer explanations stay in `docs/`.

## Migration plan

Each step leaves the tool working and is checked the same way: build, tests in both pool modes, and a comparison of dry-run plans for a fixed list of invocations before and after (the plans must be identical apart from intended wording).

1. **Add the dependency and a root command** that owns `--dry-run`, `--error-format`, `--help`, `--version`, `mcp`, `doctor`, `ocr`, `decode-ax-archive` and `devices`. Everything else is forwarded unparsed to the current code. Add the Apache notice to `ThirdParty/` and the package to the notice list in `mise/tasks/package`.
2. **Migrate observation commands:** `tree`, `screen`, `screenshot`, `readiness`, `details`, `apps`, `processes`, `media-status`, `wait`.
3. **Migrate input and element actions:** touch, multi-touch, `gesture`, `button`, `key`, `type`, `paste`, `wake`, `press`, `scroll`, `set-value`.
4. **Migrate app, file, report, recording, build and diagnostic commands,** and simulator lifecycle.
5. **Switch the MCP routes** to the new argument arrays and delete the old parsers and the help string.
6. **Update what spells commands out:** `readme.md`, the docs, `mise` tasks, the measurement runner, `AGENTS.md`. Add a task that writes completion scripts.

Size: large but mechanical. Roughly 45 commands, their dry-run plans, and the tests that assert parser messages. The operation code, the bridge and the device behaviour are untouched, so nothing here needs re-verifying on a phone beyond a smoke run of each command family at the end.

## Risks

- **Routing regressions.** A command that parses but reaches the wrong operation, or loses an operand. Mitigation: the before-and-after dry-run comparison at every step, which has caught this kind of change all week.
- **Message churn in tests.** Tests that assert the wording of arity errors will need new expectations. Tests of domain validation should not change; if one does, that is a signal the migration moved a check it should not have.
- **Help quality.** Generated help is uniform but terse. Some of today's caveats will need a deliberate home.
- **A new dependency in the shipped binary.** It is Apple-maintained and widely used; the release archive grows slightly and gains one notice.
- **Doing it during other work.** The migration touches the files every new command touches. It should run when no other command work is in flight.

## Decisions

Decided by the owner on 2026-11-16:

1. **Grammar:** B, operation first, with the target given as `--device <UDID>` or `--simulator <UUID>`.
2. **Exit code for usage errors:** 64, so a script can tell "called wrong" from "failed". `docs/errors.md` is updated with the migration.
3. **Environment defaults for the target:** yes, `MANZANERO_DEVICE` and `MANZANERO_SIMULATOR`; an explicit option always wins.
4. **Grouping:** `files list|pull|push` and `reports list|get`.
5. **`devices`:** one command with a flag (`devices` for physical devices, `devices --simulators` for simulators).
6. **When:** later, after the pending phone checks, with nothing else in flight.
