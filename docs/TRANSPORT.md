# Physical transport investigation

## 2026-11-11 — Apple Wi-Fi tunnel versus an independent pairing

Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), physical iPhone running iOS 27.2.1. Read-only `devicectl device info details` succeeded outside the sandbox. It reported manual pairing, local-network transport, a connected TCP tunnel, and Developer Mode enabled. Local outputs are under ignored `tmp/`; device identifiers, addresses, and serial numbers are omitted here.

Installed `/usr/libexec/remotectl help` documents `show`, `get-property`, and `netcat`. `show` confirmed the connected phone advertises Universal HID, Indigo HID, display service, and remote accessibility services. Advertised service presence alone does not prove their operations are authorized or working.

Two experimental bridge probes used `remotectl netcat`: one to `com.apple.internal.devicecompute.CoreDeviceProxy`, the other directly to `com.apple.coredevice.hid.universalhidservice`. Both were refused before protocol initialization; the latter ended with HTTP/2 connection-closed. The failed automatic fallback and native netcat implementation were removed from the production bridge. No physical input was sent by these probes.

For comparison, the open-source [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) checkout at `03d788d23105c1754c27cc4e6ddc1d7e23835b32` was inspected in `tmp/pymobiledevice3`. Its `remote/native_tunnel.py`, `remote/remotexpc.py`, and `docs/guides/network-stacks.md` describe an opt-in method that acquires an Apple tunnel assertion and locates the active RSD port. They also describe RSD connections competing with remoted on a shared source address, and device service reattachment when the peer identity changes. These are upstream research findings, not independently reproduced behavior here. No pymobiledevice3 source is copied or linked by appledevicescmd.

The implemented Wi-Fi path instead uses idevice's own `RemotePairingClient`, a tool-specific record, a newly requested TCP listener, native TLS-PSK, and a separate software tunnel. Ordinary device commands only verify an existing pairing; initial pairing is explicit and requires device approval and PIN entry. This avoids adding a competing RSD client to Apple's active tunnel. Live behavior is still unverified.

See [backend setup](DEPENDENCIES.md) for the commands and [verification records](VERIFICATION.md) for what was actually tested.
