# Native physical accessibility

Physical AX trees, exact-selector presses, scroll-to-visible and bounded selector waits run in `manzanero` against Apple interfaces. No device helper is required. Trees, presses and scrolls have scoped CLI/MCP evidence in Settings on iPhone 13 mini. Waits are tested locally only. Broad app and device coverage is unfinished.

For wire contracts and decoder limits, see [protocol reference](accessibility-protocol.md). For the paired tunnel and directory bootstrap, see [transport](transport.md).

## Current native tree route

```sh
manzanero physical <hardware-UDID> tree
manzanero physical <hardware-UDID> tree <positive-PID>
```

Without PID, the operation selects the process hit at the primary display's logical centre, then rechecks that process and the display geometry after capture. This requires one awake primary display with native/current portrait orientation (`rot0`). An overlay or embedded process can be selected; the result is not a combined system/application tree.

An explicit PID permits background inspection and does not verify foreground selection. PIDs must be positive Int32 values. MCP `get_ui_tree` defaults to `platform: physical`.

The route resolves fresh CoreDevice hardware identity, retains an Apple tunnel assertion, discovers the current exact-address RSD directory, validates its device/service identity, then opens raw AX DTX. It reads application → snapshot → application and discards the result if the root identity changed.

## Tree output and consistency

Output includes `format: accessibility-tree`, `parsedHierarchy: true`, `snapshotId`, application selection, nodes, coordinate space and separate cleanup results.

Nodes carry available labels, identifiers, values, frames and native metadata. Frames use device logical points, not pixels or normalized HID coordinates. IDs are paths within one snapshot; they are not reusable action handles. Repeated native identities can occur on different paths.

`atomic: false` and `rootStabilityScope: application-identity` describe the limited recheck. Descendants can change during capture. Visibility/frame metadata does not establish generic hittability or complete offscreen coverage.

The normalizer caps output at 512 nodes/depth 32, validates declared children and refuses malformed/oversized snapshots rather than returning a partial tree. Raw translation tokens stay internal.

## Current guarded native press

```sh
manzanero physical <UDID> press-id com.example.control
manzanero physical <UDID> press-label 'Exact label'
# Optional PID must agree with the selected display-centre process:
manzanero physical <UDID> press-id <pid> com.example.control
```

MCP `press_element` takes `device`, `by: identifier|label`, `text` and optional positive `pid`. Selector text is exact/case-sensitive, `1...4096` UTF-8 bytes without NUL. Pairing files are unsupported.

Before one native press, the operation requires:

1. An awake portrait primary display and its centre-selected process.
2. The same unique native target in two fresh snapshots.
3. Matching live identifier/frame and known enabled/visible state.
4. A positive-size frame wholly inside the display whose centre hits that exact target.
5. Rechecked application root, centre process and display geometry.

Repeated paths for one identity are accepted only when the full native attributes agree. Different matching identities, foreign processes, hidden/disabled/ambiguous targets and mismatches are refused.

Only then is one type-7/action-5 request submitted with a fresh token. No coordinate fallback, stale snapshot handle, automatic retry or replay is used. Sequential guards reduce stale targeting but do not make the action atomic or implement XCTest's full hittability calculation.

Native true returns `status: accepted`, `nativeAccepted: true` and `effectVerified: false`. Inspect a fresh image/tree afterward. Errors preserve whether the action was not sent, submitted, refused or accepted, together with stage/cleanup uncertainty.

## Current native scroll-to-visible

```sh
manzanero physical <UDID> scroll-id com.example.row
manzanero physical <UDID> scroll-label 'Exact row label'
```

Optional PID and selection rules match press. MCP `scroll_to_element` uses `device`, `by`, `text` and optional `pid`.

The target must already be materialized in the bounded snapshot and resolve to the same unique identity twice. Live state/frame/identifier and application/display guards precede one type-7/action-11 request. Offscreen geometry is allowed at this stage. The operation does not search an unmaterialized list, press the row or synthesize swipes.

After native true or false, one read-only observation re-resolves the target and checks enabled/visible state, matching frame/identifier, full display containment, exact centre hit and application/display stability.

- Passing observation: `status: postcondition-verified`, `postconditionVerified: true`.
- Completed native reply but failed observation: `status: postcondition-failed`, `postconditionVerified: false`, with `postconditionFailure`.

The latter is a structured result with exit zero: callers must inspect the status. `nativeResult`, `before`/`after` and postcondition remain separate. Native false can describe an already-visible target. These AX checks are not independent pixel verification; `verified` remains false.

## Bounded wait for a selector condition

```sh
manzanero physical <UDID> wait-id com.example.button
manzanero physical <UDID> wait-label 'Loading' --until gone --timeout 20
manzanero physical <UDID> wait-id <pid> com.example.field --until value --value 'Done' --interval 1
```

MCP `wait_for_element` takes `device`, `by: identifier|label`, `text` and optional `pid`, `until`, `value`, `timeout_seconds` and `interval_seconds`. It is annotated read-only. This route is implemented and covered by local fake-session tests only; it has not been run on hardware.

The wait polls inside one AX session until a condition holds or the timeout expires. It sends no input, takes no per-device lease and is not paused by a pending handoff, the same as `tree`. Each poll is a fresh, non-atomic, bounded snapshot evaluated with the exact selector matcher that press and scroll use.

| `--until` | Met when |
| --- | --- |
| `visible` (default) | Exactly one matching identity exists in the selected process and its snapshot visibility is true, and the live visibility attribute does not disagree. |
| `gone` | No path matches, or every matching path is explicitly not visible. |
| `enabled` / `disabled` | `visible`, plus the live enabled attribute (27) is true / false. |
| `value` | `visible`, plus the snapshot value is exactly the `--value` string. `--value` alone implies `--until value`. |

Visibility is the native snapshot attribute, not hittability or pixel evidence. A missing visibility or enabled attribute never satisfies a condition, including `gone`. Non-string values never match `--value`.

Options follow the selector. The first operand is always positional, so a selector can begin with `--`. With a PID, the selector cannot be one of the option names.

| Option | Range | Default |
| --- | --- | --- |
| `--timeout` | 0...60 seconds; 0 checks once | 10 |
| `--interval` | 0.25...5 seconds | 0.5 |

The loop polls, stops if the condition is met, stops if the deadline has passed, and otherwise sleeps until the next interval or the deadline, whichever comes first. A poll therefore always runs at or after the deadline unless one poll overran it. The number of polls is also capped at `timeout/interval + 2`.

### Selection while waiting

- **Without PID:** the display geometry is read once before subscribing. The display must be awake, as for `tree`. Every poll then re-selects the process at the display centre, so an app launch or a sheet from another process is followed. The result reports the PID of the last poll, `processesObserved` (distinct PIDs, at most 16) and `processChanges`. A met condition is reported only after the application identity and centre process are rechecked within the poll and the display geometry is read again and found unchanged. A display that changed or turned off before the result is a failure. On a timeout the recheck is reported as `displayRecheck`.
- **With PID:** that process is observed even if it is in the background. No display query is made. If the PID exits, the application request fails, which ends the session. The wait then reports a failure, not `gone`, because a dead process cannot be told apart from a transport fault.
- If the application identity changes between the snapshot and its recheck, that poll counts as not met (`selection-changed`) and the wait continues.

### Ambiguity

Several distinct matching identities never satisfy `visible`, `enabled`, `disabled` or `value`. The poll reports `reason: ambiguous` with `matchCount`, and polling continues, because transitions often show the old and new screens together. Repeated paths for one identity count as one element when their attributes agree. `matchPaths` gives the raw path count. For `gone`, every match must be hidden, however many there are. A match that is a reference into another process is reported as `foreign-process` and does not satisfy a positive condition.

### Results and exit codes

| Outcome | CLI | MCP |
| --- | --- | --- |
| Condition met | exit 0, JSON `status: condition-met` | `isError: false` |
| Timeout | exit 124, JSON `status: timed-out` | `isError: false`; a timeout is an answer |
| Validation, transport or session failure, display change | exit 1, diagnostic on stderr | `isError: true` |
| SIGINT / SIGTERM, MCP cancellation or EOF | 130 / 143 after cleanup | request cancelled |

Both structured outcomes include `conditionMet`, `polls`, `elapsedSeconds`, `selector`, `condition`, `application`, `processesObserved`, the last poll's `observation` (`pid`, `reason`, `detail`, `matchCount`, `matchPaths`, `foreignProcessMatches`, `element`), `cleanup` and `connectionCleanup`. `element` gives the identifier, label, value, hint, frame (logical points), traits, visible and live `enabled` of the unique match, or null. A timeout also gives `timeoutReason`. Reasons include `no-match`, `ambiguous`, `not-visible`, `visibility-unknown`, `value-differs`, `not-enabled`, `still-enabled`, `enabled-unknown`, `live-visibility-differs`, `still-visible`, `foreign-process` and `selection-changed`.

Failures name the stage (`display`, `start`, `select-process`, `application`, `snapshot`, `live-attributes`, `selection-recheck`, `interval`, `display-recheck`), the poll count, the elapsed time, the last observation and the subscription cleanup. Tunnel assertion release is appended as for other native AX operations. Oversized or malformed snapshots fail rather than match a partial tree. Cancellation, whether during a poll or between polls, runs the same subscription disable and tunnel release and writes a diagnostic to stderr. The CLI wait is covered by the physical-input signal scope.

### One session, budgets and the service queue

Repeated requests in one `AccessibilitySession` are supported: press already reads two snapshots, attributes, hits and rechecks in one session. The constraint is the session's whole-life budget. By default it is 30 seconds, 256 frames and 40 MiB of callbacks, which suits one observation. A wait therefore creates its session with scaled limits: `timeout + 30 s`, `64 + 16 × maximum polls` frames and `max(40 MiB, 4 MiB × maximum polls)` callback bytes. Each request keeps its four-second phase, and cleanup keeps its own allowance. A failed or timed-out request still closes the session, and the wait does not reconnect.

The command service runs on its own serial queue. A wait holds that queue only while a poll's blocking requests run, which is at most a few seconds for each request. The interval between polls is an asynchronous sleep, so other calls to the same MCP server or service can run between polls instead of queueing for the whole wait.

### Unverified

None of the following has been observed on a device yet:

- how long a snapshot takes;
- whether the phone sends unsolicited callbacks while a subscription idles between polls, which would consume the frame and byte budgets;
- how the application request fails for an exited PID;
- whether snapshot visibility tracks on-screen state during animations.

The first live check should cover each of these.

## Ownership, deadlines and failures

One session has one outstanding semantic request. Carrier acknowledgements do not satisfy AX reads/actions. Matching result type, target, attributes and semantic status are checked; some nil-translation attribute/action replies lack a demonstrated sequence/target correlator, so one-outstanding-request ownership remains important.

The AX session uses a 30-second overall read budget, four-second phases, 256 frames, 40 MiB callback bytes and at most eight queued results. A wait scales the overall budgets to its poll bound (see above). Cleanup has an independent three-second/32-frame allowance and attempts subscription disable even after ambiguous enable.

Successful observations can retain uncertain subscription cleanup. Inspect `cleanup.subscriptionStop`, `confirmed` and diagnostics, plus separate `connectionCleanup.tunnelAssertionRelease`. An acknowledgement is not independent proof of device-side teardown.

Cancellation propagates after cleanup attempts. No operation is replayed. Blocking private calls, force exit, crashes/disconnection and delayed same-type replies retain uncertainty.

## Evidence and earlier failures

The current Network route returned Settings trees through diagnostic, CLI and real MCP, including omitted-PID foreground selection and PNG/tree inspection. Exact identifier/label presses navigated General ↔ Información. Scroll moved a Settings row; a later MCP already-visible check returned native false with a passing postcondition and unconfirmed unsubscribe.

Earlier CoreDevice named-socket, raw RSD inventory and Apple relay attempts failed before subscription. Error 4000/underlying POSIX 83 did not identify a missing UI Automation setting or establish a private entitlement requirement. The later Network route succeeded; those earlier failures were not converted into evidence for the new route.

See [verification](verification.md) for environment and scope. Other apps, overlays, rotations, families, interrupted actions and reliable recovery remain unverified or incomplete.

## Diagnostics

```sh
mise run test:mcp-physical <UDID> <pid>
mise run test:mcp-foreground <UDID>
mise run test:mcp-press <UDID> identifier com.example.control
mise run test:mcp-scroll <UDID> com.example.row
```

Read/press/scroll tests have different effects. Use their help and inspect private captures where visual effect matters. The historical idevice AX implementation is disabled; old helper-backed results are migration evidence, not current execution instructions.
