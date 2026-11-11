# Experimental remote accessibility observation

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

`decode-ax-archive` and MCP `decode_accessibility_archive` inspect a local file through the optional bridge, without connecting to a device. This is data-only property-list decoding: it does not instantiate archived Objective-C classes. Known Foundation collection/string/data wrappers are resolved; unknown classes retain `className` and `fields`. Numeric dictionary keys become JSON keys. Nested archive data is decoded, while opaque non-archive data is represented by byte count. Attributed strings and NSValue fields remain structural objects rather than inferred UI properties.

Limits are 16 MiB of input per archive, four archives total, recursion depth 64, 100,000 expanded values, and 32 MiB of expanded strings/keys/class names. Cycles, dangling references, invalid classes, mismatched dictionary arrays, duplicate decoded keys, and non-finite numbers are rejected. These limits bound the custom expansion stage; they are not an audit of the upstream plist parser's allocations. Output retains `parsedHierarchy: false`. It does not identify stable elements, assign meanings to numeric accessibility attributes, or supply selector taps.

## Verification and remaining work

Synthetic in-memory DTX tests cover framing failures, fragments, callback filtering, acknowledgements, and correlated cleanup. A live iPhone 13 mini USB query now completed callback capture and the correlated disable exchange. A subsequent Swift CLI query saved a 7,555-byte archive under ignored `tmp/`; offline decoding found two nested archives, an `AXPTranslatorResponse`, and 27 `treeDump` responses. These are response records, not a count of UI elements. The payload includes numeric attributes, translation-object identities, and Foundation wrappers. No private device data is committed as a fixture.

Next evidence needed: independently verified numeric attribute meanings, initial-versus-update dump semantics, relationships, and comparison with a known visible screen. Generation handling, stable reference lifetime, physical selectors, and normalized hierarchy output remain unimplemented. A different device state may produce a non-tree event or an unsupported archive shape. The current probe and structural decoder do not complete physical accessibility parity.
