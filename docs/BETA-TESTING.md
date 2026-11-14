# Beta testing

`appledevicescmd` is a macOS CLI with optional MCP over stdio. The verified physical-control paths do not install an app, profile or helper on the phone.

The beta package contains a universal arm64/x86_64 executable, any required Swift compatibility libraries under `lib/`, this guide and third-party notices. It does not contain Apple device frameworks, device helpers, signing credentials or device data.

## Installation status

The initial GitHub release and tap formula are **not published yet**. For source builds, follow [README](../README.md#build-and-start) and substitute `mise run cli` for the bare executable below. Once published, installation is intended to be:

```sh
brew install kikeenrique/tap/appledevicescmd
appledevicescmd --version
appledevicescmd doctor
```

Updates use `brew update && brew upgrade appledevicescmd`. The formula records the beta version explicitly so Homebrew can distinguish prereleases.

For a manual release archive, download matching assets and `SHA256SUMS` from the same release. The full checksum file lists both archive names, so download both for `shasum -a 256 -c SHA256SUMS`. Extract one archive, keep `lib/` beside the executable and add that directory to PATH.

Archives are ad-hoc signed, without Developer ID notarization. They do not provide Apple-verified publisher identity.

## Prepare the Mac and device

- macOS 15+ for the executable; macOS 26+ for native video.
- Full Xcode selected as the active developer directory, license accepted and developer components installed.
- A paired, trusted device with Developer Mode enabled.
- For the verified UI flows: awake/unlocked device and **Settings → Developer → Enable UI Automation** enabled.

```sh
appledevicescmd devices physical
appledevicescmd physical <hardware-UDID> readiness
appledevicescmd physical <hardware-UDID> screenshot tmp/screen.png
appledevicescmd physical <hardware-UDID> tree
appledevicescmd physical <hardware-UDID> button home
```

Ensure the output parent directory exists. Readiness reports CoreDevice prerequisites and separate display/passcode observations; it does not verify UI Automation or prove current UI unlock.

The live evidence is mostly iPhone 13 mini on iOS 27.2.1, with macOS 27.2.1/Xcode 27.2. Building Intel output or accepting another device ID does not verify that hardware.

## Testing safely and usefully

Inspect fresh state after actions. Physical touch coordinates are normalized `0...1`; AX frames use logical points. A receipt acknowledges dispatch, not application behavior. A failed command may have partially changed the device.

Paste replaces the clipboard. The tool does not automatically retry input, approve prompts or switch to a non-Apple helper. Independent controllers can compete; avoid simultaneous CLI/server processes on one device.

SIGINT/SIGTERM and MCP EOF attempt owned cleanup. Crashes, forced exits and disconnects do not guarantee release or rollback.

## MCP setup

Launch the installed executable with argument `mcp` from your host configuration. Use an absolute executable path and a suitable working directory. Stdout is the protocol channel; diagnostics go to stderr. The host controls approvals. See [MCP](MCP.md).

## Reporting a problem

Include the release version, host macOS/Xcode versions, device model/OS, redacted command, expected result and stderr. Review captures, app inventories, paths and `tmp/` contents before sharing. Never upload pairing records, credentials or commercial application binaries.

Known gaps include recording startup/recovery, cross-process ownership, direct simulator input migration and broader Apple-family validation. Android is outside scope. Check [feature status](PARITY-STATUS.md) and [verification](VERIFICATION.md) before interpreting a failure.
