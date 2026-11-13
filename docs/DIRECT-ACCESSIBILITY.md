# Direct physical accessibility migration

Physical accessibility remains unavailable in the current product runtime: the former idevice executable is disabled. The replacement must operate in `appledevicescmd` against Apple interfaces, without launching an intermediary. This page tracks implementation separately from live device evidence.

## DTX framing

`AccessibilityDTX` implements bounded framing for `com.apple.accessibility.axAuditDaemon.remoteAXService`. The service carries DTX rather than the RemoteXPC HID dictionary protocol. It preserves keyed archive bytes without instantiating device-specified classes; semantic archive decoding and normalized trees are separate unfinished layers.

The codec limits a combined body to 16 MiB and a message to 64 fragments. A fragmented message's initial header declares combined size without carrying a body. Following fragments must match identifiers, conversations, channel, reply expectation and count, and their sizes must sum exactly. Header bounds precede body reads. Payload and auxiliary lengths are validated; unknown/compressed payload kinds fail explicitly. A callback invocation cannot be mistaken for an acknowledgement solely because its identifiers match.

Outgoing invocations archive project-owned selectors and arguments with Foundation secure coding. Replies preserve the identifier, advance the conversation and apply channel direction rules; overflow and unrepresentable channel negation fail. The parser leaves received archive contents opaque. Handling a DTX acknowledgement does not establish an accessibility semantic response or subscription cleanup.

Protocol facts were cross-checked against the existing [accessibility notes](ACCESSIBILITY-PROTOCOL.md), the pinned MIT [ipb protocol reference](https://github.com/ipbtools/ipb/blob/8c227a10710dad479852aa0203de729fed57471b/docs/protocol.md), and pinned AXe source reviewed in [AXE-PHYSICAL-REVIEW.md](AXE-PHYSICAL-REVIEW.md). This is project-owned interoperability code; neither reference executable is a runtime dependency. Installed Apple CoreDevice exports separately confirm service-name and feature-identifier socket methods and optional input fields. They do not establish that a particular service connection will succeed.

## Remaining integration

Two project-owned socket-opening paths now exist behind the bridge, with an opt-in read-only integration probe. Neither has opened the AX endpoint successfully on the selected phone. Product CLI/MCP accessibility routing remains disabled. Serving version negotiation, enabling/disabling accessibility, request/callback routing, bounded data-only archive decoding, fresh application snapshots and selector guards still need direct implementation and hardware verification. Historical results below other documentation headings are acceptance targets, not verification of this codec or transport.

## Socket-opening investigation

`ADCOpenAccessibilitySocket` asks Apple's CoreDevice service for the exact AX service name, without a feature identifier or RemoteXPC upgrade. Its owned descriptor and XPC control connection have one explicit close API; socket setup has a 15-second reply deadline. Framework initialization is shared with the existing HID path.

`ADCOpenRSDAccessibilitySocket` is a separate, explicitly selected experiment using installed RemoteServiceDiscovery APIs. Signatures and selection keys were checked against the installed Apple `remotectl` caller using `nm`/`otool`. It selects a remote UUID of type `coredevice-device`, requires connected state, verifies its `UniqueDeviceID` against the requested hardware UDID, then looks up the exact AX service and refuses endpoints requiring encrypted raw data. It does not guess service ports, connect another device, retry or fall back automatically. These synchronous private API calls do not yet have a product-level cancellation/deadline guarantee.

The close API closes the owned descriptor and releases retained service/device objects or cancels the owned CoreDevice control connection. Descriptors are marked close-on-exec. Identity errors clear the output owner and fail before framework access. A socket-open receipt would only prove opening, not DTX negotiation or a tree.

```sh
# CoreDevice service-name path:
mise run test:ax-socket <hardware-UDID>
# Separate RSD path; use a fresh Apple remote inventory UUID for the same device:
mise run test:ax-socket <hardware-UDID> --remote-uuid <remote-UUID>
```

Neither probe enables accessibility, sends input, reads a tree or changes device settings. Both are tests of code linked into this project, not shipped helper executables.

On 2026-11-13 the CoreDevice path failed with `com.apple.dt.CoreDeviceError 4000` before subscription. The RSD path initially found no device when filtering by `AvailableService`; separating identity lookup from service lookup found the connected phone and passed the hardware check, but `remote_device_copy_service` returned no AX endpoint. Apple `remotectl show` separately advertised that exact service, and `get-property` reported `UsesRemoteXPC: true`, `EncryptSocketData: false`. The discrepancy is unresolved; advertising and property reads do not establish a working raw connection.

The fresh Apple inventory reports the selected iPhone 13 mini on iOS 27.2.1 (24B156), differing from the earlier 27.2 (24B119) input records. Its hardware UDID was checked; no other listed Apple device was used. Host macOS remains 27.2.1 (26B131), Xcode 27.2 (27B52), CoreDevice 651.32, Swift 6.4.2. Raw device inventory and disassembly remain under ignored `tmp/`.

The next transport investigation is the ordinary paired RSD/TCP route described by the source references, with fresh directory identity checks and bounded I/O. These socket errors are not proof that the phone refuses AX or that Developer Mode/UI Automation is disabled. No additional phone setting change is justified by this evidence.

## Local validation

On 2026-11-13, `mise run test` passed 160 Swift test functions with zero errors/warnings on macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2. Seven new tests cover an independent byte fixture, outgoing subscription archives, fragment assembly/correlation, malformed header/payload/argument bounds, reply direction/overflow and opaque unknown archive class names. No phone request was sent by these tests. A successful build or codec test is not a live tree result.

After adding socket ownership/identity checks, `mise run test` passed 161 test functions with zero errors/warnings; all 24 mise tasks validate. The opt-in live socket test failed on each path as recorded above. Its failure is retained as evidence, not converted to a passing capability result. Physical accessibility remains unavailable.

The shared CoreDevice initialization was regression-checked through real MCP Home input: the before image showed Settings, the immediate after image showed its dismissal animation, and a subsequent Apple screenshot showed settled Home. The MCP handshake, receipt checks and EOF shutdown passed. This verifies the existing Home path after the initialization refactor, not accessibility connectivity.

## Reconnection retry and Apple relay comparison

After the interrupted lookup, the original log process was no longer running. A fresh CoreDevice read confirmed the same physical hardware, wired connection, enabled Developer Mode and a changed active tunnel address. The one-day Apple tunnel log query completed with no matching entries, and `netstat -anv -p tcp` returned no rows. These sources did not provide a current RSD port; no old address/port was reused or guessed. Apple's remote inventory and state dump continued to list the AX service on the selected phone.

The direct RSD probe now follows Apple's device-type parser/canonical description and checks the returned type, in addition to hardware identity. It reads the service-name inventory before looking up the endpoint, matching the installed remotectl show caller. On this retry the selected `coredevice-device` object was connected and passed the hardware check, but its direct service inventory contained zero entries. The diagnostic distinguishes absent inventory from an advertised endpoint that fails lookup. The reason this differs from the Apple tool's inventory remains unknown.

`mise run test:ax-relay <hardware-UDID> <remote-UUID>` provides a separate bounded comparison through Apple's installed `/usr/libexec/remotectl netcat`. It validates fresh CoreDevice readiness and the remote UUID's `UniqueDeviceID`, then attempts only a DTX capabilities exchange. It sends no `clientNeedsAccessibility:` subscription or UI input. Swift Subprocess owns input/output, termination and reaping within the scoped closure, with an eight-second probe deadline, 64 KiB output limit and bounded diagnostics. Partial DTX prefixes wait for the complete frame; malformed headers still fail immediately. A captured frame would be transport evidence, not a normalized tree.

The Apple relay retry exited 69 with `Unable to connect` to the exact AX service, without returning a DTX frame. Thus the observed connection failure is not limited to our CoreDevice/RSD wrapper. Its cause is not established, and this is not evidence that UI Automation needs toggling. The relay is an opt-in diagnostic, not a CLI/MCP fallback. The execution policy adds only the exact Apple remotectl path outside ordinary system bin directories; other libexec and third-party controllers stay blocked.

Local validation after the retry passed 163 test functions with zero errors/warnings; all 25 mise tasks validate. The two added checks exercise every partial DTX prefix, concatenated-frame consumption, malformed-header rejection and the exact Apple-tool policy exception. The live socket and relay failures remain failures. Physical accessibility remains unavailable, and ordinary paired transport/semantic decoding still need implementation and verification.
