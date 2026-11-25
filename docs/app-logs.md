# App logs, console and crashes

An agent that sees a wrong screen needs to know why. Three commands read what the app under test wrote and how it ended, using only Apple's tools: `logs` (unified-log entries), `console` (stdout and stderr) and `last-crash` (the newest crash report, parsed). The design and the experiments behind it are in [the research](app-logs-research.md); live results are in [verification](verification.md#app-logs-console-and-crashes).

| Command | Simulator | Physical device |
| --- | --- | --- |
| `logs` | `simctl spawn <UUID> log stream\|show --style ndjson`. Verified on one simulator | The device's log relay, a stream from now ([below](#physical-devices)). Checked on one iPhone 13 mini on 2026-11-20, on both routes |
| `console` | `simctl launch --stdout=<file> --stderr=<file>`. Verified on one simulator | `devicectl device process launch --console`. Checked on one iPhone 13 mini |
| `last-crash` | Host `~/Library/Logs/DiagnosticReports`. Verified on one simulator | Existing `reports`/`report` route plus the same parser. Checked on one iPhone 13 mini |

## Commands

```sh
manzanero logs (--seconds N | --last N | --start <ISO-8601> [--end <ISO-8601>])
    (--pid N | --bundle <id>… --process <name>… | --all) [--subsystem S… [--category C…]] [--match <text>]
    [--level default|info|debug] [--max-entries N] [--max-bytes N] [--output <new.ndjson>]
    (--simulator <UUID> | --device <UDID>, with --seconds only)
manzanero console <bundle-id> --seconds N [--max-bytes N] [--os-log] [--terminate]
    (--device <UDID> | --simulator <UUID>) [-- app-args…]
manzanero last-crash (--bundle <id> | --process <name>) [--since <ISO-8601>] [--download <existing-dir>]
    (--device <UDID> | --simulator <UUID>)
```

Options may come in any order; the target and every option go before `--`, after which everything is passed to the app. Every command has a `--dry-run` plan that prints the planned argv, the derived predicate and the bounds without querying anything. A simulator is addressed by its UUID only.

MCP exposes them as `capture_logs` (`readOnly`; `platform` is `simulator` unless given as `physical`), `capture_console` (a mutation: it launches an app) and `latest_crash` (`readOnly`); see [MCP](mcp.md).

## `logs`

**Time.** Exactly one of:

- `--seconds 1…60` (`1…600` on a physical device): `log stream` from now. `log --timeout` ends it; the tool's hard deadline is five seconds later.
- `--last 1…3600`: `log show --last <n>s` over the simulator's persisted store.
- `--start <ISO-8601> [--end <ISO-8601>]`: `log show` over a window. The tool passes the instants in UTC.

**Processes.** Exactly one of, as Apple's `log stream`, `idevicesyslog` and `pymobiledevice3 syslog` offer:

- `--pid N`: one process, `processID == N`. A relaunch changes the PID.
- `--bundle <id>` and `--process <name>`, each repeatable (at most 16), together a group: alternatives joined with `OR`. A bundle is resolved with `simctl get_app_container <UUID> <id> app` to the installed `.app` directory, then matched with `processImagePath BEGINSWITH "<app>/"`, which covers the app and anything inside its bundle and survives relaunches (Q7); a bundle that is not installed is `target-unresolved`. A name is `process == "<name>"`.
- `--all`: every process. With no filter either, no predicate is passed at all.

**Narrowing.** `--subsystem` and `--category` (each repeatable; a category needs a subsystem), each set joined with `OR`; `--match <text>`, `eventMessage CONTAINS "<text>"`. Every group of conditions is joined with `AND`. `--level default|info|debug` (default `default`) is passed to `log stream --level` or as `--info`/`--debug` to `log show`.

**No raw predicate.** The tool builds the predicate itself. Bundle identifiers, subsystems and process names are limited to ASCII letters, digits and a few punctuation characters; categories to printable ASCII, and `--match` to printable characters, both without quotes or backslashes. Values are also escaped when quoted. Entries that do not match the processes, subsystems, categories and text are dropped on the host as well and counted in `filteredOut`, as are entries that are not log events (activities). `--all` with no filter returns every process's messages, which can carry private data of other apps.

**Bounds.**

| Bound | Default | Ceiling |
| --- | --- | --- |
| Entries kept (`--max-entries`) | 2,000 | 10,000 |
| Bytes of normalised entries kept (`--max-bytes`) | 1 MiB | 8 MiB |
| Raw bytes read from `log`, before filtering | 64 MiB | fixed |
| Process deadline | stream: `seconds + 5`; show: 60 s | fixed |

An entry that would cross the entry or byte limit is not kept, and the capture stops there: the child is sent SIGTERM (then SIGKILL after one second) and reaped. `truncated` is true only when a limit dropped something; exactly reaching the limit is not truncation.

**Result.**

```json
{"entries":[{"timestamp":"2026-01-01T11:00:00.123456Z","level":"error","pid":1234,"process":"Example",
  "subsystem":"com.example.app","category":"network","sender":"Example","message":"request failed: 401"}],
 "entryCount":1,"entryBytes":212,"receivedBytes":4096,"filteredOut":0,"toolReportedCount":1,
 "stopReason":"duration","truncated":false,"source":"simctl-log-stream","level":"default",
 "predicate":"processImagePath BEGINSWITH \"<app path>/\"","platform":"simulator","device":"<UUID>","operation":"logs"}
```

(invented example). `stopReason` is `duration` (a stream ran its time), `complete` (a `show` query finished), `entryLimit` or `byteLimit`. Timestamps are converted to ISO 8601 UTC with the source's fraction digits. `toolReportedCount` is the count in `log`'s final `{"count":N,"finished":1}` record, which includes events the host then filtered. With `--output <path>`, every kept entry is written to that new file as NDJSON (mode 0600; an existing file is refused) and only the newest 50 are returned inline (`inlineEntryCount`).

**Failures.** `log` exiting non-zero (64 for a bad predicate) is `tool-failed` with its stderr, minus the `getpwuid_r did not find a match` line the simulator's `log` always prints. A `log` that exits 0 without its final record is also `tool-failed`, never a short success. The hard deadline is `timeout`. Every `logs` failure reports `inputSent: none`.

**Debug entries are not persisted.** `log show` (`--last`, `--start`) returned info and above but no debug entries, even with `--level debug`. Capture debug output live with `--seconds`.

### Physical devices

On a device `logs` reads the device's log relay (`com.apple.os_trace_relay.shim.remote`, `OSTraceRelay` and `PhysicalLogCapture`), the route the experiment of 2026-11-18 proved ([record](verification.md#the-log-relay-on-the-phone)). Built on 2026-11-20 and unit-tested against a fake relay on a socket pair. The same evening, on the iPhone 13 mini, it kept the probe's lines at every level by `--bundle` and by `--process`, on the tool's own tunnel and on Apple's, and stopped with exit 130 on SIGINT ([record](verification.md#phone-session-of-2026-11-20-a-table-row-a-moving-stream-open-url-and-logs)). The result has `firstParseFailure` when a record does not parse; one in 180 did not in the first run. On the Apple TV 4K it ran on the paired tunnel on 2026-11-21. On the phone on 2026-11-22: MCP `capture_logs` with `platform: physical` (`processWatch: devicectl`), a filtered one-process stream that ran its full 590 s, an unfiltered one at debug that stopped at its 2000-entry bound in about five minutes, and a group stream at debug that stopped at the 256 MiB received bound in under seven minutes, a busy phone sending far more than an idle one ([morning](verification.md#phone-session-of-2026-11-22-morning-the-owed-runs-that-need-no-person), [afternoon](verification.md#phone-session-of-2026-11-22-afternoon-with-the-human-owner-at-the-phone)). On an Apple Watch (watchOS 27.2.1, 2026-11-25) a one-process stream of the watchOS probe over Apple's tunnel ended at its duration with nothing received (`receivedBytes: 0`) at `default`, `info` and `debug`, although the probe logged presses meanwhile; why is open ([record](verification.md#the-physical-apple-watchs-remaining-commands)).

- **Time.** `--seconds` only, 1…600, a stream from now. `--last` and `--start` are usage errors: the device's stored log is not read.
- **One process, until it ends.** `--pid`, or a single `--bundle` or `--process` that matches one running process: `--bundle` is resolved with `devicectl device info apps` and `processes` to the running process whose executable is directly inside the app's `.app` (an extension's is deeper and does not count), `--process` to the running process with that executable name. The device is asked for that PID only, and the capture ends when the process does (`stopReason: processEnded`), which the relay does not do by itself: the tool looks for the PID every 2 s, in the relay's own process list on the tool's tunnel (`processWatch: relay`, one fresh socket per look, because the relay answers one `PidList` per socket and closes it on a second) or in `devicectl`'s on Apple's tunnel (`processWatch: devicectl`, since a directory there is only good for seconds). A look that fails is reported in `processWatch` and the capture runs to its other limits. Not installed or not running is `target-unresolved`, with nothing captured; to see an app start, capture a group or `--all` with a filter. A relaunch is not followed.
- **A group or every process.** Several `--bundle`/`--process` values, `--all`, or a name that several running processes share: the device is asked for every process (`Pid: -1`, `deviceStream: every process`), and the Mac keeps a record when its PID, its executable's name, or its path inside a selected app's `.app` matches (`/private/var` and `/var` are taken as the same). Nothing needs to be running: an app launched during the capture is kept from its first lines. An idle iPhone 13 mini sent about 560 records and 200 kB a second this way.
- **Levels and filters.** The device sends every level, debug included, which `console --os-log` never shows. Level, subsystems, categories and `--match` are filtered on the Mac. `--level default` keeps default, error and fault; `info` adds info; `debug` adds debug. Entries have the simulator's fields (`timestamp` with microseconds, `level`, `pid`, `process`, `subsystem`, `category`, `sender`, `message`). A record whose subsystem fields hold sizes but whose bytes end after the message (seen from `locationd`) has no subsystem.
- **Route.** The tool's own tunnel when it reaches the device (result `serviceDirectory: own-tunnel`, `ownTunnelLink`), which disturbs nothing; otherwise Apple's tunnel, with a tunnel assertion, port discovery and one directory connection, which makes the device reset the Mac's `remoted` once (`serviceDirectory: opened`, and why in `ownTunnelUnavailable`). A stale connection is refused before it starts.
- **Bounds and ending.** `--max-entries` and `--max-bytes` as on a simulator; reading stops after 256 MiB received whatever is kept (600 seconds of an idle phone's every process is about 120 MB), and a record longer than 1 MiB is refused before it is read. `stopReason` is `duration`, `processEnded`, `entryLimit`, `byteLimit` or `closed` (the device ended the stream), and the result also has `receivedRecords`, `filteredOut` and `parseFailures`. The stream is read on a thread of its own, so an MCP server answers other calls meanwhile; cancellation stops it within 100 ms and closes the socket.

## `console`

`console <bundle-id> --seconds N` launches the app (relaunching it if it runs, so the streams attach to the new process) and returns the last `--max-bytes` (default 64 KiB, at most 1 MiB) of each stream as `stdoutTail` and `stderrTail`, with `stdoutBytes`, `stderrBytes`, `truncated` and `stopReason` (`exited`, `duration` or `byteLimit`, the last when the two streams pass 8 MiB together). Arguments after `--` go to the app verbatim.

`--os-log` sets `OS_ACTIVITY_DT_MODE=enable` for the app (`SIMCTL_CHILD_`/`DEVICECTL_CHILD_`), which mirrors the app's own unified-log lines to its stderr as `<date> <Process>[<pid>:<tid>] [<category>] <message>`. Info and above were mirrored; debug was not, unless `OS_ACTIVITY_MODE=debug` was also set (Q8), which the command does not do. The lines carry no level or subsystem; use `logs` for those.

**Simulator.** `simctl launch --terminate-running-process --stdout=<file> --stderr=<file>` returns at once with the PID. The tool polls whether the PID is alive every 100 ms until the app exits or the duration passes, then reads the tails from the files under `tmp/console-<uuid>/` and returns their paths. The app **keeps running** (and writing to those files) unless `--terminate` is given, which runs `simctl terminate` (`terminatedByTool`, `stillRunning`). `exitStatus` is always `null`: simctl does not report how the app ended, so use `last-crash` to tell a crash from a normal exit.

Output the app does not flush is lost in this mode: an unflushed `print` did not reach the file while the app ran or after it was terminated (Q3). It did arrive with `simctl launch --console-pty`, which the command does not use because that mode blocks and ends the app with the capture.

**Physical.** On an iPhone 13 mini (iOS 27.2.1) the probe's flushed and unflushed stdout lines and its stderr line came back, and with `--os-log` so did its mirrored log lines at info and above. When the app aborts, `devicectl` exits non-zero; the result then carries the captured output with `appEndedAbnormally: true`, `devicectlExit`, and the signal in `exitStatus`, rather than failing. A launch that never happens is still an error. `devicectl device process launch --device <UDID> --console --terminate-existing --timeout <seconds + 60> --json-output tmp/console-<uuid>/launch.json <bundle-id> [app-args]`. devicectl stays attached; at the duration the tool sends it SIGINT, which devicectl forwards, so **the app always ends at the duration** (`--terminate` changes nothing). The hard deadline is `seconds + 20`. The duration counts from devicectl's start, so connection and launch time are included. `pid` and `exitStatus` (devicectl's `terminationResult`, for example `{"terminatingSignal":2,"wasCoreDumpCreated":false}`) come from the JSON file when present. Above the default bound, with the probe's `-probeBulk`, the phone's tails were exactly 64 KiB and the 8 MiB stop was `byteLimit`, as on a simulator; lines arrive ending in `\r\n` (devicectl's terminal), and one launch of several failed in `devicectl` before the app's PID was known (2026-11-22, [record](verification.md#phone-session-of-2026-11-22-morning-the-owed-runs-that-need-no-person)).

An earlier run with Settings, which prints nothing of its own, carried only devicectl's three status lines on stdout and nothing on stderr. So the physical result carries `liveVerification` (where the route was checked) and `appOutputObserved`, which says whether anything other than devicectl's own status lines (`Launched application with…`, `Waiting for the application to terminate…`, `App terminated due to…`) arrived. When nothing did, it adds `captured: false` and a note that this does not mean the app printed nothing. A devicectl failure is `tool-failed` with `inputSent: unknown`.

`console` launches an app, so it is not read-only: it is paused by a pending handoff, and failures after the launch can report `possible` or `unknown`. It takes no device lease, like `launch`.

## `last-crash`

Returns the newest crash report (bug type 309) for the app, or `{"found":false,…}` with exit 0.

**Simulator.** The simulator writes crash reports on the Mac, in `~/Library/Logs/DiagnosticReports` (top level; `Retired/` is not read). The tool reads only each candidate's one-line JSON header and keeps reports with platform 7 (iOS simulator), bug type 309, the bundle identifier (`--bundle`) or process name (`--process`, also used to pre-filter file names `<process>-…`), and a header timestamp not before `--since`. A user app's `procPath` contains the simulator's device directory (Q9), so reports from other simulators are excluded; `deviceMatch` is `procPath` when it named this simulator and `unverified` when the path was redacted (system apps). The directory is never listed to the caller. A report appeared about two seconds after the crash; a call made sooner returns `found: false`.

**Physical.** Lists `systemCrashLogs` without recursion (the `reports` route), keeps `.ips` names modified at or after `--since` (and starting with `<process>-` for `--process`; listing entries whose `bug_type` attribute is not 309 are skipped), then downloads the newest candidates one at a time into `tmp/crash-<uuid>/` (the `report` route), at most five, until a header matches the bundle or process. Non-matching downloads are deleted at once. The listing and the downloads run with `--quiet`: without it `devicectl` also wrote the whole listing as a table on stderr, which the tool passes on, and on 2026-11-25 a `last-crash --bundle` on an iPhone Duo under a privacy rule printed every report's name ([record](verification.md#first-run-on-a-physical-iphone-duo)). The candidates downloaded to read their headers may be other apps' reports; on a device under a privacy rule, do not run it. On the iPhone 13 mini it found and downloaded the probe's deliberate abort a few seconds after the crash ([verification](verification.md#app-console-and-last-crash-on-the-phone)).

**Summary.** `exceptionType`, `signal`, `exceptionCodes`, `terminationReason` (the termination indicator, for example `Abort trap: 6`) and `termination`, `crashMessages` (application-specific messages, at most five of 1 KB), `faultingThread` (index, queue, frame count and the top 12 frames as image name, offset and the symbol when the report has one), `lastExceptionBacktrace` when present, `process`, `pid`, `bundleId`, `timestamp`, `captureTime`, `osVersion`, `path` and `symbolicated: false`. System frames and a simulator Debug build's app frames already carry symbols; a stripped app's frames are offsets. `--download <dir>` copies the report into an existing directory and refuses to replace a file.

**Symbols.** `--symbols <path>` (MCP `symbols`; since 2026-11-23) resolves the app's own frames on the Mac. The path is a `.dSYM` (its DWARF files), an `.app` (its executable, its `*.debug.dylib` and its frameworks' executables), an `.xcarchive` or a folder of `.dSYM` bundles such as an archive's `dSYMs` (the DWARF files of each; since 2026-11-24, when such a folder was handed to `dwarfdump` whole and failed), or a Mach-O file. `xcrun dwarfdump --uuid` reads their UUIDs, and only a report image with the same UUID and architecture is resolved, with one `xcrun atos -o <file> -arch <arch> -l <base> <addresses>` for the frames shown, so another build's symbols never name a frame. Each resolved frame gets `atos` (the line as atos wrote it), `sourceLocation` (`File.swift:42`, left out for atos's `<compiler-generated>:0`) and `symbol` when the report had none; `symbolicated` is then true, and `symbols` says how many frames were resolved, which images matched, the UUIDs given, and a `note` when none matched. Run on 2026-11-23 against the probe's deliberate `trap` on an iPhone simulator: the matching Debug build resolved two frames (a closure and a thunk, both `<compiler-generated>:0`, so no file or line), and another build of the same app resolved none and said so. On 2026-11-24 it ran on the iPhone 13 mini against an archived, stripped build of the probe: the report named neither of the app's two frames, and `--symbols` with the archive, or with its `dSYMs` folder, matched the UUID and named both (`closure #1 in LogProbeEmitter.launched(arguments:)` and its thunk, `<compiler-generated>:0`) ([record](verification.md#crash-symbols-for-a-stripped-build-on-the-phone)).

## Signals and cleanup

`logs` and `console` run under the CLI signal scope: SIGINT or SIGTERM cancels the capture, stops and reaps the child (`simctl spawn`, and through it the simulator's `log`; or devicectl) or closes the device's log relay, and exits 130 or 143 without a result. MCP cancellation does the same. A simulator console that is cancelled leaves the app running. On the simulator, no `simctl spawn` or in-simulator `log stream` process was left after a normal end, a limit, SIGINT or SIGTERM.

## Privacy

- Captures are the app's own output and can contain user data. In the simulator, `privacy: .private` values were **not** redacted. Keep captures and `--output` files under `tmp/`, which is not tracked, and do not paste them into documents.
- `logs` keeps only the processes asked for, by predicate and again on the host. `--all` asks for every process: give it a filter unless every app's messages are wanted. On a device, a group or `--all` brings every process's records into the Mac's memory before the filter drops them; they are never written out.
- `last-crash` reads headers only until it finds a match, and returns only that report; for a device, other apps' candidate reports are deleted after their header is read.
- Console files and downloaded reports stay under `tmp/` until deleted.

## Not implemented

- On a physical device: the device's stored log (`CreateArchive`). Following one process across a relaunch is left out by decision: a one-process capture ends with its process.
- Symbolication without being asked: `last-crash` resolves frames only with `--symbols`.
- Crash reports in `Retired/`, and hang or other non-crash report types.
- Extensions: `--bundle` matching covers anything inside the `.app`, but no extension was tested.
