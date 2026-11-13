# Physical transport investigation

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
