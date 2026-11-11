# Backend dependencies

The main CLI is Swift 6.2+ with strict concurrency. Xcode supplies `devicectl` and `simctl`; macOS supplies Vision. Private protocol implementations stay behind optional backend boundaries.

## idevice

Physical HID uses the open-source [idevice library](https://github.com/jkcoxson/idevice), by Jackson Coxson, under the MIT license. Its source is declared as a Git dependency in [the bridge manifest](../Backends/IDevice/Cargo.toml), pinned to revision `89702099f4d7552f704f93b4526756abda319ceb`. [Cargo.lock](../Backends/IDevice/Cargo.lock) records the transitive dependency versions and registry checksums. A development clone in `tmp/idevice` is investigation material and is not needed to build the shipped backend.

This revision's `swift/Package.swift` describes local binary XCFramework targets. The upstream idevice repository root has no Swift package manifest, and its C FFI does not expose HID or display-stream clients. Adding this repository directly to SwiftPM would not provide these APIs. The small Rust executable in `Backends/IDevice` therefore depends on the library directly; the Swift CLI validates and plans commands, then invokes the bridge with an argument array. JSON is the process boundary. It does not run the upstream example CLI, whose error paths sometimes return success.

The bridge's display-stream startup is adapted from the MIT-licensed `tools/src/coredevice_stream.rs` at the same revision. The complete [MIT notice](../ThirdParty/idevice-LICENSE.txt) is retained. No proprietary device-control tooling binary is used or redistributed. Distributing a compiled bridge also requires preserving the licenses of the transitive libraries included in that build.

### Build

Install mise (tested with 2026.10.20), then run from the repository root:

```sh
mise run idevice:build
export PATH="$PWD/.build/debug:$PWD/tmp/bin:$PATH"
swift build
.build/debug/appledevicescmd physical <UDID> hid-info
```

`mise run idevice:build` installs Rust 1.99.1 under `tmp/`, builds the bridge with the committed Cargo lockfile, and copies it to `tmp/bin`. Use `mise run idevice:build --debug --offline` for a debug build with cached Cargo dependencies, and `mise run idevice:test --offline` for bridge tests. The toolchain must already be installed for a fully offline first step. Cargo downloads, Rust toolchain files, mise's tool data/cache, and bridge outputs stay under `tmp/`. The Swift CLI itself builds without Rust; physical input, HID discovery, accessibility snapshots, and Wi-Fi pairing require the bridge on PATH.

### Protocol and verification limits

The bridge connects to an exact UDID exposed by usbmuxd, opens a software CoreDeviceProxy tunnel, discovers services through RSD, and uses RemoteXPC. A device visible in `devicectl` is not necessarily available through usbmuxd. For devices absent from usbmuxd, the optional `--pairing-file` path verifies a tool-specific Wi-Fi record and creates a separate TLS-PSK/software tunnel. That path is implemented but not live-verified; it does not reuse Apple’s existing trust keys or RSD connection. The vendor’s setup guide calls for Mac trust, Developer Mode, and UI Automation. The exact authorization checks for each operation in this backend have not been verified.

Physical `tap`, `multi-tap`, `swipe`, and `drag` take normalized 0...1 coordinates, origin at the top left. The Swift planner converts them to the library's 16-bit touch range. Simulator input uses interface points instead. `multi-tap` sends two to five simultaneous contacts and release, not an arbitrary moving multitouch gesture. `swipe` uses a touch drag rather than the upstream digitizer-swipe example that is marked nonworking. Physical drags use 30 movement samples; the per-sample delay is integer milliseconds, so actual duration is approximate.

The library's input examples require a display stream for HID authentication. The bridge holds audio/video sockets while dispatching, then attempts to stop the stream after normal dispatch success or failure. The available stop operation is `stopAll`; the bridge refuses a reported pre-existing `streamConfig`, but concurrent controllers and all possible server-status formats have not been verified. Do not use simultaneous screen controllers for input checks. If setup times out or the process is killed, connection teardown is the remaining cleanup mechanism; stream cleanup after cancellation is unverified.

Successful bridge input returns `status: dispatched` and `verified: false`; confirm effects with a screenshot or other observation. The bridge emits JSON errors on stderr and exits nonzero. The Swift CLI currently wraps subprocess failures in text, so end-to-end CLI errors are not uniformly JSON. Live physical input is **not verified**: the current device was discoverable through CoreDevice but absent from usbmuxd. See [verification records](VERIFICATION.md).

### Wi-Fi pairing

Use a device-advertised `_remotepairing._tcp` endpoint (hostname and port). Apple's installed Bonjour utility can browse and resolve those endpoints:

```sh
dns-sd -B _remotepairing._tcp local
# Stop browsing with Ctrl-C; resolve the selected service instance:
dns-sd -L '<instance-name>' _remotepairing._tcp local
```

Both commands stay running; stop them after reading the service information. Pairing requires approval on the device and its displayed PIN. No automatic trust pairing occurs during a normal HID command.

```sh
mkdir -p tmp/pairings
appledevicescmd pair wifi <host> <port> tmp/pairings/phone.pairing.plist
# Enter the device's six-digit PIN when prompted.
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> hid-info
appledevicescmd --pairing-file tmp/pairings/phone.pairing.plist physical <UDID> tap 0.5 0.5
```

The pairing result returns the discovered UDID. Keep it for later commands: the record must match the requested UDID, and the bridge also checks the RSD `UniqueDeviceID` when supplied by the device. Records contain private signing keys, are created with mode 0600 on macOS, and are never overwritten. A drop guard attempts to remove an unfinished record on ordinary errors and when the pairing future is dropped, including its timeout. Abrupt process termination can bypass that guard and leave an empty or partial file; cleanup after Ctrl-C or a kill has not been verified. The Swift CLI requires the `.pairing.plist` suffix, which is excluded from Git; keep records under ignored `tmp/` as well. A device reset, revoked trust, or changed advertised endpoint may require explicitly pairing to a new record. Endpoint rediscovery is currently manual.

The Wi-Fi protocol path follows the pinned idevice `RemotePairingClient`, `RpPairingSocket`, and native TLS-PSK tunnel APIs. Pairing has a 180-second deadline; bridge device operations have a 60-second deadline. Device PIN entry is on stdin and prompts are on stderr; JSON command results remain on stdout. A wrong PIN has no all-zero/default fallback.

Live initial pairing, reconnection, HID effects, and cancellation on a physical device remain unverified. Consult [transport investigation](TRANSPORT.md) before attempting to reuse Apple's active tunnel instead.

## AXe

Simulator input uses [AXe](https://github.com/cameroncooke/AXe), by Cameron Cooke, licensed under MIT and using Meta IDB. Install AXe separately with its accompanying license notices. This repository neither vendors its source nor redistributes its binaries. Its argument surface was checked against installed AXe 1.9.0-prerelease.1.


## Experimental accessibility snapshots

`physical <UDID> ax-snapshot` uses the protocol bridge and accepts the same optional `--pairing-file` prefix. It captures the first matching remote-accessibility callback archive as base64 JSON. It does not decode a physical UI hierarchy. The request lifecycle and payload meaning remain unverified on hardware; see [protocol evidence](ACCESSIBILITY-PROTOCOL.md).
