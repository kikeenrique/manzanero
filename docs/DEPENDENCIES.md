# Backend dependencies

The main CLI is Swift 6.2+ with strict concurrency. Xcode supplies `devicectl`, `simctl`, and Vision. Private protocol implementations stay behind optional backend boundaries.

## idevice

Physical HID uses the open-source [idevice library](https://github.com/jkcoxson/idevice), by Jackson Coxson, under the MIT license. Its source is declared as a Git dependency in [the bridge manifest](../Backends/IDevice/Cargo.toml), pinned to revision `89702099f4d7552f704f93b4526756abda319ceb`. [Cargo.lock](../Backends/IDevice/Cargo.lock) records the transitive dependency versions and registry checksums. A development clone in `tmp/idevice` is investigation material and is not needed to build the shipped backend.

This revision's `swift/Package.swift` describes local binary XCFramework targets. The repository root has no Swift package manifest, and its C FFI does not expose HID or display-stream clients. Adding this repository directly to SwiftPM would not provide these APIs. The small Rust executable in `Backends/IDevice` therefore depends on the library directly; the Swift CLI validates and plans commands, then invokes the bridge with an argument array. JSON is the process boundary. It does not run the upstream example CLI, whose error paths sometimes return success.

The bridge's display-stream startup is adapted from the MIT-licensed `tools/src/coredevice_stream.rs` at the same revision. The complete [MIT notice](../ThirdParty/idevice-LICENSE.txt) is retained. No proprietary device-control tooling binary is used or redistributed. Distributing a compiled bridge also requires preserving the licenses of the transitive libraries included in that build.

### Build

Install Rust/Cargo (verified with Rust 1.99.1), then run from the repository root:

```sh
python3 scripts/build-idevice.py
export PATH="$PWD/tmp/bin:$PATH"
swift build
.build/debug/appledevicescmd physical <UDID> hid-info
```

The build script uses the committed lockfile, stores Cargo downloads and build outputs under `tmp/`, and places the helper in `tmp/bin`. `--debug` selects a debug build; `--offline` uses an already populated Cargo cache. It can also use the locally installed toolchain under `tmp/cargo-home` and `tmp/rustup`. The Swift CLI itself builds without Rust; only physical input and HID discovery require the bridge on PATH.

### Protocol and verification limits

The bridge connects to an exact UDID exposed by usbmuxd, opens a software CoreDeviceProxy tunnel, discovers services through RSD, and uses RemoteXPC. A device visible in `devicectl` is not necessarily available through usbmuxd; Apple remote-pairing-only Wi-Fi devices are not supported by this connection path yet. Trust, Developer Mode, UI Automation authorization, and compatible device services remain prerequisites imposed by the device.

Physical `tap`, `multi-tap`, `swipe`, and `drag` take normalized 0...1 coordinates, origin at the top left. The Swift planner converts them to the library's 16-bit touch range. Simulator input uses interface points instead. `multi-tap` sends two to five simultaneous contacts and release, not an arbitrary moving multitouch gesture. `swipe` uses a touch drag rather than the upstream digitizer-swipe example that is marked nonworking. Durations are quantized to 30 samples.

The library's input examples require a display stream for HID authentication. The bridge holds audio/video sockets while dispatching, then stops the stream even when input fails. The available stop operation is `stopAll`; the bridge refuses a reported pre-existing `streamConfig`, but concurrent controllers and all possible server-status formats have not been verified. Do not use simultaneous screen controllers for input checks. If setup times out or the process is killed, connection teardown is the remaining cleanup mechanism; stream cleanup after cancellation is unverified.

Successful input returns `status: dispatched` and `verified: false`; confirm effects with a screenshot or other observation. Errors are JSON on stderr with a nonzero exit status. Live physical input is **not verified**: the current device was discoverable through CoreDevice but absent from usbmuxd. See [verification records](VERIFICATION.md).

## AXe

Simulator input uses [AXe](https://github.com/cameroncooke/AXe), by Cameron Cooke, licensed under MIT and using Meta IDB. Install AXe separately with its accompanying license notices. This repository neither vendors its source nor redistributes its binaries. Its argument surface was checked against installed AXe 1.9.0-prerelease.1.
