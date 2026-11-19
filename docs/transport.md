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

## The cost of this route

The tool's own directory connection is a second one from the same Mac, and the device resets the one `remoted` holds when it arrives. `remoted` reconnects, and now and then that reconnect never completes: every `devicectl` query then times out until the tunnel is replaced, while input still arrives. It was traced on an Apple TV on 2026-11-18 ([guide](other-families.md#a-physical-apple-tv)); `remoted` logs the same interruptions for the phone. Avoiding it means reaching the AX service without a second directory connection. Both ways through Apple's daemons were looked at again that night and both are closed as they stand: `remoted` refuses this process the lookup ("Client lacks privilege"), and `CoreDeviceService` is granted the lookup but its socket request fails for every service that is not CoreDevice's own (below). They are closed for good, not for want of the right request: `remoted` lets a client connect only with the entitlement the device names for the service, and for the AX service that is `AppleInternal`. The device itself does not check, which is why this project's direct connection works and why it stays the only route. What can be done is to make that route cost less, and two things are built:

- **The directory is read once per tunnel.** `AccessibilityServicePorts` remembers the accessibility port a directory gave, keyed by the device and the tunnel's address: in memory for later commands of the same process (an MCP server, a `batch`), and in `~/Library/Application Support/manzanero/service-ports.json` (mode 600) for later processes. A result says which happened: `serviceDirectory: opened`, `reused-port` (this process's memory) or `reused-saved-port` (the file). A new tunnel has a new address, so its port is looked up afresh; an entry older than twelve hours is not used; a transport failure or timeout on a reused port forgets it. On the Apple TV 4K a `batch` of 30 accessibility steps opened the directory once and `remoted` logged one interruption instead of thirty, and ten separate commands on a tunnel already known logged none ([record](verification.md#one-directory-connection-per-tunnel)). The tunnel is dropped some seconds after the last command when nothing else holds the device, so commands spaced further apart than that each find a new tunnel and open the directory again.
- **A stale connection is refused before the command starts.** `StaleDeviceConnection.refuseIfStale` reads `remotectl dumpstate` and, if the device's own connection is `attached`, fails as `device-not-ready` before the usage assertion that would keep the stale tunnel alive.

The fault would only end with a tunnel of the tool's own, on which it would be the device's only directory peer. This project had such a route and retired it; reopening it is the human owner's decision.

## Earlier failures and why they matter

The code for these attempts (CoreDevice named AX socket, RemoteServiceDiscovery lookup/browse and transport-profile reads, connected-FD directory bootstrap, `remotectl netcat` relay) is gone; the findings remain as history.

- CoreDevice named AX sockets failed with error 4000, later including POSIX 83 (`EDEVERR`). The category did not establish a missing setting, credential or entitlement. Looked at again on 2026-11-18 against an Apple TV, with `CoreDeviceService`'s log open ([record](verification.md#asking-coredeviceservice-for-the-accessibility-socket)): the `createservicesocket` action does open a socket by service name alone for CoreDevice's own services (`com.apple.coredevice.hid.indigo`, `…openstdiosocket`, `…deviceinfo`, the ones `remoted` lists with a `Features` property), and for every other service tried (`…axAuditDaemon.remoteAXService`, its `remoteserver.shim.remote`, `com.apple.os_trace_relay.shim.remote`) `CoreDeviceService` logs `remote_service_connect_socket failed for '<service>' (errno=83)` within a millisecond, whatever feature identifier the request carries and with or without a tunnel assertion held. So the refusal is decided on the Mac, before any packet, and it separates CoreDevice's services from the rest; a feature identifier does not change it. The reason was then read from `remoted`'s code and from the device's directory: to connect to a service through `remoted`, a client must hold the entitlement that the service's directory entry names, and the device names `AppleInternal` for `remoteAXService`, which `remoted` grants only on an Apple-internal build of macOS. The shim services name `com.apple.mobile.lockdown.remote.trusted`. This is by design and not something a build of this project can satisfy: a `com.apple.private` entitlement cannot be claimed by software Apple did not sign.
- Direct RSD lookup/browse saw zero services while Apple's tool advertised AX. Apple `remotectl netcat` also failed before DTX. Advertising or service metadata was insufficient. Looked at again on 2026-11-18 against an Apple TV, with `remoted`'s log open: for a lookup of the AX service by this project's process, `remoted` says `Client lacks privilege to find service with name …remoteAXService`, so the reason is a privilege the process does not have; for `remotectl netcat` it grants the lookup and the connect then fails ([record](verification.md#the-apple-tv-4k-what-wakes-it-and-why-its-connection-goes-stale)).
- An early directory response passed once, but later connected-FD attempts returned `Connection invalid`. Nearby generic TLS-renegotiation logs did not establish a causal device-specific explanation.
- Holding a valid tunnel assertion and copying service mode-4/version flags did not repair those attempts. Service metadata is not directory bootstrap.
- The later unstarted-Network/mode-2 route succeeded. Its success does not retroactively make the earlier modes working fallbacks.

No TLS bypass, daemon suspension, private entitlement, pairing change or automatic replay was added to force those probes through.

## References

The native tunnel/directory work was informed by pinned [pymobiledevice3 native-tunnel](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/native_tunnel.py) and [RemoteXPC](https://github.com/doronz88/pymobiledevice3/blob/03d788d23105c1754c27cc4e6ddc1d7e23835b32/pymobiledevice3/remote/remotexpc.py) references, without adding that runtime or copying credentials/source.

The retired idevice path used independent pairing records and TLS-PSK software tunnels. Live pairing/reconnection remained unverified, and that route has been removed. See [dependencies](dependencies.md), [AX contracts](accessibility-protocol.md) and [verification](verification.md).
