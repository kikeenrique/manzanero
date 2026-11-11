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
