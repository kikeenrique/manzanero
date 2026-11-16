# App logs research

> **Status (2026-11-16).** Milestones 1 to 6 are implemented as [`logs`, `console` and `last-crash`](app-logs.md): simulator `logs`, `console` and `last-crash` were verified on one iPhone Air simulator; physical `console` and `last-crash` were later verified on the iPhone 13 mini ([verification](verification.md#app-console-and-last-crash-on-the-phone)); milestone 7 (native `os_trace_relay`) was not built. Q3, Q7, Q8 and Q9 are settled below. Choices made where this document left them open: `log show` also runs through `StreamingToolRunner` so the entry and byte limits stop it early; `--last` takes seconds (1...3600); with `--output` the newest 50 entries are returned inline; `console` always relaunches the app; physical `console` ends the app at the duration whatever `--terminate` says; `last-crash --bundle` on a device downloads at most five newest candidates to read their headers; the probe's no-touch trigger is the accessibility element `probe.log.emit`, because a custom URL scheme asks for confirmation. The text below is the original research, with commands in the grammar of the time (`manzanero <platform> <device> logs …`); the current guide is [app logs](app-logs.md).

Research for a decision; nothing here is implemented. The question: how can an agent that drives a device get the logs of the app under test (unified-log `os_log`/`Logger` entries, the launched process's stdout/stderr, and crash information) on a physical device and on a simulator, using only Apple interfaces? How large is each piece?

## Evidence labels and environment

Each claim carries one label:

- **[E]** confirmed by experiment on this machine (simulator only; no physical device was contacted);
- **[H]** read in installed help, a man page or strings in an installed Apple binary;
- **[S]** read in reference source (git history or `tmp/` checkouts);
- **[I]** inferred.

Anything about a physical device is at best [S] or [H]. Nothing in this document has been tried against hardware.

Environment for [E] and [H]: macOS 27.2.1, Xcode 27.2 (27B52), `devicectl` 651.32, iOS 27.2 simulator runtime (24B8117), one iPhone Air simulator booted for the experiments and shut down afterwards. Stock Settings (`com.apple.Preferences`) was the test app. Captured output stays private under `tmp/app-logs-research/`; the shapes below are described or invented, not copied.

## 1. What an agent needs

In a test loop the agent acts, observes that the screen is wrong, and needs to know why. Four capabilities cover that loop:

| # | Capability | Typical call |
| --- | --- | --- |
| C1 | **Launch and capture console.** Launch (or relaunch) the app and return its stdout/stderr until it exits or N seconds pass. | "Relaunch `com.example.app`, give me 10 s of output." |
| C2 | **Capture unified-log entries going forward.** Return entries for one app (PID, bundle or process), optionally narrowed by subsystem, category and level, from now for N seconds, bounded by entry count and bytes. | "Watch the app's `network` category while I tap Login." |
| C3 | **Query recent unified-log entries.** Return entries for the app from a past window (`--last 60s` or between two timestamps). | "What did the app log in the last minute?" after a failure. |
| C4 | **Fetch the latest crash.** After the app disappears, find the newest crash report for that app since a timestamp and return a parsed summary (exception, signal, faulting thread's top frames, report path), optionally symbolicated. | "Did it crash? Where?" |

C2 and C3 are the same feature with different time directions. C1 overlaps C2 when the app's `os_log` output can be mirrored to stderr (see `OS_ACTIVITY_DT_MODE` below). Everything must be bounded: agents call tools unattended and a chatty app floods quickly. Settings alone produced about 1,670 entries and 2.6 MB of NDJSON in about six seconds at debug level [E].

## 2. Options per capability and platform

### 2.1 Simulator

#### S-A. `simctl spawn <device> log stream` (C2)

- **How it works.** Runs the simulator runtime's own `log` tool inside the booted simulator. The simulator has its own log store, separate from the host's. `--style ndjson` writes one JSON object per entry, then a trailing `{"count":N,"finished":1}` record [E][H]. `--timeout N` ends the stream by itself with exit 0 [E][H].
- **Evidence.** `simctl help spawn`; `simctl spawn <device> log help` lists `stream`, `show`, `collect`, `config`, `erase`, `repack` [H]. A bounded stream with `--predicate 'process == "Preferences"' --level debug --timeout 8` returned entries with the keys `timestamp`, `machTimestamp`, `messageType` (Default/Info/Debug/Error/Fault), `eventType`, `eventMessage`, `formatString`, `subsystem`, `category`, `processID`, `processImagePath`, `processImageUUID`, `senderImagePath`, `senderImageUUID`, `senderProgramCounter`, `threadID`, `activityIdentifier`, `traceID`, `userID`, persona fields, `bootUUID` and `backtrace` [E].
- **Quirks found [E].** stdout starts with a non-JSON banner line (`Filtering the log data using "<predicate>"`) before the first JSON object, so the parser must skip non-JSON lines. stderr always carries the noise line `getpwuid_r did not find a match for uid <host-uid>` (the host user's ID is unknown inside the simulator), so stderr content is not a failure signal. An invalid predicate exits 64 with `log: Bad predicate (...)` on stderr. An empty result is just the `{"count":0,"finished":1}` record.
- **Reference code.** None needed; this is an Apple executable. The removed Rust capture (`git show 1ef5066^:Backends/IDevice/src/logs.rs`, this project, history) supplies the bounding logic worth keeping: a deadline, an entry limit (2000), a byte limit (4 MiB) that excludes the entry that would cross it, `stopReason` of `duration`/`entryLimit`/`byteLimit`, `truncated`, and a mid-stream failure that is never reported as a complete capture [S].
- **Prerequisites.** A booted simulator. No root, no settings change.
- **Filtering.** Any NSPredicate on `processID`, `process`, `processImagePath`, `subsystem`, `category`, `messageType`, `sender`, `eventMessage` [H]. `--level default|info|debug` [H]. A bundle maps to a process in two ways. `simctl spawn <device> launchctl list` shows `UIKitApplication:<bundle-id>[…]` with its PID [E]. Alternatively `processImagePath BEGINSWITH "<installed .app path>"` would also catch the app's extensions and survive relaunches; entries carry host paths [E for system apps, I for user apps].
- **Bounds.** `--timeout` is the soft stop. The runner needs its own hard deadline a few seconds later, an entry limit and a byte limit. Default to `--level default`: at debug level Settings produced roughly 400 KB/s, about 75 % of it Debug [E].
- **Streaming or finite.** Streaming, made finite by `--timeout`.
- **Cleanup.** SIGTERM to the host `simctl spawn` process ended the in-simulator `log` process. No simulator `log stream` process was left afterwards [E].
- **Privacy.** Without a predicate the stream carries every process in the simulator. Build the predicate from structured, validated fields (PID, bundle-derived image path, subsystem, category). Do not pass agent-supplied raw predicates. No `<private>` redaction appeared in simulator output [E], so the app's private strings appear in clear text; treat captures as sensitive.
- **Stability risk.** Low. Public, documented tool; the NDJSON style is documented in `man log` [H]. The banner line and the `finished` record are format details to test against.
- **Dependency rule.** Fits: an Apple executable run through `xcrun`.

#### S-B. `simctl spawn <device> log show` (C3)

- **How it works.** Finite query of the simulator's persisted store: `--last 2m` or `--start/--end`, `--info`, `--debug`, `--style ndjson`, `--predicate` [H].
- **Evidence.** A two-minute query for one PID returned about 790 entries in 1.3 s, ending with the `finished` record. It had no banner line [E]. It contained Default, Info and Error entries but **no Debug** entries, while a live stream of the same app was mostly Debug [E]. That fits debug entries not being persisted by default [I], so C3 cannot recover debug-level output. Capture it live with C2.
- **Bounds.** A time window plus entry and byte limits. A process-level hard deadline is needed because large windows can be slow [I].
- **Everything else** as S-A.

#### S-C. `simctl launch --console` / `--console-pty` / `--stdout=` `--stderr=` (C1)

- **Help [H].** `--console` blocks and prints the app's stdout and stderr. `--console-pty` does the same through a PTY. `--stdout=<path>`/`--stderr=<path>` redirect to files and cannot be combined with the console options. `--terminate-running-process` relaunches. Signals received by simctl are passed to the app. Environment reaches the app through a `SIMCTL_CHILD_` prefix.
- **Findings [E]:**
  - With `--console`, stdout's first line is `<bundle-id>: <pid>`, followed by the app's stdout. The app's stderr goes to stderr. When simctl's stdout is a file or pipe it is **block-buffered**: after six seconds nothing had been written, and the PID line appeared only at exit. A streaming reader therefore cannot rely on getting the PID early.
  - With `--console-pty`, stdout and stderr are **merged** into stdout with CRLF line endings and arrive promptly. The PID line came after the app's first output lines.
  - `--stdout=`/`--stderr=` take **host** paths, return immediately with the `<bundle-id>: <pid>` line, and keep writing after `simctl` exits. Files persist after the app ends.
  - **SIGTERM to `simctl launch --console` terminates the app**: the PID was gone afterwards. Ending a console capture by signal ends the app under test.
  - When the app was aborted (SIGABRT) under `--console`, **simctl exited 0** and printed nothing about the termination. Ended by SIGTERM through `simctl terminate`, it also exited 0. So **console capture does not report how the app ended**; crash detection needs C4 or the log.
  - Simulator app PIDs are host PIDs: a host `kill` reached the app [E]. The host can therefore check liveness with `kill(pid, 0)` without a simctl call [I].
- **`OS_ACTIVITY_DT_MODE` [E].** Launching with `SIMCTL_CHILD_OS_ACTIVITY_DT_MODE=enable` made the app's own unified-log entries appear on its stderr, one line each in the form `<date> <Process>[<pid>:<tid>] [<category>] <message>`. Settings went from 6 stderr lines (runtime warnings only) to about 85 in a comparable window. The line carries no level or subsystem, only the category. Adding `OS_ACTIVITY_MODE=debug` raised it to about 116 lines. Whether debug-level entries are fully mirrored was not established.
- **Buffering of `print`.** Swift `print` and C stdio buffer stdout fully when it is not a terminal, so app stdout may not appear until a flush or exit under `--console` or `--stdout=` [I]. `--console-pty` gives line buffering [I]. The ProbeApp check below settles this.
- **Reference code.** None needed.
- **Bounds.** A deadline, plus byte limits applied to what is read back (keep the tail when truncating; the most recent output is the useful part).
- **Cleanup.** File mode is the safest: launch returns at once, nothing blocks, and the tool decides at the deadline whether to leave the app running or terminate it explicitly (`simctl terminate`). Console mode couples capture lifetime to app lifetime.
- **Privacy.** Only the app's own streams, so there is no cross-process leak. With DT mode, only the app's own `os_log` lines are mirrored.
- **Stability.** Low risk; documented options.
- **Dependency rule.** Fits.

#### S-D. Host crash reports (C4)

- **Where [E].** A simulator app crash (SIGABRT sent to Settings) produced `~/Library/Logs/DiagnosticReports/<Process>-<YYYY-MM-DD-HHMMSS>.ips` on the **host**, within a few seconds. The first line is a JSON header with `app_name`, `bundleID`, `bug_type` (`309` for a crash), `platform` (`7`, `PLATFORM_IOSSIMULATOR` in `mach-o/loader.h` [H]), `os_version`, `timestamp`, `incident_id` and `slice_uuid`. The rest of the file is one JSON document with `exception`, `termination`, `faultingThread`, `threads` (frames with `imageIndex`, `imageOffset` and sometimes `symbol`), `usedImages`, `procPath`, `pid` and `modelCode`. `modelCode` is the **Mac's** model, not the simulated device's.
- Older reports move to a `Retired/` subdirectory [E: it exists].
- **Matching to a simulator.** The header gives bundle ID and platform 7. For user-installed apps, `procPath` should contain the simulator's device directory, which ties a report to one simulator when several are booted [I]. For the stock app, `procPath` was a redacted runtime path [E].
- **Reference code.** ipb `Experiments/tools/symcrash.py` (MIT; `tmp/ipb/`) parses exactly this two-part `.ips` layout and resolves frames from `usedImages` and `imageOffset` with `nm`. Use it as a format reference only [S].
- **Symbolication.** System frames already carried symbols [E]. App frames need the build's dSYM: `atos -o <dSYM> -l <load address> <addresses>` is installed through `xcrun` [H]. `symbolicatecrash` is not on the `xcrun` path; it exists only as a resource inside DVTFoundation [H].
- **Bounds.** Report files are typically tens to hundreds of KB. Return a summary and the path, not the whole file.
- **Privacy.** The host directory holds crash reports for every Mac process. Filter strictly by `platform == 7`, bundle ID and time, and never list the directory to the agent.
- **Dependency rule.** Fits: reading files with Foundation.

#### S-E. Other simulator options considered

- `simctl diagnose` collects everything (all simulators' logs, optionally data containers) into an archive [H]. It is too broad and slow for a test loop and is privacy-heavy. Not recommended.
- Host `log show`/`log stream` read the host store, not the simulator's [I]. The public `OSLogStore(url:)` in the OSLog framework could read a `.logarchive` in process [I]. That is an option for later archive parsing, not needed now.

### 2.2 Physical device

#### P-A. `devicectl device process launch --console` (C1, and part of C2)

- **Help [H].** `--console` "attaches the application to the console and waits for it to exit". If the app is not already running, its standard streams are connected to devicectl's. Catchable signals sent to devicectl are forwarded to the app. `--console` bridges the app's stdout to devicectl's stdout, so `--json-output -` is refused; JSON must go to a file. `--terminate-existing` relaunches. Environment reaches the app through `DEVICECTL_CHILD_` or `--environment-variables`. `--timeout` is the overall command limit.
- **How it works [S].** In the idevice reference (`tmp/idevice/idevice/src/services/core_device/openstdiosocket.rs` and `app_service.rs`, MIT), the host opens the RSD service `com.apple.coredevice.openstdiosocket`, reads a 16-byte UUID and passes it as the stdio identifier in CoreDevice's app-service launch request. The process's stdio then flows over that socket. The installed CoreDevice binary contains the `com.apple.coredevice.openstdiosocket` string [H], and a saved `remotectl show` service listing for the project's test phone (private, under `tmp/`) advertises it [H]. The reference notes that the stdio UUID is ignored if the process already has one, which matches "if the app is not already running" in the help.
- **`os_log` on the console.** `OS_ACTIVITY_DT_MODE` appears among the environment-handling strings in `CoreDeviceCLISupport` (next to `TERM` and `DEVICECTL_CHILD_`) [H]. Passing `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable` should mirror the app's own `os_log` entries to its stderr, as on the simulator [I]. Whether devicectl already sets it, and whether stderr is bridged as well as stdout, are open questions (Q1).
- **Prerequisites.** Developer Mode, a paired and connected device, an app the device lets devicectl launch (developer-signed apps; the existing `launch` route works for Settings).
- **Filtering.** None needed: only the app's own streams.
- **Bounds.** The tool's deadline and byte limits. `--console` blocks until the app exits, so the tool must end it at the deadline, and that signal is forwarded to the app (help). Design C1 as "capture for N seconds, then the app is terminated" or "until it exits", never "detach and leave running".
- **Exit status.** Unknown whether devicectl's JSON reports the app's exit status or signal after `--console` (Q2). The simulator equivalent reports nothing [E].
- **Stability.** Medium. Documented options, but `--console` output is "meant for human consumption", and the help warns that stdout carries bridged remote stdout.
- **Dependency rule.** Fits: an Apple executable.

#### P-B. Native `os_trace_relay` over the existing RSD transport (C2)

- **What the removed bridge did [S].** `physical <UDID> logs <1…30 s> [pid]` connected idevice's `OsTraceRelayClient` through RSD (`connect_rsd`) over idevice's own TLS-PSK software tunnel. It sent `StartActivity` and collected decoded entries with the bounds listed under S-A. Its tests covered parsing, deadline, entry limit, byte limit and mid-stream failure. Verification recorded "live trace and remote cleanup unverified" (`docs/verification.md` before `d41d99a`).
- **Protocol [S]** (`tmp/idevice/idevice/src/services/os_trace_relay.rs`, MIT, crediting pymobiledevice3):
  - RSD service name `com.apple.os_trace_relay.shim.remote` (lockdown name `com.apple.os_trace_relay`). It is a lockdown "shim": raw TCP to the advertised port, then `RSDCheckin`. The client sends `{Label, ProtocolVersion: "2", Request: "RSDCheckin"}` and expects replies with `Request: "RSDCheckin"` and then `Request: "StartService"`. Plists are framed with a 4-byte big-endian length. No TLS on the service socket (`idevice/src/lib.rs`, `rsd_checkin`).
  - `StartActivity` as a binary plist: `{Request: "StartActivity", Pid: <pid or -1>, MessageFilter: 65535, StreamFlags: 60}`. The reply is one byte, then a plist with `Status: "RequestSuccessful"`.
  - Each entry is a `0x02` byte, a 4-byte little-endian length, then a packed record. After 9 bytes of padding: PID; a 42-byte block holding `procid` and the process image UUID; seconds and microseconds; a level byte (0 Notice, 1 Info, 2 Debug, 0x10 Error, 0x11 Fault); a 38-byte block holding the mach timestamp, thread ID and sender image UUID; sizes for image name, message, subsystem and category; the sender image offset; a NUL-terminated process path; then the strings. The fixed header is 129 bytes. Several fields are "unidentified".
  - `PidList` returns `{Payload: {"<pid>": {ProcessName}}}`. `CreateArchive` with optional `SizeLimit`/`AgeLimit`/`StartTime` streams a log archive in `0x03`-prefixed chunks; that is a finite C3 path on the device.
  - The sibling `syslog_relay.shim.remote` gives plain text lines delimited by `\n\0` with no structure (`syslog_relay.rs`).
- **Fit with this project's transport [S][I].** The live accessibility route already does tunnel assertion, then `nettop` RSD port discovery, then the RSD directory over Network/RemoteXPC, then a raw Darwin TCP socket to an advertised port (`NativeTunnelAssertion.swift`, `RSDPortDiscovery.swift`, `RSDDirectoryConnection.swift`). The only AX-specific piece is `ADCValidateRSDHandshake`, which hard-codes `com.apple.accessibility.axAuditDaemon.remoteAXService` and requires `UsesRemoteXPC: true` and `EncryptSocketData: false`. A shim service probably advertises different properties [I], so the check must be generalised per service, with its own property rules. The saved `remotectl show` listing for the test phone advertises `com.apple.os_trace_relay.shim.remote`, `com.apple.syslog_relay.shim.remote`, `com.apple.crashreportcopymobile.shim.remote` and `com.apple.coredevice.openstdiosocket` [H]. It shows names only, not ports or properties.
- **Filtering.** On the device: one PID or all (`-1`). Subsystem, category and level are filtered on the host after receipt, so with `-1` every process's entries cross the wire. With a PID, a relaunch changes the PID and ends coverage. Resolve bundle to PID with the existing `processes` operation (`devicectl device info processes`).
- **Bounds.** Port the removed bounds. Add a raw-byte limit that counts bytes received, not only entries kept, so host-side filtering cannot hide a flood. Cap the record length before allocating (the length field is attacker-shaped data from the wire).
- **Cleanup.** Closing the socket ends the subscription (comment in the removed `logs.rs`) [S]. That was never verified live.
- **Privacy.** Device-side redaction (`<private>`) applies to dynamic strings that are not marked public [I]. With `Pid: -1`, other apps' entries reach host memory and must be dropped before output.
- **Stability risk.** High. Private, undocumented binary format with unidentified fields, which pymobiledevice3 and idevice have revised over time. The shim may need properties or entitlements not yet seen. There was never a live success through Apple's native tunnel.
- **Dependency rule.** Fits the precedent: project-owned protocol code over Apple's tunnel and Network APIs, like raw AX/DTX. idevice and pymobiledevice3 are references only; attribution is already in `ThirdParty/` for idevice.

#### P-C. Host `log collect --device` (C3)

- **Help and strings [H].** `log collect --device | --device-name | --device-udid` with `--last`, `--start`, `--size`, `--output`. The binary contains `Must be root to collect logs from attached device` and `Warning: --predicate is ignored when collecting from attached device`. Collecting the **host** store without root worked here [E], which says nothing about the device path.
- **Assessment.** It needs root, which an unattended agent should not have. It collects the whole device's logs with no predicate, so privacy is poor. It is finite but slow and large [I]. Whether it works over the iOS 17+ CoreDevice tunnel is unknown (Q5). Possibly a manual fallback for a person, but not an agent capability.

#### P-D. `devicectl device sysdiagnose` (post-mortem only)

- **Help [H].** `--destination`, `--gather-full-logs` (off by default because it is much larger), `--dry-run-only`. The reference shows it uses CoreDevice's `com.apple.coredevice.feature.capturesysdiagnose` with `collectFullLogs` [S].
- **Assessment.** Minutes and hundreds of MB, with every subsystem's data. Not for a test loop. Useful only as an escalation a person approves.

#### P-E. Crash reports (C4)

- **Today.** `physical <UDID> reports [dir]` lists and `report <remote> <local>` downloads from `devicectl … --domain-type systemCrashLogs` (`Sources/Manzanero/ReportCommand.swift`). Listing is live-verified; download is not. Parsing, filtering and symbolication are missing (`docs/feature-status.md`).
- **Needed.** List, filter names by process prefix and modification time ≥ `since`, download the newest match into a tool-owned directory, then parse it with the same `.ips` parser as S-D (platform 2) [I]. Symbolicate app frames with `atos` and the dSYM from the Build & Run products when available.
- **Native alternative.** `com.apple.crashreportcopymobile.shim.remote` (AFC over the shim) [S] is unnecessary while devicectl's domain works.

#### P-F. App cooperation (any platform)

The app can export its own entries with the public `OSLogStore(scope: .currentProcessIdentifier)` and write them to its container, which the existing `files`/`pull` operations can read [I]. It needs nothing from the device, but it requires changing the app under test, so it fits fixtures (ProbeApp), not arbitrary apps. It is a useful control for verifying the other routes.

## 3. Recommendation

### Simulator: build it first, entirely with `simctl`

1. **C2/C3: `logs` over `simctl spawn … log stream|show --style ndjson`.** Structured predicate built from PID, bundle (via the installed app path or `launchctl list`), subsystem, category and level, with the removed bridge's bounds. Medium. It answers the core question for the most common case, every piece was exercised here, and it needs no new runtime machinery beyond a runner mode where reaching the deadline counts as success.
2. **C1: `console` via `simctl launch --stdout=<file> --stderr=<file>` plus `SIMCTL_CHILD_OS_ACTIVITY_DT_MODE=enable`.** Wait until the app exits (host `kill(pid, 0)`) or the deadline passes, then return byte-bounded tails. Terminate only on request. Small to medium. File mode avoids three problems seen in `--console` mode: simctl's buffered stdout, termination of the app when capture ends, and blocking.
3. **C4: `last-crash` reading the host `DiagnosticReports`** filtered by platform 7, bundle and time. Medium, shared with the physical parser.

Main risk: the app's own stdout may be block-buffered and invisible until exit (`print` without flush). Fallback: `--console-pty` for a line-buffered merged stream, at the cost of the console-mode problems above. Logger output is unaffected because C2 reads the log store directly.

### Physical device: Apple executables first, native relay only if needed

1. **C4 first: crash summary on top of the existing `reports`/`report`.** Small once the S-D parser exists. It is the highest-value physical piece, and the listing route is already live-verified.
2. **C1: `console` through `devicectl device process launch --console --terminate-existing`, JSON to a file, `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable`.** Small to medium. If stderr is bridged and DT mode is honoured, this also delivers the app's own `os_log` lines at default level and above, which covers most of C2 for apps the tool launches.
3. **C2 for apps not launched by the tool, or with subsystem, level or debug detail: native `os_trace_relay`** over the existing tunnel and RSD path. Large. Build it only if the Q1 experiment shows P-A is insufficient.

Apple executables are **not** sufficient for C2/C3 on a physical device in general. `devicectl` has no log, console-stream or trace command for an already-running process (every `devicectl device` subcommand was checked [H]). `log collect --device` needs root and ignores predicates [H]. sysdiagnose is far too heavy. Main physical risk: whether `--console` bridges stderr and whether DT mode mirrors `os_log` on a device. Fallback: P-B, then P-F for fixtures.

## 4. Implementation plan in this codebase

### Command shapes

`launch` cannot take capture options: physical `launch` passes everything after the bundle to the app as argv (`DeviceCommands.swift`). Capture therefore gets its own operations, with options after the operands as in `wait-id`:

```text
manzanero <platform> <device> console <bundle-id> [--seconds N] [--max-bytes N] [--os-log] [--terminate] [-- app-args…]
manzanero <platform> <device> logs (--seconds N | --last N | --start <ISO-8601> [--end <ISO-8601>])
          (--pid N | --bundle <id> | --process <name>) [--subsystem S [--category C]] [--level default|info|debug]
          [--max-entries N] [--max-bytes N] [--output <host.ndjson>]
manzanero <platform> <device> last-crash (--bundle <id> | --process <name>) [--since <ISO-8601>] [--download <dir>] [--symbolicate <dSYM>]
```

- `--seconds` is required for `console` and stream-mode `logs`, 1–60 by default (the removed bridge used 1–30). The hard process deadline is `seconds + 5`.
- `logs` defaults to level `default`, 2,000 entries and 1 MiB inline. `--output` writes every kept entry as normalised NDJSON and returns a summary plus the last entries inline, mirroring how screenshots save a full file and return a bounded inline result. Hard ceilings: 10,000 entries and 8 MiB.
- No raw predicate option. Filters are validated (bundle-ID and subsystem character sets) and quoted into the predicate by the tool.
- MCP: `capture_console`, `capture_logs`, `latest_crash` (three tools, bringing the catalogue from 32 to 35). `capture_logs` and `latest_crash` are `readOnly`. `capture_console` launches an app, so it is a mutation and goes through the handoff pause and lease rules that `launch` uses.

### Result shape (both platforms)

```json
{"entries":[{"timestamp":"2026-01-01T12:00:00.000000Z","level":"error","pid":1234,"process":"Example",
  "subsystem":"com.example.app","category":"network","sender":"Example","message":"request failed: 401"}],
 "entryCount":1,"entryBytes":212,"receivedBytes":4096,"filteredOut":17,
 "stopReason":"duration","truncated":false,"source":"simctl-log-stream","level":"default"}
```

(invented example). `console` returns `pid`, `stdoutTail`, `stderrTail`, byte counts, `truncated`, `stopReason` (`exited`/`duration`/`byteLimit`), `terminatedByTool`, and `exitStatus: null` unless a platform actually reports it. `last-crash` returns `found`, `path`, `timestamp`, `exceptionType`, `signal`, `terminationReason`, `faultingThread` frames (image, offset, symbol if any) and `symbolicated`.

### Runners

- `StreamingToolRunner` streams stdout under a deadline and output limit, but it treats the deadline as a `timeout` failure, keeps stderr only as a 64 KiB string, and has no environment parameter. Add (a) a capture mode where the deadline is a normal stop that reports `stopReason: duration` and still reaps the child, and (b) an environment overlay, needed for `SIMCTL_CHILD_`/`DEVICECTL_CHILD_` variables. Both are small. Use it for `log stream` and for `devicectl … --console`.
- `ToolRunner` (synchronous, file-backed) is enough for `log show`, `simctl launch --stdout/--stderr` (which returns immediately), `launchctl list`, the report listing and download, and `atos`. It also needs the environment overlay.
- The NDJSON reader is line-based: skip non-JSON lines (the banner), stop on the `finished` record, count received bytes before filtering, and keep the removed bridge's rule that a mid-stream failure is an error, never a short success.
- The native relay (later) is a Swift actor owning the socket, reusing `RSDDirectoryConnection` with a generalised service validator in `AppleDeviceBridge`.

### Errors (`docs/errors.md` categories)

| Situation | `code` | `inputSent` |
| --- | --- | --- |
| Bad duration, filter characters, mutually exclusive options | `usage` | `none` |
| Physical `logs` before the native relay exists | `unsupported-operation` | `none` |
| Simulator not booted; device not ready | `device-not-ready` | `none` |
| Bundle not installed, no running process for `--bundle` | `ambiguous-or-missing-target` | `none` |
| `log`/`simctl`/`devicectl` non-zero exit (for example 64, bad predicate) | `tool-failed` | `none` for `logs`; `unknown` for `console` |
| Hard deadline passed after the soft stop (child did not exit) | `timeout` | as above |
| Relay checkin, `StartActivity` or record parse failure | `transport-failed` | `none` |
| MCP cancellation | `cancelled` | as above |

`logs` and `last-crash` join the read-only list, so every failure reports `none`. `console` launches and may terminate an app, so failures after the launch step are `possible`/`after-inspection`.

### Dry runs

`--dry-run` prints the planned argv, the bounds and the derived predicate, for example `["xcrun","simctl","spawn","<device>","log","stream","--style","ndjson","--level","default","--timeout","10","--predicate","processImagePath BEGINSWITH \"<app path>\""]` with `{"maxEntries":2000,"maxBytes":1048576,"hardDeadlineSeconds":15}`. When resolving the bundle to a path or PID would itself need a device query, the plan shows the placeholder and the query it would run. The native relay's plan lists steps (tunnel assertion, RSD service and validated properties, `StartActivity` PID) without contacting the device.

### Milestones

Each milestone is independently verifiable.

1. **Runner support.** Deadline-as-success mode and environment overlay, with unit tests on the existing manual clock and a fixture process. *Small*: contained changes to two runners and their tests.
2. **Simulator `logs`.** Stream and show, predicate builder, NDJSON reader, bounds, `--output`, CLI, MCP and dry run; tests with synthetic NDJSON (banner, `finished` record, oversized entry, mid-stream failure, exit 64). *Medium*: new parsing and normalisation plus two front ends; no new device machinery.
3. **Simulator `console`.** File-mode launch, DT-mode environment, liveness polling, tail-bounded reads, optional terminate. *Small to medium*: mostly orchestration of existing simctl calls.
4. **`.ips` parser and simulator `last-crash`.** Header and body decoding, frame summary, host-directory filter by platform, bundle and time, optional `atos`. *Medium*: format parsing with fixtures built from invented reports, plus symbolication plumbing.
5. **Physical `last-crash`.** Reuse the parser on `reports`/`report` output, filtered by name and time. *Small*: planner and filter on an existing route; the download needs its first live check.
6. **Physical `console`.** `devicectl --console`, JSON to a tool-owned file, environment overlay, signal-forwarding semantics documented. *Small to medium*: the code is small, but behaviour must be established on hardware (Q1, Q2).
7. **Physical native `logs`** (only if 6 is insufficient). Generalised RSD service validator, RSDCheckin and plist framing, `StartActivity`, record parser ported from the MIT reference with attribution, bounds, cleanup, doctor capability entry. *Large*: private binary format, a new bridge path, privacy filtering, and live verification on at least one iOS version.

## 5. Verification

### ProbeApp additions

Add a log probe with its own `probe.log.*` identifiers, following the touch probe's namespacing (`docs/probe-app.md`). ProbeApp currently has no logging.

- A launch argument `-probeLogToken <token>` that, at launch, writes:
  - `Logger(subsystem: "<probe bundle id>", category: "probe")` lines at debug, info, default (notice), error and fault, each containing the token and its level, with `privacy: .public`;
  - one private-interpolated value, to observe redaction;
  - `print("stdout <token> flushed")` followed by `fflush(stdout)`, and `print("stdout <token> unflushed")` without a flush;
  - a direct write of `stderr <token>` to `FileHandle.standardError`.
- A button `probe.log.emit` that emits the same set with a counter, for "between two moments" checks (C2 started before the tap, C3 queried after it).
- A launch argument `-probeCrash abort|trap` that crashes deliberately after logging `about to crash <token>`, for C4 and for "last lines before the crash".
- Optionally, an export of its own entries through `OSLogStore(scope: .currentProcessIdentifier)` to `Documents/log-export.jsonl`, as the P-F control.

### Checks

- **Simulator.** Build and run ProbeApp, then call `logs --bundle … --seconds 10 --level debug` and tap `probe.log.emit` in parallel. Assert that every level's token appears with the right `level`, `subsystem` and `category`, and that no entry from another process appears. Repeat `logs --last 60` and assert debug is absent (the persistence finding). Run `console --os-log --seconds 5` and assert that the stderr token, the flushed stdout token and the DT-mode `os_log` lines appear; record whether the unflushed token appears. Run `-probeCrash abort`, then `last-crash --bundle … --since <launch time>`, and assert `found`, the abort signal and a frame in ProbeApp. Verify bounds with `--max-entries 3` (expect `entryLimit`, `truncated`). Verify cleanup: no `log` or `simctl` child left (process list), and the app is still running unless `--terminate` was given.
- **Phone.** The same `console` and `last-crash` checks after a signed ProbeApp install (physical signing of ProbeApp is untried, `docs/probe-app.md`). Record iOS, Xcode and `devicectl` versions, whether stderr arrived, whether DT-mode lines arrived, and whether the JSON reports an exit status. Native `logs`, if built: tokens at each level for the PID, `Pid: -1` with host filtering, and socket close followed by a fresh capture to show the earlier subscription ended.

Record results in `docs/verification.md` with the usual scope; a passing simulator run says nothing about devices.

## 6. Open questions and settling experiments

**First phone result for Q1 and Q2 (2026-11-15, iPhone 13 mini, iOS 27.2.1, Xcode 27.2), inconclusive.** Settings was launched twice with `devicectl device process launch --console --terminate-existing`, once with `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable` and once without, each stopped with SIGINT after ten seconds. Both runs printed only devicectl's own three lines on stdout (launched, waiting, `App terminated due to signal 2`) and no app output on either stream; the JSON file reported `outcome: success`. So the termination signal is reported in text, the interrupt does end the app, and no `os_log` line was mirrored for this system app. Whether that is because Settings writes nothing to stdout or stderr, because DT mode is not honoured for a system app, or because devicectl does not bridge stderr cannot be told from this run. Q1 stays open until an app that prints known tokens (the probe app, once it can be signed) is launched the same way.

| # | Question | Experiment |
| --- | --- | --- |
| Q1 | Does `devicectl … launch --console` bridge **stderr** as well as stdout, and does `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable` mirror `os_log` lines to it on a device? Does devicectl already set DT mode itself? | **Phone, cheap, owner-run.** `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable xcrun devicectl device process launch --device <UDID> --console --terminate-existing --json-output tmp/app-logs-research/launch.json com.apple.Preferences > tmp/app-logs-research/phone.out 2> tmp/app-logs-research/phone.err` and stop it with Ctrl-C after about 10 s. Repeat without the variable. Compare whether `phone.err` has `Preferences[pid:tid] [category]` lines in each run. Note that Ctrl-C is forwarded and ends Settings. |
| Q2 | Does devicectl's JSON report the app's exit status or signal after `--console`? Does `awaitTermination` report it? | Same run: inspect `launch.json`. Then `devicectl device process awaitTermination --pid <pid> --json-output <file>` against a launched Settings, ended with `process terminate`. |
| Q3 | Is unflushed `print` output lost or delayed under `--stdout=`/`--console`, and does `--console-pty` fix it? | ProbeApp flushed and unflushed tokens on the simulator (M3 check). **Settled 2026-11-16:** lost under `--stdout=` (while running and after terminate) and `--console`; `--console-pty` delivered it at once ([verification](verification.md#app-logs-console-and-crashes)). |
| Q4 | What properties does the RSD directory advertise for `com.apple.os_trace_relay.shim.remote` (port, `UsesRemoteXPC`, `EncryptSocketData`, others)? | **Phone, cheap.** A diagnostic task on the existing directory route that prints only the `Properties` of the four log-related services, without connecting to them. Alternatively, look at a `remotectl` dump if it shows properties. |
| Q5 | Does `sudo log collect --device-udid <UDID> --last 1m` work over the iOS 17+ CoreDevice tunnel, and how large is a one-minute archive? | Phone, owner-run with sudo; output to `tmp/`. Informational only: root rules it out for agents. |
| Q6 | Does `StartActivity` with a PID succeed over the native tunnel with RSDCheckin, and does closing the socket end the device-side subscription? | Only if P-B is pursued: a test task that opens the service, sends `StartActivity` for Settings' PID, reads at most 50 records or 5 s, closes, and reopens. |
| Q7 | Does `processImagePath BEGINSWITH "<app path>"` capture a user app and its extensions in the simulator, including after a relaunch? | ProbeApp in the simulator: stream across a `--terminate-running-process` relaunch. **Settled for the app 2026-11-16:** yes, across two relaunches; extensions untested (the probe has none). |
| Q8 | Are debug-level entries fully mirrored in DT mode, and under which `OS_ACTIVITY_MODE` values? | ProbeApp debug token with and without `SIMCTL_CHILD_OS_ACTIVITY_MODE=debug`. **Settled 2026-11-16:** DT mode alone mirrors info and above, not debug; adding `OS_ACTIVITY_MODE=debug` mirrors debug too. |
| Q9 | Does `procPath` in a simulator `.ips` identify the simulator device for user-installed apps? | Crash ProbeApp in the simulator and inspect the report (M4 check). **Settled 2026-11-16:** yes, it is the host path under `CoreSimulator/Devices/<UUID>/`. |

## Sources

- Removed implementation: `git show 1ef5066^:Backends/IDevice/src/logs.rs`, `main.rs`, `transport.rs`; introduced in `4812304`, removed in `d41d99a`.
- idevice (MIT, `tmp/idevice/`, notice in `ThirdParty/idevice-LICENSE.txt`): `services/os_trace_relay.rs`, `services/syslog_relay.rs`, `services/core_device/openstdiosocket.rs`, `services/core_device/app_service.rs`, `services/core_device/diagnosticsservice.rs`, `services/crashreportcopymobile.rs`, `lib.rs` (`rsd_checkin`, plist framing).
- ipb (MIT, `tmp/ipb/`): `Experiments/tools/symcrash.py` (`.ips` layout); its README lists logs as not implemented ("planned: syslog via RemoteXPC").
- AXe (`tmp/AXe/`) and cmagic (`tmp/cmagic/`): no device or simulator log capture; cmagic is a CI client.
- Installed help: `xcrun devicectl help` and every `device`, `device process` and `device info` subcommand, `device process launch`, `device sysdiagnose`, `diagnose`, `device copy from`; `xcrun simctl help`, `launch`, `spawn`, `diagnose`; `man log`; strings in `/usr/bin/log` and `CoreDeviceCLISupport`.
