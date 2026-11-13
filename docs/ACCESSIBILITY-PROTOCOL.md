# Physical accessibility observations

**Current runtime:** the idevice executable path described below is disabled. The direct in-process replacement is being developed; see [direct accessibility migration](DIRECT-ACCESSIBILITY.md). Historical observations are migration targets, not current availability claims.

## Active per-application tree

```sh
mise run idevice:build --debug --offline
mise run build
mise run cli physical <UDID> tree
mise run test:mcp-foreground <UDID>
mise run cli physical <UDID> processes
# Use a current application PID from processes or the result of launch:
mise run cli physical <UDID> tree <pid>
# Optional real MCP stdio verification of that same read:
mise run test:mcp-physical <UDID> <pid>
```

`tree [pid]` performs active read-only requests through the optional idevice bridge and the existing physical Developer Mode preflight. Without a PID, a primary-display centre hit selects the application process. The displayed PID and display geometry are checked again after observation. Exactly one primary display and native/current `rot0` are required, using the display discovery described below for presses. Selection is reported as `centre-hit-test`; an overlay or embedded process may be selected, and the result is not a combined display tree. An explicit PID must be positive and no greater than 2147483647; it preserves background application inspection without display selection. The optional `--pairing-file` prefix uses the existing bridge transport; that Wi-Fi path is not verified by the USB checks below. MCP `get_ui_tree` accepts `platform: physical`, `device`, and optional integer `pid`. Its default remains the simulator/AXe tree for existing clients. Supplying a PID for a simulator is rejected.

The protocol path follows the MIT-licensed [pinned ipb research and implementation](https://github.com/ipbtools/ipb/blob/8c227a10710dad479852aa0203de729fed57471b/docs/protocol.md), with the retained [license notice](../ThirdParty/ipb-LICENSE.txt). The host answers `hostAPIVersion` with 7 and requires device API version 26, which is a protocol version rather than the iOS version. After `clientNeedsAccessibility: true`, it sends `AXPTranslatorRequest` type 1 for the PID's application root, then type 2 / attribute 52 for a native descendant snapshot. All requests have action type zero. Data travels as a keyed archive argument to `processDataFromHost:`; `processDataFromRemoteDevice:` supplies semantic responses separately from DTX call acknowledgements.

The native snapshot options request attributes `[2001,2002,2003,2004,5019,2006,2025,5003,5004,3003]`, traversal from parents to children, depth 48, and child/array caps 512. These IDs supply label, hint, frame, traits, identifier, value, visibility, and native class/bundle metadata. They are distinct from the older AXP attribute IDs. Missing properties stay absent; unsupported value/geometry shapes cause an error instead of an inferred field. Geometry is **device logical points**, not screenshot pixels or normalized HID coordinates. The observed portrait root was 375×812, while screenshots were 1125×2436.

Success returns `format: accessibility-tree`, `parsedHierarchy: true`, nodes with `parentId`/`children`, and a random `snapshotId`. IDs such as `n0` identify paths within this observation only. Repeated native elements on different parent paths remain separate occurrences; equal labels do not establish identity. Opaque translation tokens never appear in the returned tree. Native class/bundle fields retain their numeric keys under `nativeAttributes`; no XCUIElementType mapping or generic hittability claim is made.

The snapshot response must report request type 2, attribute 52, error zero, and the matching root identity. Each declared child count must match its array. Host traversal rejects more than 512 nodes or depth over 32 without emitting a partial tree. The application root is queried again afterward and must retain its PID/object identity and application flag. `rootStabilityScope: application-identity` and `atomic: false` describe that limited check: descendants can change during the operation. Explicit PID selection may inspect a background app; no foreground/display hit test is performed. A tree is not every UIView, a combined system/app dump, or proof that device-side caps include every offscreen node.

There is one outstanding semantic request at a time; older queued notifications are discarded before sending it. A bounded data-only metadata read routes callbacks by response request type before full semantic decoding. Unrelated payloads are not expanded; matching payloads still reject non-finite numbers and invalid archives. DTX replies must match identifier/conversation/channel, and unsupported reply kinds fail. Semantic errors, missing status/data, target/attribute mismatches, changed root, malformed children, or decode limits abort the read. No shallow fallback or automatic request retry occurs. The observation deadline is 30 seconds, individual reply phases have four-second deadlines, and cleanup has three seconds.

After an attempted subscription, the host attempts `clientNeedsAccessibility: false`. A correlated reply reports `cleanup.subscriptionStop: confirmed`. If a typed transport closure occurs while waiting for that reply, a completed tree or accepted press is retained with `connection-closed-before-ack`, `confirmed: false`, and an explicit warning. This reports the observed close-before-ack condition recognized by the pinned ipb implementation; it does not prove device-side cleanup. Timeout, malformed replies, and other cleanup errors still fail the operation. Earlier operation errors remain errors even if cleanup sees a closure. The bridge's outer 60-second deadline or process termination can interrupt cleanup. The separate raw `ax-snapshot` probe retains its stricter correlated-ack requirement.

Active protocol decoding remains data-only. Its internal mode preserves opaque data for fresh request tokens and permits archive wrapper depth 512, while the public offline structural inspector retains its original depth 64 and byte-count-only opaque data. Both retain the 16 MiB input-per-archive, four-archive, 100,000-value, and 32 MiB expanded-content limits. The session also caps received callback archives at 40 MiB, queued callbacks at eight, and frame/response loops. These host limits are not an audit of upstream plist parsing allocations.

On the selected awake/unlocked USB iPhone 13 mini, a CLI read and a separate real MCP stdio exchange each returned a 263-node Settings snapshot, maximum depth 20, with confirmed subscription stop. A fresh screenshot matched visible labels including Pantalla y brillo, Desarrollador, General, and the search close control. This is scoped physical evidence for this Settings/search/keyboard state. Other apps, overlays, rotations, secure content, Wi-Fi, stable actionable references, and broad completeness remain unverified or unimplemented. Fresh selector presses are a separate operation below.

## Fresh selector presses

```sh
mise run cli physical <UDID> press-id <pid> com.example.button
mise run cli physical <UDID> press-label <pid> 'Exact visible label'
# Omit PID to select the primary display-centre process:
mise run cli physical <UDID> press-id com.example.button
mise run cli physical <UDID> press-label 'Exact visible label'
```

These commands submit one native AX press, not a coordinate tap. MCP exposes `press_element` with `device`, optional integer `pid`, `by: identifier|label`, `text`, and optional existing `pairing_file`. Selector text is an exact, case-sensitive string of 1...4096 UTF-8 bytes without NUL. The native AX path uses the idevice bridge, independently of the separate idevice HID path whose Home/tap effects remain unresolved. No proprietary binary, upstream Python runtime, XCTest, app installation, coordinate fallback, or automatic retry is used.

The bridge discovers exactly one advertised RemoteXPC service supporting `com.apple.coredevice.feature.getdisplayinfo` and queries it on the same owned RSD connection. Exactly one primary display is required. Effective bounds divided by `pointScale` supply logical coordinates; only native/current `rot0` is supported. A type-6 point request at the primary display centre selects the application PID before any selector lookup; an explicit PID must match it. Its `NSValue` point uses primary `displayId: 0` in the captured AXP request format; this is distinct from the display metadata's identifier.

Two fresh native snapshots must resolve the selector to the same single distinct PID/object identity. Multiple paths of one native element are accepted only when their native attributes agree; different matching elements are ambiguous, including hidden duplicates. A type-5 read of AXP attributes 21/25/27/32 rechecks frame, available native identifier, and known enabled/visible state. The whole positive-size frame must fit inside the primary display, and its centre must hit the exact selected native identity. The application root, displayed PID at display centre, and current display geometry/orientation are checked again before submission. These sequential checks reduce stale/occluded targeting; they do not make the operation atomic or implement XCTest's complete hittability calculation.

Only after those checks does the bridge send type 7 / action 5 with the fresh token and nil parameters. Native result true/1 produces `status: accepted`, `nativeAccepted: true`, `verified: false`, and `effectVerified: false`; the caller must observe the effect. No raw token is returned. Errors before submission say no AX press was sent. A refusal, timeout, transport error after submission, or cleanup failure preserves `state=submitted|refused|accepted` in the diagnostic and warns against automatic retry. Cleanup uses the confirmed versus connection-closed-before-ack distinction described above. The 30-second action deadline, three-second cleanup deadline, and outer 60-second bridge deadline can interrupt work; no rollback is promised.

Both identifier and exact-label navigation were screenshot-verified on the USB iPhone 13 mini: General → Información by `com.apple.settings.general.about`, then Información → General by the `General` back-button label. An earlier attempt on Software Update stopped with no press because its centre-hit PID differed from the requested Settings PID. The cause of that mismatch was not isolated. Embedded/overlay processes and other states can therefore be conservatively refused; the tool does not switch PID or fall back to a tap. Other apps, rotations, Wi-Fi, secure fields, modal permissions, and generic press effects remain unverified. The live action checks used the shared CLI; MCP routing is tested synthetically, with no separate real MCP press exchange yet.

## Scroll an element into view

```sh
mise run cli physical <UDID> scroll-id [pid] com.example.row
mise run cli physical <UDID> scroll-label [pid] 'Exact row label'
```

MCP exposes `scroll_to_element` with `device`, `by: identifier|label`, `text`, optional `pid`, and optional `pairing_file`. Selection, selector bounds, Developer Mode preflight, handoff pause, and portrait display requirements match the physical press path. This operation follows the pinned ipb protocol research mapping type 7 / action 11 to native `scrollToVisible`; it does not submit a press or a coordinate swipe.

The target must already exist in the bounded native snapshot. Two fresh snapshots must resolve the same unique native identity. Live enabled state, identifier, frame, and known visibility must agree with the latest snapshot; an offscreen frame is allowed and visibility may be false. Application identity, display-centre process, and display geometry are rechecked before one action. It cannot discover an unmaterialized row by repeatedly scrolling or retry an unknown result.

`nativeResult` preserves the device's Boolean response. Native false can mean an already-visible target, and native true alone does not prove the target became visible. One subsequent read-only observation resolves the same identity, checks live and snapshot visibility/enabled state and matching geometry, requires the full positive-size frame inside the display, checks its exact centre hit, and rechecks application/display selection. Passing these checks returns `status: postcondition-verified`, `postconditionVerified: true`, and public `before`/`after` state. These are sequential AX checks, not an atomic transaction or independent screenshot proof; `verified` remains false.

A completed native response with a failed post-action observation returns `status: postcondition-failed`, `postconditionVerified: false`, and `postconditionFailure` while retaining `nativeResult` and `before`. The command returns this structured observation with exit zero; callers must inspect the status and verification field. No follow-up action is sent. Pre-submission failures say no AX scroll was sent; errors after submission preserve `state=submitted|native-true|native-false` and advise inspection before retrying. Cleanup and deadlines match the active tree/press behavior above. No device-side rollback or full-list coverage is promised.

On the selected USB iPhone 13 mini, a CLI identifier scroll moved the Settings Captura de pantalla row from y=793 to y≈416.33 logical points with native true and a passing postcondition; independent screenshots confirmed movement into view. A distinct real MCP call on that now-visible row returned native false, unchanged geometry, and a passing visibility/hit postcondition. The MCP result honestly reported connection closure before cleanup acknowledgement. A later label selection for Información found zero matches in its fresh snapshot and sent no scroll; a previously returned tree does not guarantee continued materialization. See [verification records](VERIFICATION.md).

## Evidence and scope

The physical phone's advertised services included `com.apple.accessibility.axAuditDaemon.remoteAXService`; see [transport notes](TRANSPORT.md). Advertisement does not prove that a request will succeed. The older DTX audit service, `com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote`, offers focus/audit operations and must not be treated as an interchangeable full-tree API.

Static inspection of [private framework reference removed] 0.9.0/build 90 in Hopper identified:

| Observation | Location/evidence | What it establishes |
| --- | --- | --- |
| RSD connection for the newer service | `start_accessibility` closure at `0x342f4c` | A compiled service connection path; no live authorization result. |
| DTX calls and replies in the accessibility worker | `sub_37e700` call graph | DTX framing rather than an assumed RemoteXPC request dictionary on this service. |
| `clientNeedsAccessibility:` | String at `0x73ca0f`, length 25; DTX call at `0x37e8ec` | A selector name. The nearby NSKeyedArchive encoder and Boolean-shaped value suggest enable/disable arguments; semantics remain unverified live. |
| `processDataFromRemoteDevice:` | Worker selector comparison around `0x37f0a0`–`0x37f104` | A callback selector handled by the worker. It does not prove every callback is a complete tree. |
| Keyed archive parsing | `parse_dump` at `0x3e6ed8` calls the framework's archive parser | Archive-based processing exists; the full tree schema is not yet independently established. |

These are interoperability observations, not copied implementation code. No proprietary binary is linked or used at runtime. The bridge uses the pinned open-source [idevice DTX message implementation](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/dvt/message.rs) and `ns-keyed-archive` for encoding.

## Implemented probe

`appledevicescmd physical <UDID> ax-snapshot` opens the advertised service through the bridge's usbmuxd or explicit Wi-Fi tunnel, sends the inferred enable request, acknowledges incoming calls that request a reply, and captures the first matching callback's archive argument. It then attempts a disable request and requires its correlated reply before returning success. Acquisition is bounded to 30 seconds/256 frames; cleanup has a separate 3-second deadline, inside the bridge's overall operation deadline.

Frames are checked for the DTX magic, 32-byte header, bounded fragment count/size, fragment order, and consistent payload lengths before the library decoder runs. The current maximum assembled payload is 16 MiB and the fragment limit is 64. These checks are not an audit of the upstream archive decoder or proof of all valid device wire variants.

The JSON result identifies `format: nskeyedarchive-base64`, contains `archive`, and explicitly sets `parsedHierarchy: false` and `experimental: true`. It is a raw observation artifact, not stable element references, labels, or a selector-targetable physical hierarchy. Keep saved results under ignored `tmp/`; they may contain device UI data.

## Saving and inspecting a callback

```sh
mise run build
# The optional bridge must also have been built with mise run idevice:build.
mise run cli physical <UDID> ax-snapshot tmp/accessibility.plist
mise run cli decode-ax-archive tmp/accessibility.plist
```

The optional `.plist` destination saves the original archive bytes with mode 0600 and returns `archivePath`/`archiveBytes` instead of base64. The parent directory must exist. Existing files and symlinks are refused using exclusive creation; write failure removes the newly created partial file. Destination validation occurs before the device query. Exclusive creation also prevents replacement if another process creates the destination during capture. Without a destination, the existing base64 result remains available. MCP `get_accessibility_archive` accepts the same optional `path`.

`decode-ax-archive` and MCP `decode_accessibility_archive` inspect a local file in process through Foundation, without connecting to a device or launching a helper. This is data-only property-list decoding: it does not instantiate archived Objective-C classes. Known Foundation collection/string/data wrappers are resolved; unknown classes retain `className` and `fields`. Numeric dictionary keys become JSON keys. Nested archive data is decoded, while opaque non-archive data is represented by byte count. Attributed strings and NSValue fields remain structural objects rather than inferred UI properties. This inspector is available even while live direct accessibility capture is unfinished.

Limits are 16 MiB of input per archive, four archives total, recursion depth 64, 100,000 expanded values, 100,000 archive-table entries, and 32 MiB of expanded strings/keys/class names/opaque data. Binary plist offset tables are bounded to one million raw plist objects; raw UID widths/values are checked before Foundation parsing to prevent wider values aliasing a narrowed reference. Cycles, dangling references, invalid classes, mismatched dictionary arrays, duplicate decoded keys, and non-finite numbers are rejected. These limits bound custom validation/expansion; they are not an audit of Foundation's plist parser allocations. Output retains `parsedHierarchy: false`. It does not identify stable elements, assign meanings to numeric accessibility attributes, or supply selector taps. The internal typed decoder and read-response matcher are tracked separately in the [direct migration](DIRECT-ACCESSIBILITY.md#remaining-integration); their implementation does not restore live capture.

## Verification and remaining work

Synthetic in-memory DTX tests cover framing failures, fragments, callback filtering, acknowledgements, and correlated cleanup. A live iPhone 13 mini USB query now completed callback capture and the correlated disable exchange. A subsequent Swift CLI query saved a 7,555-byte archive under ignored `tmp/`; offline decoding found two nested archives, an `AXPTranslatorResponse`, and 27 `treeDump` responses. These are response records, not a count of UI elements. The payload includes numeric attributes, translation-object identities, and Foundation wrappers. No private device data is committed as a fixture.

The raw callback probe still does not interpret initial-versus-update dump semantics. The separate active requests above now supply a normalized native hierarchy, display-centre application selection, and fresh selector presses with scoped physical verification. Generation handling, stable actionable references, broader app/overlay coverage, and other AX actions remain unfinished. A different device state may produce unsupported data. These paths do not complete physical accessibility parity.
