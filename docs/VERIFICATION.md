# Verification records

## 2026-11-11 — simulator interaction backend

Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2, AXe 1.9.0-prerelease.1, iPhone 17 simulator running iOS 27.2.

- `swift test` through xcsift passed with zero errors/warnings: six test functions, including seven invalid-input cases. Coverage includes literal shell-sensitive text and leading-dash selectors, invalid numeric values and ambiguous targets, large subprocess output, and nonzero child-process diagnostics.
- Live CLI `simulator <UDID> tree` returned a JSON SpringBoard accessibility hierarchy.
- Live CLI `simulator <UDID> tap-label Settings` returned a dispatch receipt. A subsequent CLI tree returned an Application labeled Settings, its Settings heading, and settings rows. This verifies the selector tap changed the foreground app.
- Coordinate tap, drag, swipe, typing, and buttons are implemented but their live behavior has not yet been verified. Input success means dispatch only.
- Compiler cache and CoreSimulator services required execution outside the workspace sandbox. This is an environment constraint, not proof of unsupported device services.
- Physical-device input/accessibility, multitouch, streaming, and MCP are not implemented by this backend.

Installed `axe <command> --help` was checked for every wrapped command. Installed `devicectl help` confirms stdout JSON support via `--json-output -`. AXe attribution and installation link are in the root README; no third-party binaries or source are redistributed by this change.


## 2026-11-11 — pinned idevice dependency and physical HID bridge

Environment remains macOS 27.2.1, Xcode 27.2, Apple Swift 6.4.2; bridge built with Rust 1.99.1 (58cf8f9c3). Upstream idevice revision: `89702099f4d7552f704f93b4526756abda319ceb`, version 0.1.68.

- Swift tests through xcsift passed: nine test functions with zero warnings/errors, including ten additional invalid physical-input cases. New checks cover normalized endpoint/midpoint conversion, seconds-to-milliseconds conversion, simultaneous-contact counts, nonfinite/out-of-range coordinates, unsupported buttons/keys, and argument arity.
- Rust bridge build and two unit tests passed. Rust parser tests reject malformed coordinates, durations, multitouch pairs, and keys before connecting to any device. The committed Cargo lockfile was used for the offline repeat build.
- `python3 scripts/build-idevice.py --debug --offline` successfully built the optional helper into `tmp/bin` using the declared Git dependency. The development clone is not used by this build.
- A live read-only `hid-info` check targeted the physical iPhone discoverable through CoreDevice. It returned JSON error `Device not available through usbmuxd: device not found` with exit code 1 and no success payload. No touch, keyboard, or button input was sent. This provides failure-path evidence, not live HID functionality.
- Current connection support is an in-process CoreDeviceProxy tunnel from usbmuxd. Apple's separately paired CoreDevice-only Wi-Fi path is still missing.
- Audio/video stream negotiation, stream ownership detection, input dispatch, and cleanup are compiled but have not been verified on a physical device. The metadata and feature-mask values come from the pinned library's upstream example. The bridge checks for a reported active `streamConfig` before starting; simultaneous-controller behavior and cancellation cleanup remain unverified.


## 2026-11-11 — explicit Wi-Fi pairing and transport

Environment unchanged; Rust 1.99.1 and Swift 6.4.2.

- Swift tests through xcsift passed: 12 test functions, zero warnings/errors. Added checks cover interactive pairing planning, literal paths with spaces, private-record suffix, invalid host/port input, and restriction of `--pairing-file` to the physical HID backend.
- Six Rust tests passed with the pinned library and updated lockfile. Added checks cover pairing-record round trips, wrong-device rejection, malformed records/endpoints, removal of uncommitted reservations, mode 0600, and refusal to overwrite an existing record. These test locally generated fixture keys only.
- A dry run of `--pairing-file <path with spaces> physical <UDID> hid-info` produced the expected helper argument array.
- Native `remotectl netcat` proxy and direct-HID probes failed before input. That experimental path was removed; see [TRANSPORT.md](TRANSPORT.md).
- The implemented Wi-Fi path compiles against idevice's remote-pairing and native TLS-PSK APIs and holds its pairing control connection for the tunnel lifetime. No live pairing, trust change, or physical input was attempted. Device-side approval and a PIN are required before that verification can proceed.
- `dns-sd -h` was checked for the documented Bonjour browse/resolve commands. Endpoint discovery is manual and saved endpoint changes are not automatically handled yet.
