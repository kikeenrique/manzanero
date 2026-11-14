# Accessibility protocol reference

This page records the AXP/DTX contracts used by the native physical backend and their provenance. For normal commands and selector behavior, use [native accessibility](DIRECT-ACCESSIBILITY.md).

The exact service is `com.apple.accessibility.axAuditDaemon.remoteAXService`. The older `remoteserver.shim.remote` audit service is not an interchangeable full-tree endpoint. Advertising a service does not establish working authorization or transport.

## Session and request flow

The host answers `hostAPIVersion` with 7 and requires device API version 26. Those are protocol versions, not the iOS release number.

After attempting `clientNeedsAccessibility: true`, requests are keyed archives passed to `processDataFromHost:`. Semantic responses arrive separately through `processDataFromRemoteDevice:`; DTX call acknowledgements are not semantic results.

| Request | Type/action | Purpose |
| --- | --- | --- |
| Application root | Type 1, positive PID | Get the application's translation token |
| Descendant snapshot | Type 2, attribute 52 | Read native snapshot data |
| Live attributes | Type 5, IDs 21/25/27/32 | Frame, identifier, enabled and visible state |
| Point selection | Type 6 | Select a native identity/process at a logical point |
| Press | Type 7, action 5 | One native press |
| Scroll-to-visible | Type 7, action 11 | One native scroll request |

Snapshot options request attributes `[2001,2002,2003,2004,5019,2006,2025,5003,5004,3003]`, parent-to-child traversal, depth 48 and child/array caps 512. Host normalization separately caps the returned tree at 512 nodes/depth 32.

Outgoing token encoding preserves unsigned 64-bit object identity, bounded opaque data and Apple's wire spelling `didPopuldateAppInfo`. Tokens are not exposed as public reusable handles.

## Response matching

Only one semantic request is outstanding per session. The reader first checks bounded response metadata; unrelated request types are ignored without expanding their results. This matters because unrelated type-11 notifications observed during point selection contained non-finite values.

Matching replies still require valid archives, finite relevant values, expected request/attribute/status and appropriate target identity. Application roots must retain positive PID/object identity and application flag. Snapshots are followed by another application lookup.

Type-5 replies can have nil associated translation, and type-7 replies have nil translation. There is no demonstrated sequence/target correlator for those nil results. A supplied translation must match; the single-request guard does not eliminate every delayed same-type reply risk.

A native Boolean/integer 0/1 action result is different from UI effect. Selector guards and postconditions are described in [DIRECT-ACCESSIBILITY.md](DIRECT-ACCESSIBILITY.md).

## DTX framing

`AccessibilityDTX` checks message headers before body reads, exact payload/auxiliary lengths, fragment correlation and supported kinds.

- Maximum body: 16 MiB; maximum fragments: 64.
- A fragmented initial header declares combined size without carrying the body.
- Subsequent fragments must agree on identifiers, conversation, channel, reply expectation and count; sizes must sum exactly.
- Payload kinds: acknowledgement 0, invocation 2, archived object 3, error 4. Raw DATA 1 and unsupported/compressed kinds fail.
- Auxiliary dictionaries use low-byte tag `0xf0`. Upper header metadata is opaque; observed values included `0x3f0` and `0xb9f0`. It is never an allocation size.

An earlier type mapping confused object/error values; literal wire fixtures now check them independently. Reply correlation alone does not make an error reply successful.

## Data-only archive decoding

Incoming archives are interpreted as data, never instantiated as device-supplied Objective-C classes. The typed internal representation preserves opaque tokens for fresh requests. The public inspector redacts opaque data to byte counts and remains structural.

| Bound | Limit |
| --- | --- |
| Input per archive | 16 MiB |
| Nested archives | Four total |
| Expanded values / archive table | 100000 each |
| Expanded content | 32 MiB |
| Public wrapper depth | 64 |
| Internal protocol wrapper depth | 512 |
| Raw binary-plist object count | One million |

Validation rejects cycles, dangling references, invalid classes, mismatched dictionary arrays, duplicate decoded keys, non-finite numbers and invalid UID widths/values. Traversal uses a bounded explicit work stack rather than unbounded Swift recursion. These custom limits do not audit Foundation's parser allocations.

Snapshot normalization validates declared children, native rectangles and scalar metadata. Repeated identities on distinct paths remain occurrences; foreign-process references are allowed only as explicit leaf references, not foreign subtrees. Geometry stays in logical points; there is no inferred XCUIElementType or generic hittability mapping.

## Saving and inspecting a callback

Current offline inspection is available without a device or helper:

```sh
appledevicescmd decode-ax-archive tmp/accessibility.plist
```

MCP `decode_accessibility_archive` takes the same local `path`. Known Foundation wrappers are expanded; unknown objects retain `className`/`fields`. The result retains `parsedHierarchy: false`; it does not turn an arbitrary callback into an actionable UI tree.

The old live `ax-snapshot` capture and MCP `get_accessibility_archive` route depend on the disabled idevice executable. Historical capture saved a new mode-0600 file or returned base64, with `parsedHierarchy: false`; it required correlated disable acknowledgement. That is not a currently supported capture command.

## Cleanup and uncertainty

The native session attempts `clientNeedsAccessibility: false` after attempted subscription, including ambiguous enable. It uses bounded independent cleanup and reports acknowledged/unconfirmed outcomes separately from useful result data. Closing a socket or receiving an acknowledgement does not independently prove device-side subscription teardown.

See [native session limits](DIRECT-ACCESSIBILITY.md#ownership-deadlines-and-failures) and [verification](VERIFICATION.md).

## Provenance

The request/response research follows pinned MIT [ipb protocol notes](https://github.com/ipbtools/ipb/blob/8c227a10710dad479852aa0203de729fed57471b/docs/protocol.md), earlier project-owned Rust AX code, retained phone callbacks and installed Apple interfaces. The [ipb notice](../ThirdParty/ipb-LICENSE.txt) is retained. The earlier Rust path used pinned [idevice DTX](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/dvt/message.rs); its current executable route is blocked.

Static inspection of [private framework reference removed] 0.9.0/build 90 also identified the newer AX service and DTX worker selectors:

| Observation | Historical location | Scope |
| --- | --- | --- |
| AX service connection | `start_accessibility` closure `0x342f4c` | Compiled connection path, no live authorization result |
| DTX worker | `sub_37e700` | Framing/call graph evidence |
| `clientNeedsAccessibility:` | String `0x73ca0f`, call `0x37e8ec` | Selector plus Boolean-shaped argument evidence |
| `processDataFromRemoteDevice:` | Around `0x37f0a0–0x37f104` | Callback handled by the worker |
| Archive processing | `parse_dump` at `0x3e6ed8` | Archive parser presence, not an independently established complete tree schema |

These are interoperability observations, not a live trace or copied implementation claim. No proprietary binary is linked or packaged. [Original investigation](ANALYSIS.md) retains the inspected artifact and limits; the [public-readiness review](PUBLIC-READINESS.md) calls out the publication/provenance decision.
