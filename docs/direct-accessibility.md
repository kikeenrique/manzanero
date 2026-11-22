# Native physical accessibility

Physical AX trees, exact-selector presses, scroll-to-visible and bounded selector waits run in `manzanero` against Apple interfaces. No device helper is required. Trees, presses, scrolls and waits have scoped CLI/MCP evidence in Settings and the probe app on iPhone 13 mini. Broad app and device coverage is unfinished. `set-value`, which uses the same selection and guards, is described in [physical typing](physical-typing.md) and [simulator input](simulator-input.md#unicode-text-set-value).

The same trees, selector actions and waits run on a booted simulator through CoreSimulator; see [simulator input and accessibility](simulator-input.md) for how process selection and cleanup differ there. For wire contracts and decoder limits, see [protocol reference](accessibility-protocol.md). For the paired tunnel and directory bootstrap, see [transport](transport.md).

## Current native tree route

```sh
manzanero tree --device <hardware-UDID>
manzanero tree --pid <positive-PID> --device <hardware-UDID>
```

Without PID, the operation selects the process hit at the primary display's logical centre, then rechecks that process and the display geometry after capture. This requires one awake primary display that is native portrait (`rot0`). Until 2026-11-21 its current orientation had to be portrait too, and on a phone turned to landscape `tree` and every selector command failed with "native AX centre selection requires portrait geometry" (seen on the iPhone 13 mini, 2026-11-17). Since then a turned interface (`rot90`, `rot180`, `rot270`) is accepted: the display's bounds are taken the way the interface is turned, as the tree's frames are, and each hit point is mapped into the display's native portrait points before it is sent, the mapping a simulator was measured to need in landscape and the one touch already uses. On the iPhone 13 mini the same evening, in both landscapes, `tree`, `press`, `set-value` and `scroll --search` ran and a `tap` at a row's centre from the tree reached the row, so the mapping holds on the phone ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)). A wrong mapping would be refused at the hit check ("target centre hit is another native element"), never pressed elsewhere; the tree and waits do not depend on it, because the display's centre is the same point either way. An overlay or embedded process can be selected; the result is not a combined system/application tree. A system alert is such an overlay: while a permission prompt is up, the tree is the alert's, and when it is answered the tree is the app's again. Answering one needs no command of its own: `press --label '^Allow' --match regex` presses whichever Allow button the alert shows (Allow, Allow Once, Allow While Using App), and `press --label "^Don.t Allow$" --match regex` refuses (the label is spelled with a curly apostrophe, `Don’t`, which an exact `--label "Don't Allow"` does not match). Checked on an iPhone simulator on 2026-11-21 against the probe's notification prompt: the tree listed `Allow` and `Don’t Allow`, the regex press was accepted, and the alert was gone from the next tree. Selecting by identifier is not possible there: on a fresh iPhone 17e simulator (iOS 27.2) the same prompt's title, message, `Allow` and `Don’t Allow` carried no identifier at all, only labels; the prompt is SpringBoard's, in its app-switcher window, not the app's. (On that simulator's first boot the probe's request went unanswered for about a minute and the prompt came only after a relaunch.) On a device in another language, read the buttons' labels from the tree first. Deciding a permission is the human owner's call. A web page is another ([web content](#web-content)).

An explicit PID permits background inspection and does not verify foreground selection. PIDs must be positive Int32 values. MCP `get_ui_tree` defaults to `platform: physical`.

The route resolves fresh CoreDevice hardware identity, retains an Apple tunnel assertion, discovers the current exact-address RSD directory, validates its device/service identity, then opens raw AX DTX. It reads application → snapshot → application and discards the result if the root identity changed.

## Tree output and consistency

Output includes `format: accessibility-tree`, `parsedHierarchy: true`, `snapshotId`, application selection, nodes, coordinate space and separate cleanup results.

Nodes carry available labels, identifiers, values, frames and native metadata. Frames use device logical points, not pixels or normalized HID coordinates. IDs are paths within one snapshot; they are not reusable action handles. Repeated native identities can occur on different paths.

`atomic: false` and `rootStabilityScope: application-identity` describe the limited recheck. Descendants can change during capture. Visibility/frame metadata does not establish generic hittability or complete offscreen coverage.

The normalizer caps output at 512 nodes/depth 32, validates declared children and refuses malformed/oversized snapshots rather than returning a partial tree. Raw translation tokens stay internal.

### Web content

**On a simulator** the browser is the foreground application and the page is a process it shows, the reverse of a phone. Safari's tree names the page's process twice: as `WebViewProcessID=<n>` in its tab's identifier and as the `processIdentifier` of its `AXRemoteElement` (which reported itself hidden while the page was on screen). Give that PID:

```sh
manzanero tree --pid <page> --simulator <UUID>
manzanero press --label Send --pid <page> --simulator <UUID>
```

Since 2026-11-21, by the human owner's word, `press`, `scroll`, `set-value` and `wait` accept on a simulator a PID that one of the foreground application's remote elements shows with a frame (`AccessibilityPlatform.acceptsShownProcess`); the receipt says `application.selection: explicit-pid-shown-by-frontmost-or-centre-hit` and gives Safari's PID as `hostPid`. A device keeps the rule below. Every other guard is unchanged, the hit test at the target's centre included; on Safari's page the frames were already in screen points, because its web view starts at the screen's top-left corner, so the hit needed no offset. A web view that does not start there was checked on 2026-11-22 with the iOS probe's web screen ([web probe](probe-app.md#web-probe), a `WKWebView` 40 points in from every edge): the first snapshot any client reads of the page has its frames relative to the web view ("Top button" at (12, 95)), and every later one has them in screen points ((52, 249)), however long after the page appeared the first read comes. So the simulator session reads the first snapshot of a page (a snapshot rooted at a remote element) twice in each command and uses the second (`SimulatorAccessibilitySession.snapshot`). With that, `tree --pid`, `press`, `scroll` and a press on the field then `type` worked on the page, a press on the page's very first read included ([record](verification.md#web-content-in-an-apps-own-inset-web-view)). Without `--pid` nothing changed: Safari's tree stops at the remote element, so a selector for a page element has no match. Taps at points and `type` worked on the page before and still do ([record](verification.md#safari-on-a-simulator-by-selector)). `set-value` is acknowledged by a web input and does not change it, as on the phone: press the field, then `type`.

What follows is the phone.

A web page is drawn by a content process of its own, inside the browser's or app's `WKWebView`. Once the page's accessibility is awake, the display centre belongs to that process, and its application snapshot comes back rooted at the host's `AXRemoteElement` with the page's elements beneath. The normalizer accepts that one shape: the root node then carries `externalProcessReference: true` and the host's PID in `processIdentifier`, and `application.pid` is the content process. Seen with Chrome on one iPhone 13 mini ([verification](verification.md#web-content-on-the-phone)).

What follows from it:

- The tree is the page alone. The browser's own controls are in the browser's tree (`tree --pid <browser>`), which stops at the remote element. To act on them while the page holds the display centre, give the browser's PID: `press`, `scroll` and `set-value` accept `--pid` when it is the process that hosts the display-centre one, which is read from the page's root (`processIdentifier`). The receipt then reports `application.selection: explicit-pid-hosting-centre-hit-test` and the page's PID as `hostedPid`. Any other PID is still refused, and every later guard is unchanged: the hit test at the target's centre must answer the target itself. Unit-tested only; not yet run against a browser on a device.
- The first read after a page loads can still select the browser, before the page's accessibility has started. Read again, or `wait` for an element of the page.
- `press`, `scroll` and `wait` use the same selection, so they act on the page. A link or a field usually shares its label with the text inside it or with its HTML label; when the visible-one rule does not settle that, the selector is ambiguous and web elements carry no identifier to fall back on. Use `--index`.
- `set-value` is acknowledged by a web input but did not change it (`valueMatches: false`). Press the field, then `type`.
- An app's own `WKWebView` that does not start at the screen's corner works as a browser does: on the phone the first read of the probe's inset web view already had screen points, and `press`, `scroll` both ways and a press on the field then `type` worked on it (2026-11-22, [record](verification.md#web-content-in-an-apps-own-inset-web-view)).
- `scroll` on a page: a page scrolls with an animation, and read at once after the scroll request its target was hidden in the snapshot and shown by its live attributes, which failed the check afterwards. Since 2026-11-22 the check reads the tree until the target's frame and visibility stop changing (at most six reads, 150 ms apart) before it checks; verified on the phone and on a simulator.
- Focusing a field can zoom the page, and an element can then be wider than the display (a 392-point field on a 375-point display). `press` used to refuse it ("target is not wholly inside the primary display"); since 2026-11-17 it accepts an element that reaches past an edge when its centre is on the display and the hit test there answers the element. It ran on the phone on 2026-11-22 with the probe's zooming web page: a field zoomed to 361 points from x 56, past the right edge, was pressed and typed into ([record](verification.md#selector-by-value-detect-layout-index-masked-read-back-and-the-display-note)).

## Current guarded native press

```sh
manzanero press --id com.example.control --device <UDID>
manzanero press --label 'Exact label' --device <UDID>
# An element with neither identifier nor label, by its exact current value:
manzanero press --with-value 'Buscar' --device <UDID>
# Optional PID: the display-centre process, or the process that hosts it (a browser around a page):
manzanero press --id com.example.control --pid <pid> --device <UDID>
```

Give exactly one of `--id`, `--label` or `--with-value`. `--with-value` compares the element's current value, which is all a search field showing only its placeholder has (the Settings search field); the value changes as soon as something is typed, so read the tree first. `press`, `scroll`, `set-value`, `wait` and `handoff --until` take it; `detect-layout` does not, because its probe changes the field's value. MCP `press_element` takes `device`, `by: identifier|label|value`, `text` and optional positive `pid`. Selector text is exact/case-sensitive unless `--match` says otherwise (below), `1...4096` UTF-8 bytes without NUL; it may begin with `-`, and text that spells one of the global options (`--dry-run`, `--error-format`, `--help`, `--version`) is attached with `=` (`--label=--help`). Pairing files are unsupported.

Before one native press, the operation requires:

1. An awake primary display that is native portrait (its interface may be turned) and its centre-selected process or, with `--pid`, the process that hosts it.
2. The same unique native target in two fresh snapshots.
3. Matching live identifier/frame and known enabled/visible state.
4. A positive-size frame whose centre is on the display and hits that exact target. The frame may reach past an edge. On an Apple TV, physical or simulated, the hit test is left out: there is no pointer, and the system process can answer it ([Apple TV](other-families.md#a-physical-apple-tv)).
5. Rechecked application root, centre process and display geometry.

Repeated paths for one identity are accepted only when the full native attributes agree. Different matching identities, foreign processes, hidden/disabled/ambiguous targets and mismatches are refused. When several distinct elements match and the visible-one rule does not settle it, the failure lists up to five of them with their identifier, visibility and frame (`… multiple distinct or inconsistent matches: 5 elements (identifier 'com.apple.settings.general', visible, frame 20,254 280x52; …). Select one by a unique identifier, or by its position in this list with --index`), so the call can be repeated with `--id` or `--index`. Nothing is chosen for the caller.

**`--index <n>`** (MCP `index`) chooses among several matches when no identifier tells them apart, as on web pages, where a field shares its label with its HTML label. It takes the nth distinct matching element, counted from 1 in the tree's node order, which is the order the failure lists them and the order of `tree`'s node IDs. `press`, `scroll`, `set-value`, `wait`, `detect-layout` and `handoff --until` take it. With it the visible-one rule is not applied and a hidden element is not skipped: the position is taken as given. A position beyond the matches is refused with the list. Every guard after the choice still applies to the chosen element: the second snapshot must give the same identity at that position, and live state, frame and hit are checked as usual. The receipt's `selector` carries the `index`. A position is not an identity: content that gains or loses an earlier match moves it to another element, so read the tree or the failure's list first, and prefer `--id` when an identifier exists.

**`--match exact|contains|regex`** (MCP `match`) says how the text is compared with the field `--id`, `--label` or `--with-value` names. `exact`, the default, is the whole field, case-sensitive. `contains` finds the text anywhere in the field, ignoring case and diacritics (`--label cafe --match contains` matches "Mi CAFÉ"). `regex` is an ICU regular expression (`NSRegularExpression`) found anywhere in the field, case-sensitive: anchor it with `^…$` for a whole field, and start it with `(?i)` to ignore case. A pattern that does not compile is a usage error before any device is contacted. `press`, `scroll` (with `--search` too), `set-value` and `wait` take it, and so does a press by the Inspector's cursor on an Apple TV; `detect-layout` and `handoff --until` stay exact. The mode changes only which elements match: ambiguity, `--index` and every guard after the choice work as for an exact selector, so a loose pattern is usually refused with the list of its matches and settled with `--index`. The receipt's `selector` carries `match` when it is not exact. Run on an iPhone simulator and, for `press --match regex` and an MCP `press_element` with `match: contains`, on the iPhone 13 mini ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)).

```sh
manzanero press --label 'row 1' --match contains --index 1 --simulator <UUID>
manzanero scroll --id 'probe\.list\.row\.5[0-9]$' --match regex --index 1 --search 10 --device <UDID>
```

Only then is one type-7/action-5 request submitted with a fresh token. No coordinate fallback, stale snapshot handle, automatic retry or replay is used. Sequential guards reduce stale targeting but do not make the action atomic or implement XCTest's full hittability calculation.

Native true returns `status: accepted`, `nativeAccepted: true` and `effectVerified: false`. Inspect a fresh image/tree afterward. Errors preserve whether the action was not sent, submitted, refused or accepted, together with stage/cleanup uncertainty.

## Current native scroll-to-visible

```sh
manzanero scroll --id com.example.row --device <UDID>
manzanero scroll --label 'Exact row label' --device <UDID>
```

Optional PID and selection rules match press, including `--with-value` and `--index`. MCP `scroll_to_element` uses `device`, `by: identifier|label|value`, `text` and optional `pid`, `index` and `match`.

The target must already be materialized in the bounded snapshot and resolve to the same unique identity twice. Live state/frame/identifier and application/display guards precede one type-7/action-11 request. Offscreen geometry is allowed at this stage. Without `--search` the operation does not look through an unmaterialized list; it never presses the row or synthesizes swipes.

### Searching a list that loads its rows: `--search`

```sh
manzanero scroll --id probe.tv.row.35 --search 40 --simulator <UUID>
```

A list that loads its rows as it moves holds only the rows near the screen in the tree, so a row further down has no node to select. `--search <steps>` (1...200; MCP `search`) looks forward for it before the guards above. Each step reads the tree; if the selector has no match, it asks for the lowest element of a list to be scrolled into view with the same type-7/action-11 request, waits for the tree to stop changing (a scroll is animated, and the next rows load after it; at most six reads 150 ms apart), and looks again. The search ends when the selector matches, when no anchor moves the tree along the search's axis (the end of the list), or when the steps run out; the last two fail as `target-unresolved` and say how many steps were taken. The normal scroll to the target then runs, and the result adds `search: {steps, maximum, toward}`.

`--toward up`, `left` or `right` (MCP `toward`) makes the search move that way instead of down; the anchor is then the highest, leftmost or rightmost element:

```sh
manzanero scroll --id probe.tv.row.1 --search 60 --toward up --simulator <UUID>
manzanero scroll --id probe.tv.col.28 --search 60 --toward right --simulator <UUID>
```

How the anchor is chosen, and why:

- Only elements that have no children, that carry a label, an identifier or a value, and that are no taller or wider than the display. Scrolling to the list itself put a list back at its top, a strip as wide as the display reaches further right than its last column, and the probe's tree holds unnamed hidden backdrops the size of the display.
- A screen can hold several lists, so the furthest element of all may belong to another one. Elements are grouped by where they start across the axis (the rows of one list share an x, the columns of one strip a y; their parents do not say, because each row has a parent of its own), and each group offers its furthest element. A group with one element is not a list along this axis and is left out when another remains: without that, a search downward scrolled to the columns of a strip below the list and moved the strip sideways.
- The candidates are tried in turn, the group that moved last first and then by reach, at most four at one position. Only movement along the axis counts.
- Hidden elements get no preference. An earlier version tried them first: the probe's rows have hidden parts on screen, and a hidden row above the screen moved a search downward back up.

It moves one way only, and it does not move the list back when it fails. A target already in the tree takes no step. Run on one tvOS 27.2 simulator against the [tvOS probe](probe-app.md#tvos-probe), whose list held 13 of 40 rows. With the list alone on screen, `--search 40` reached row 35 in 22 steps and about 8 seconds, the scroll verified, and a `press` on that row was recorded by the probe. With the list and a strip of thirty columns on screen, on 2026-11-18: down to row 35 in 10 steps, up to row 1 in 28, right to column 28 in 16, left to column 1 in 18, each with the scroll verified and the other list left where it was; a search for a row that does not exist stopped by itself at row 40. On an iPhone simulator (iOS 27.2) against the iOS probe's [list screen](probe-app.md#list-probe), on 2026-11-20: down to row 58, up to row 2, right to column 38 and left to column 2, each verified ([record](verification.md#a-search-on-an-iphone-simulator-and-a-table-rows-two-objects)). Since then it ran on the iPhone 13 mini, on iPad, Duo and watch simulators and on the physical Apple TV ([status](status.md)).

A `UITableView` keeps rows below the screen in the tree and almost none above it, so on the iOS probe's sixty-row list a search downward from the top reaches row 60 in 4 steps and a search upward from the bottom needs 16 to reach row 1 on a simulator; on the phone 15 were not enough ([record](verification.md#phone-session-of-2026-11-21-the-days-new-commands-landscape-and-a-recording)). Give a search upward a larger budget.

After native true or false, one read-only observation re-resolves the target and checks enabled/visible state, matching frame/identifier, a centre that is on the display and hits the exact target (the frame may reach past an edge, as for press), and application/display stability.

- Passing observation: `status: postcondition-verified`, `postconditionVerified: true`.
- Completed native reply but failed observation: `status: postcondition-failed`, `postconditionVerified: false`, with `postconditionFailure`.

The latter is a structured result with exit zero: callers must inspect the status. `nativeResult`, `before`/`after` and postcondition remain separate. Native false can describe an already-visible target. These AX checks are not independent pixel verification; `verified` remains false.

## Bounded wait for a selector condition

```sh
manzanero wait --id com.example.button --device <UDID>
manzanero wait --label 'Loading' --until gone --timeout 20 --device <UDID>
manzanero wait --id com.example.field --pid <pid> --until value --value 'Done' --interval 1 --device <UDID>
```

MCP `wait_for_element` takes `device`, `by: identifier|label|value`, `text` and optional `pid`, `index`, `until`, `value`, `timeout_seconds` and `interval_seconds`. It is annotated read-only. On the iPhone 13 mini, `visible`, `gone`, `enabled`, `disabled` and `value` were each met in Settings, and timeouts exited 124 ([verification](verification.md#remaining-phone-checks-keys-files-waits-prompts-and-a-live-mcp-session)); `focused` has been checked on an Apple TV simulator only ([other families](other-families.md#focus-in-the-tree-and-in-waits)).

The wait polls inside one AX session until a condition holds or the timeout expires. It sends no input, takes no per-device lease and is not paused by a pending handoff, the same as `tree`. Each poll is a fresh, non-atomic, bounded snapshot evaluated with the exact selector matcher that press and scroll use.

| `--until` | Met when |
| --- | --- |
| `visible` (default) | Exactly one matching identity exists in the selected process and its snapshot visibility is true, and the live visibility attribute does not disagree. |
| `gone` | No path matches, or every matching path is explicitly not visible. |
| `enabled` / `disabled` | `visible`, plus the live enabled attribute (27) is true / false. |
| `value` | `visible`, plus the snapshot value is exactly the `--value` string. `--value` alone implies `--until value`. |
| `focused` | `visible`, plus the live focused attribute (28) is true. Accepted on every platform; checked on an Apple TV simulator and on one physical Apple TV 4K, where focus moves with `remote`. |

Visibility is the native snapshot attribute, not hittability or pixel evidence. A missing visibility or enabled attribute never satisfies a condition, including `gone`. Non-string values never match `--value`.

Options may come in any order. `--id`, `--label`, `--with-value` and `--value` take the next argument as their value even when it begins with `-`; attach a value that spells a global option with `=`, as for press. With `--pid`, the selector cannot be exactly `--until`, `--value`, `--timeout` or `--interval`: the wait reads its options after the selector by name.

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

Several distinct matching identities do not satisfy `visible`, `enabled`, `disabled` or `value`, with one exception: when exactly one match is visible and every other is explicitly not visible, the visible one is the element. Settings rows need this, because a row and the hidden text inside it share a label. `matchCount` still reports all of them. With `--index` the element at that position stands for the selector instead: `gone` is then met when that element is hidden or there is no element at that position, and the other conditions report `no-match` while there is none. Otherwise the poll reports `reason: ambiguous` with `matchCount`, and polling continues, because transitions often show the old and new screens together. A match whose visibility is unknown always keeps the result ambiguous. Repeated paths for one identity count as one element when their attributes agree. `matchPaths` gives the raw path count. For `gone`, every match must be hidden, however many there are. A match that is a reference into another process is reported as `foreign-process` and does not satisfy a positive condition.

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

### Observed and still unverified

Observed on the iPhone 13 mini: a wait for a visible Settings row was met on its first poll in about 1 s, and a `tree` of the Home screen (245 nodes) took about 5 s. A label wait on a row whose label includes its value matched only the hidden inner text and reported `not-visible`; use the identifier for such rows. One wait reported `subscriptionStop: unconfirmed` while its tunnel release was acknowledged; the cause is unknown.

Not yet observed on a device:

- whether the phone sends unsolicited callbacks while a subscription idles between polls, which would consume the frame and byte budgets;
- how the application request fails for an exited PID;
- whether snapshot visibility tracks on-screen state during animations.

## Ownership, deadlines and failures

One session has one outstanding semantic request. Carrier acknowledgements do not satisfy AX reads/actions. Matching result type, target, attributes and semantic status are checked; some nil-translation attribute/action replies lack a demonstrated sequence/target correlator, so one-outstanding-request ownership remains important.

The AX session uses a 30-second overall read budget, four-second phases, 256 frames, 40 MiB callback bytes and at most eight queued results. A wait scales the overall budgets to its poll bound (see above). Cleanup has an independent three-second/32-frame allowance and attempts subscription disable even after ambiguous enable.

A `tree` or a wait whose own tunnel ended under it (the cable pulled) is run once more on a new connection, and its result then carries `retriedAfter`, the first attempt's failure; commands that send input are never run again. `detect-layout` reports the route of its last accessibility request in `route`, and a `handoff` that watches for an element reports each look's in `observation.route`, with the same fields. A failed physical accessibility command says its route in its message (`Route: serviceDirectory=own-tunnel, ownTunnelLink=network.`). Every physical result also carries `serviceDirectory`: `opened` when the command read the device's service directory, `reused-port` when it connected to the accessibility port an earlier command of the same process had read from it, `reused-saved-port` when an earlier process had saved it, `own-tunnel` when the command ran on the tool's own tunnel, with `ownTunnelLink` saying whether the device was reached on its `cable` or on the `network` (the default; `MANZANERO_OWN_TUNNEL=0` turns it off; [why it matters](transport.md#the-cost-of-this-route)).

Successful observations can retain uncertain subscription cleanup. Inspect `cleanup.subscriptionStop`, `confirmed` and diagnostics, plus separate `connectionCleanup.tunnelAssertionRelease`. An acknowledgement is not independent proof of device-side teardown.

Cancellation propagates after cleanup attempts. No operation is replayed. `press`, `scroll` and `set-value` take the device lease, so they are refused as `device-quarantined` while the device is [quarantined](native-input.md#quarantine-after-an-uncertain-release); they hold nothing themselves and never cause a quarantine. `tree` and `wait` are not affected. Blocking private calls, force exit, crashes/disconnection and delayed same-type replies retain uncertainty.

## Evidence and earlier failures

The current Network route returned Settings trees through diagnostic, CLI and real MCP, including omitted-PID foreground selection and PNG/tree inspection. Exact identifier/label presses navigated General ↔ Información. Scroll moved a Settings row; a later MCP already-visible check returned native false with a passing postcondition and unconfirmed unsubscribe. With a paste-permission prompt showing, `tree` returned the prompt's title and buttons (owned by SpringBoard) and `press --label` on its decline button dismissed it; the earlier refusal there (error 8) came from the hit test at an empty display centre, now asked with the container client type.

Earlier CoreDevice named-socket, raw RSD inventory and Apple relay attempts failed before subscription; their code has since been removed. Error 4000/underlying POSIX 83 did not identify a missing UI Automation setting or establish a private entitlement requirement. The later Network route succeeded; those earlier failures were not converted into evidence for the new route.

See [verification](verification.md) for environment and scope. Other apps, overlays, rotations, families, interrupted actions and reliable recovery remain unverified or incomplete.

## Diagnostics

```sh
mise run test:mcp-physical <UDID> <pid>
mise run test:mcp-foreground <UDID>
mise run test:mcp-press <UDID> identifier com.example.control
mise run test:mcp-scroll <UDID> com.example.row
```

Read/press/scroll tests have different effects. Use their help and inspect private captures where visual effect matters. The historical idevice AX implementation has been removed; old helper-backed results are migration evidence, not current execution instructions.
