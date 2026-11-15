# Native physical transport

Physical AX uses an owned Apple tunnel assertion, a freshly discovered RSD directory and Apple's Network/RemoteXPC APIs, then raw TCP/DTX to the validated AX service. This is the only route; the older socket experiments listed below have been removed (git history keeps them).

## Current Network directory and native AX route

1. Resolve fresh physical hardware/CoreDevice identity and connected tunnel address.
2. Acquire/retain a native Apple pairing-daemon tunnel assertion for the selected hardware.
3. Discover the current directory port for that exact tunnel address.
4. Create an unstarted Network connection configured for Apple's RemoteXPC directory bootstrap.
5. Verify peer hardware identity and the exact advertised AX service properties.
6. Open the AX endpoint and retain the assertion/directory until AX cleanup.

CLI/MCP explicit-PID and foreground Settings trees passed on iPhone 13 mini. That scoped result does not establish broad Wi-Fi, host, pairing-state or OS-version compatibility.

No custom HTTP/2 encoder, credential extraction, private entitlement or third-party device executable is used by the product route.

## Read-only RSD port discovery

`RSDPortDiscovery` requests one numeric TCP sample from Apple's `nettop`, limited to `remoted`, with interface/state columns, ten-second process timeout and a 1 MiB output cap.

It requires the expected CSV shape, an established IPv6 socket at the exact fresh tunnel address and a live PID whose executable is `/usr/libexec/remoted` according to `proc_pidpath`. Duplicate observations of one port are acceptable; zero or multiple distinct ports fail. Link-local scope must match.

This discovers a candidate, not a trusted service endpoint. The later directory handshake must verify hardware and service identity. No prefix match, old port reuse or guessed default is used.

## Native directory handshake

Installed Apple caller inspection distinguishes directory bootstrap from service-connection flags. The current route uses `xpc_remote_connection_setup_nw_parameters` with client mode 2, an unstarted `nw_connection_t`, and `xpc_remote_connection_get_failsafe_version_flags`.

The installed getter returned `0x0100000000000000`; the host RSD capability advertisement separately uses `0x0100000000000006`, protocol 7 and the local UUID from Apple `remotectl dumpstate`. These values are version-sensitive implementation observations, not public API guarantees.

Lower TCP parameters disable TLS using `NW_PARAMETERS_DISABLE_PROTOCOL`, matching the inspected lower-transport helper. This is not a certificate-verification override. A separate RemoteXPC TLS lifecycle and all interface-binding details have not been reproduced.

The directory must identify the selected hardware and exact `com.apple.accessibility.axAuditDaemon.remoteAXService`, with a positive decimal port, `UsesRemoteXPC: true` and explicit `EncryptSocketData: false`. Inventories above 4096 services, malformed flags and identity mismatches are refused. Apple's wire decoder still has allocations outside the project's post-decode limits.

## Assertion and socket ownership

`NativeTunnelAssertion` browses the current user's Apple pairing daemon, selects the exact UDID and requests an assertion on that device endpoint. It does not initiate pairing, target another user's daemon or export the opaque assertion UUID.

Browse/acquisition share a twelve-second budget. Returned IPv6 must equal the fresh selected tunnel address. Explicit close requests release, waits up to two seconds for acknowledgement, then cancels owned connections. A late acquisition reply after timeout/cancellation can leave an unknown remote result.

The Network handshake waits up to eight seconds with cancellation polling; the AX TCP connection and session have their own bounds. Close cancels RemoteXPC/Network, closes the AX descriptor and reports assertion release separately. These are owned close/release actions, not independent proof of remote teardown. Synchronous private calls and forced exit retain uncertainty.

## Diagnostic tasks

```sh
mise run test:rsd-port <hardware-UDID>
mise run test:native-tunnel <hardware-UDID>
mise run test:rsd-tree <hardware-UDID> <positive-PID> --native-tunnel
mise run test:rsd-wire
```

The port task reads inventory only. Assertion-only testing acquires/releases without AX. The tree task uses the product's Network directory and records DTX frame structure privately under `tmp/`. The local wire task uses an owned synthetic loopback peer and deliberately incomplete handshake; its expected directory failure is not a physical-device result.

## Earlier failures and why they matter

The code for these attempts (CoreDevice named AX socket, RemoteServiceDiscovery lookup/browse and transport-profile reads, connected-FD directory bootstrap, `remotectl netcat` relay) is gone; the findings remain as history.

- CoreDevice named AX sockets failed with error 4000, later including POSIX 83 (`EDEVERR`). The category did not establish a missing setting, credential or entitlement.
- Direct RSD lookup/browse saw zero services while Apple's tool advertised AX. Apple `remotectl netcat` also failed before DTX. Advertising or service metadata was insufficient.
- An early directory response passed once, but later connected-FD attempts returned `Connection invalid`. Nearby generic TLS-renegotiation logs did not establish a causal device-specific explanation.
- Holding a valid tunnel assertion and copying service mode-4/version flags did not repair those attempts. Service metadata is not directory bootstrap.
- The later unstarted-Network/mode-2 route succeeded. Its success does not retroactively make the earlier modes working fallbacks.

No TLS bypass, daemon suspension, private entitlement, pairing change or automatic replay was added to force those probes through.

## References

The native tunnel/directory work was informed by pinned [pymobiledevice3 native-tunnel](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/native_tunnel.py) and [RemoteXPC](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/remotexpc.py) references, without adding that runtime or copying credentials/source.

The retired idevice path used independent pairing records and TLS-PSK software tunnels. Live pairing/reconnection remained unverified, and that route has been removed. See [dependencies](dependencies.md), [AX contracts](accessibility-protocol.md) and [verification](verification.md).
