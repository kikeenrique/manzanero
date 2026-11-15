# Native physical accessibility

Physical AX trees, exact-selector presses and scroll-to-visible run in `manzanero` against Apple interfaces. No device helper is required. These operations have scoped CLI/MCP evidence in Settings on iPhone 13 mini; broad app/device coverage is unfinished.

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

## Ownership, deadlines and failures

One session has one outstanding semantic request. Carrier acknowledgements do not satisfy AX reads/actions. Matching result type, target, attributes and semantic status are checked; some nil-translation attribute/action replies lack a demonstrated sequence/target correlator, so one-outstanding-request ownership remains important.

The AX session uses a 30-second overall read budget, four-second phases, 256 frames, 40 MiB callback bytes and at most eight queued results. Cleanup has an independent three-second/32-frame allowance and attempts subscription disable even after ambiguous enable.

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
