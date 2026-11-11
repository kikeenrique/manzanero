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

## Verification and remaining work

Synthetic in-memory DTX tests cover framing failures, fragments, callback filtering, acknowledgements, and correlated cleanup. No captured device fixture or live snapshot has validated this implementation. A real callback may require additional startup messages, contain a non-tree event, or use an unsupported archive shape.

Next evidence needed: a device-authorized session, a captured callback, its request/result schema, and verified disable behavior. Only then can a parsed hierarchy, generation handling, and stable reference lifetime be claimed. The current probe does not complete physical accessibility parity.
