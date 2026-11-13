# Physical transport investigation

## Current Network directory and native AX route

As of 2026-11-13, shared CLI/MCP explicit-PID trees use a native Apple tunnel assertion, a freshly discovered exact-address directory port, an unstarted Network connection and Apple's RemoteXPC directory handshake. They then connect raw DTX to the identity-validated AX port. The diagnostic, CLI and real MCP each returned 106 Settings nodes on the selected iPhone 13 mini. Earlier failed transports below are retained as investigation history; they do not describe current product routing.

Installed Apple `RSDRemoteCoreDeviceDevice.needsConnect` distinguishes the directory bootstrap from service transport flags. The implementation calls `xpc_remote_connection_setup_nw_parameters` with client mode 2, creates an unstarted `nw_connection_t`, and supplies `xpc_remote_connection_get_failsafe_version_flags()` to `xpc_remote_connection_create_with_nw_connection`. The installed getter returns `0x0100000000000000`; the separately serialized host RSD capability advertisement remains `0x0100000000000006`, protocol 7, with the local UUID from Apple `remotectl dumpstate`. The connected-FD diagnostic also uses the failsafe getter but still failed on the phone; it is not an automatic fallback.

Network creates the lower TCP parameters with `NW_PARAMETERS_DISABLE_PROTOCOL` for TLS, matching the inspected Apple lower-transport helper; certificate verification is not overridden. A separate RemoteXPC TLS lifecycle and all Apple's interface-binding parameters have not been reproduced. This scoped success does not establish compatibility across hosts, pairing states, transports or OS versions. No custom HTTP/2 encoder, credential extraction, private entitlement or third-party device executable was added. Network.framework is linked as a built-in Apple framework.

The Network connection/handshake has an eight-second wait with cancellation polling. The validated AX socket has a separate bounded TCP connect; session read/cleanup limits remain in [direct accessibility](DIRECT-ACCESSIBILITY.md). Owners retain the assertion and directory through AX cleanup. Close cancels RemoteXPC and Network, closes the AX descriptor, and records assertion release independently. Cancellation requests and protocol acknowledgements do not independently prove remote teardown. Late assertion acquisition and forced process exits retain cleanup uncertainty.

```sh
mise run cli physical <hardware-UDID> tree <positive-PID>
mise run test:rsd-tree <hardware-UDID> <positive-PID> --native-tunnel --network
# Owned loopback peer only; expected incomplete directory failure:
mise run test:rsd-wire --network
```

The low-byte DTX auxiliary tag correction allowed callbacks past framing validation. The successful tree retained the existing semantic response matching, bounded data-only archive decoding, root recheck and snapshot normalization. Explicit PID does not verify foreground/display selection. See [verification](VERIFICATION.md) for exact outcomes and private artifact locations.

## Historical investigation

The following sections record earlier configurations and results in order. References to unavailable trees and proposed next steps belong to those checkpoints; use the current route above for present availability.

## 2026-11-11 — Apple Wi-Fi tunnel versus an independent pairing

Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), physical iPhone running iOS 27.2.1. Read-only `devicectl device info details` succeeded outside the sandbox. It reported manual pairing, local-network transport, a connected TCP tunnel, and Developer Mode enabled. Local outputs are under ignored `tmp/`; device identifiers, addresses, and serial numbers are omitted here.

Installed `/usr/libexec/remotectl help` documents `show`, `get-property`, and `netcat`. `show` confirmed the connected phone advertises Universal HID, Indigo HID, display service, and remote accessibility services. Advertised service presence alone does not prove their operations are authorized or working.

Two experimental bridge probes used `remotectl netcat`: one to `com.apple.internal.devicecompute.CoreDeviceProxy`, the other directly to `com.apple.coredevice.hid.universalhidservice`. Both were refused before protocol initialization; the latter ended with HTTP/2 connection-closed. The failed automatic fallback and native netcat implementation were removed from the production bridge. No physical input was sent by these probes.

For comparison, the open-source [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) checkout at `03d788d23105c1754c27cc4e6ddc1d7e23835b32` was inspected in `tmp/pymobiledevice3`. Its `remote/native_tunnel.py`, `remote/remotexpc.py`, and `docs/guides/network-stacks.md` describe an opt-in method that acquires an Apple tunnel assertion and locates the active RSD port. They also describe RSD connections competing with remoted on a shared source address, and device service reattachment when the peer identity changes. These are upstream research findings, not independently reproduced behavior here. No pymobiledevice3 source is copied or linked by appledevicescmd.

The implemented Wi-Fi path instead uses idevice's own `RemotePairingClient`, a tool-specific record, a newly requested TCP listener, native TLS-PSK, and a separate software tunnel. Ordinary device commands only verify an existing pairing; initial pairing is explicit and requires device approval and PIN entry. This design is intended to avoid adding a competing RSD client to Apple's active tunnel; successful tunnel isolation has not been demonstrated live. Live behavior is still unverified.

See [backend setup](DEPENDENCIES.md) for the commands and [verification records](VERIFICATION.md) for what was actually tested.

## Read-only RSD port discovery

`RSDPortDiscovery` can obtain a current candidate directory port through Apple's `/usr/bin/nettop`, without a non-Apple executable or custom socket-table reader. It requests one numeric TCP sample limited to `remoted`, with only interface/state columns, a ten-second process deadline and a one-MiB output cap. The installed tool's help confirms these flags. The approach was informed by the pinned [pymobiledevice3 native tunnel reference](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/native_tunnel.py); no source from it was copied or added as a dependency.

The parser requires the expected CSV columns, an established IPv6 socket under a `remoted.<PID>` process row, and the exact current tunnel address. It verifies that PID's live executable path is `/usr/libexec/remoted` through Apple's `proc_pidpath`. It does not match an IPv6 prefix or guess a default port. Duplicate observations of one port are accepted; zero or multiple distinct candidates are refused. Scoped link-local addresses require a matching explicit scope. Invalid, malformed, oversized and ambiguous inventory is rejected.

```sh
mise run test:rsd-port <hardware-UDID>
```

The explicit integration check obtains fresh CoreDevice details for the hardware UDID, requires physical/connected/paired state, discovers a candidate, then requires the tunnel address to remain unchanged in another details query. Metadata is saved beneath ignored `tmp/rsd-port-*/`. This check reads host socket inventory and device details only; it does not create a service connection, acquire a tunnel assertion, enable AX, send UI input or verify a peer handshake. PID/port ownership may change after discovery, so a future connection must still verify the directory's advertised hardware identity and exact service properties. This is an investigation primitive, not a CLI/MCP connection fallback.

## Native directory handshake

`mise run test:rsd-directory <hardware-UDID>` explicitly connects once to the freshly discovered directory port through Apple's in-process RemoteXPC interfaces. TCP setup and the handshake each have an eight-second deadline with cancellation checks. The connection consumes its stream descriptor on all paths, retains the native connection until explicit close/deinitialization, and requests cancellation on close. It uses the recorded Apple RemoteXPC version flags `0x0100000000000006` with client connection mode zero; no alternate flags, reconnect loop or runtime fallback is attempted.

The handshake must identify the exact hardware UDID. Only the exact `com.apple.accessibility.axAuditDaemon.remoteAXService` entry is selected, with a positive decimal port, `UsesRemoteXPC: true` and explicit `EncryptSocketData: false`. Wrong identities, unsupported flags/shapes, malformed ports and inventories above 4096 services are refused. The native framework performs wire decoding; these post-decode bounds do not bound or audit its internal allocations. The owned handler caps unrelated messages at 32 while awaiting the handshake. Directory metadata remains private under `tmp/rsd-directory-*/`.

The 2026-11-13 selected-iPhone check verified this handshake and obtained the AX port. It did not open AX, subscribe, read a tree or send input. Cancellation requests are not independent proof of remote teardown, and disconnects after validation can invalidate the port. The existing product tree route still uses its original CoreDevice socket opener; direct RSD/AX integration remains separate. Potential competition with Apple's existing RSD client remains a reference-reported limitation, not a general reliability claim.

Subsequent checks did **not** reproduce the successful directory response: two tree-probe setups and a directory-only control failed before opening AX. Native RemoteXPC reported `Connection invalid`; nearby remoted logs contained `Device must renegotiate TLS`, without proving which device or causal sequence those generic log messages describe. The initial successful response establishes received/validated peer metadata, not a durable or repeatable session.

The probe now explicitly sends the RSD host handshake through Apple's XPC serializer: protocol version 7, the recorded RemoteXPC version flags, the local UUID reported in the `Local device` section of Apple `remotectl dumpstate`, empty services and the reference's properties. The local identity parser never falls back to a remote device UUID. This follows the pinned [RemoteXPC reference](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/remotexpc.py); no source or credentials were copied. The next explicit tree attempt still failed in RSD with `Connection invalid`. Therefore the explicit host message is implemented but has no successful live exchange yet. No retry loop, TLS bypass, daemon suspension, private entitlement or pairing change was added. Native tunnel-assertion ownership and session/peer identity behavior need further investigation.

`mise run test:rsd-tree <hardware-UDID> <positive-PID>` is an opt-in diagnostic for the next stage. If directory setup succeeds, it opens only the validated AX port as raw DTX and retains the directory until the AX socket closes after session cleanup. It refuses a closed/failed directory or a second service owner. The existing application/snapshot/application identity checks and bounded normalization are reused. All live attempts so far stopped before that stage; this is not current product tree availability or a foreground-app guarantee.

## Native Apple tunnel assertion

```sh
# Acquisition and explicit release only; no RSD or AX connection:
mise run test:native-tunnel <hardware-UDID>
# Separate explicit comparison, retaining the assertion through AX cleanup:
mise run test:rsd-tree <hardware-UDID> <positive-PID> --native-tunnel
```

`NativeTunnelAssertion` requires fresh details identifying the exact paired/connected physical hardware. The project-owned bridge uses ordinary libxpc to browse the current user's Apple pairing daemon, filters the exact UDID, and requests `RemotePairing.CreateAssertionCommand` on its supplied device endpoint. It never sends an initiate-pairing command, retargets another user's daemon or prints/exports the opaque assertion UUID. These request shapes follow the pinned [native tunnel reference](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/native_tunnel.py); no third-party source or dependency was added.

Browse/acquisition share a 12-second deadline with cancellation polling. The selected address must be bounded, valid unicast IPv6 and equal to the fresh selected-device tunnel address; mismatches are released and refused. The owner retains browse/device connections and the opaque token. Explicit close sends `RemotePairing.ReleaseAssertionRequest`, waits independently up to two seconds for its response, then cancels the owned connections. Close is idempotent in Swift. A release response is a protocol acknowledgement, not independent verification of device-side teardown. Acquisition timeout/cancellation can leave an unknown remote result if its reply arrives late; diagnostics preserve that uncertainty instead of claiming successful remote cleanup.

On 2026-11-13, the selected-phone assertion-only check acquired the assertion and received a release acknowledgement. A separate tree probe acquired and held an assertion, still failed at the RSD handshake with native `Connection invalid`, then received its release acknowledgement. It opened no AX socket and read no tree. Holding the assertion therefore did not repair that attempt; native RemoteXPC/RSD compatibility and session behavior remain unresolved. The diagnostic now saves both success and failure stages/outcomes beneath `tmp/rsd-tree-*/`, preserving the original test failure.

## Local native-wire and service-profile comparison

`mise run test:rsd-wire [--mode 0|4]` observes Apple's native client against an owned IPv6 loopback peer. It uses synthetic hardware/host UUIDs, caps the prefix at 64 KiB and capture at three seconds, sends only empty HTTP/2 SETTINGS from the peer, then shuts down and drains the owned client task. It does not query a physical device or intercept another process's traffic. The peer supplies no RSD metadata and is deliberately incomplete; the resulting directory error is expected and is not a phone connectivity result. Raw prefix/frame metadata remain beneath ignored `tmp/native-rsd-wire-*/`.

Both observed modes emitted a valid HTTP/2 preface, SETTINGS, WINDOW_UPDATE, stream-1/3 headers and RemoteXPC initialization data. In these prefixes the stream-3 initialization preceded the stream-1 termination marker; the source reference orders those two data frames oppositely. SETTINGS acknowledgement placement varied between captures. These observations do not prove an ordering defect, a complete handshake or the cause of the live failure. No production frame reordering or custom wire encoder was added.

`mise run test:rsd-profile <hardware-UDID> <remote-UUID>` reads Apple's **service transport metadata** after checking connected state, device type and hardware identity. A second one-shot lookup by exact hardware UDID must agree with the UUID lookup. It reads version/mode flags and the native TLS-enabled boolean, without copying TLS identities, reading credentials or opening a service. The selected phone reported version flags `0x0100000000000006`, mode `4` and TLS enabled `false`. Those are service-profile values, not proof of the directory-control bootstrap or its TLS requirements. Unknown outputs and unsupported identity shapes remain failures.

An explicit held-assertion tree comparison using the service-profile values still failed before AX with `Connection invalid`; release was acknowledged. The directory probe therefore retains its earlier diagnostic baseline rather than treating the service profile as a verified directory configuration. Installed Apple caller inspection subsequently showed a separate control bootstrap: `RSDRemoteCoreDeviceDevice.needsConnect` uses `xpc_remote_connection_get_failsafe_version_flags` and client mode `2` for an unstarted Network connection; the installed getter returns `0x0100000000000000`. A connected-FD caller has different setup constraints. Matching that control bootstrap, including its Network/TLS lifecycle, is the next investigation; the service-profile comparison is not a repair.
