# Beta testing

`manzanero` is a macOS CLI with optional MCP over stdio. The verified physical-control paths do not install an app, profile or helper on the phone.

The beta package contains a universal arm64/x86_64 executable, any required Swift compatibility libraries under `lib/`, this guide and third-party notices. It does not contain Apple device frameworks, device helpers, signing credentials or device data.

## Installation status

The initial GitHub release and tap formula are **not published yet**. For source builds, follow [README](../readme.md#build-and-start) and substitute `mise run cli` for the bare executable below. Once published, installation is intended to be:

```sh
brew install kikeenrique/tap/manzanero
manzanero --version
manzanero doctor
```

Updates use `brew update && brew upgrade manzanero`. The formula records the beta version explicitly so Homebrew can distinguish prereleases.

For a manual release archive, download matching assets and `SHA256SUMS` from the same release. The full checksum file lists both archive names, so download both for `shasum -a 256 -c SHA256SUMS`. Extract one archive, keep `lib/` beside the executable and add that directory to PATH.

Archives are ad-hoc signed, without Developer ID notarization. They do not provide Apple-verified publisher identity.

## Prepare the Mac and device

- macOS 15+ for the executable; macOS 26+ for native video.
- Full Xcode selected as the active developer directory, license accepted and developer components installed.
- A paired, trusted device with Developer Mode enabled, or a booted simulator addressed by its UUID (`--simulator <UUID>`).
- For the verified UI flows: awake/unlocked device and **Settings → Developer → Enable UI Automation** enabled.
- For native recording with the macOS firewall on: a rule allowing incoming connections for the installed `manzanero` executable. The beta archive is ad-hoc signed, so it is not allowed automatically. `manzanero doctor` reports the state and the path; see [recording](recording.md#the-macos-firewall-can-drop-the-video).

```sh
manzanero devices
manzanero readiness --device <hardware-UDID>
manzanero screenshot tmp/screen.png --device <hardware-UDID>
manzanero tree --device <hardware-UDID>
manzanero button home --device <hardware-UDID>
```

Ensure the output parent directory exists. Readiness reports CoreDevice prerequisites and separate display/passcode observations; it does not verify UI Automation or prove current UI unlock.

The live evidence is mostly iPhone 13 mini on iOS 27.2.1, with macOS 27.2.1/Xcode 27.2. Building Intel output or accepting another device ID does not verify that hardware.

## Testing safely and usefully

Inspect fresh state after actions. Physical touch coordinates are normalized `0...1`; AX frames use logical points. A receipt acknowledges dispatch, not application behavior. A failed command may have partially changed the device.

Paste replaces the clipboard. The tool does not automatically retry input, approve prompts or switch to a non-Apple helper. A second `manzanero` process that tries to send input to a device another one is controlling is refused (`device-busy`); Xcode and other tools are not coordinated.

SIGINT/SIGTERM and MCP EOF attempt owned cleanup. Crashes, forced exits and disconnects do not guarantee release or rollback.

## MCP setup

Launch the installed executable with argument `mcp` from your host configuration. Use an absolute executable path and a suitable working directory. Stdout is the protocol channel; diagnostics go to stderr. The host controls approvals. See [MCP](mcp.md).

## Reporting a problem

Include the release version, host macOS/Xcode versions, device model/OS, redacted command, expected result and stderr. Review captures, app inventories, paths and `tmp/` contents before sharing. Never upload pairing records, credentials or commercial application binaries.

Known gaps include recording recovery, release after a failure, devices other than one iPhone 13 mini, and Apple TV, Apple Watch and iPhone Duo hardware (simulators only so far). Check [feature status](feature-status.md), the [roadmap](roadmap.md#pending) and [verification](verification.md) before interpreting a failure.
