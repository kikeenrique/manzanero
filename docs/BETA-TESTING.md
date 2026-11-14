# Beta testing appledevicescmd

This is a macOS command-line tool, with optional MCP over stdio. There is no app to install on the phone for the verified control paths. The package contains one universal arm64/x86_64 executable, required Swift compatibility runtime libraries under `lib/`, this guide and third-party notices. It does not bundle Apple device frameworks, helper executables, signing credentials or device data.

## Installation

Once the first GitHub prerelease and tap formula are published:

```sh
brew install kikeenrique/tap/appledevicescmd
appledevicescmd --version
appledevicescmd doctor
```

Update with `brew update && brew upgrade appledevicescmd`. The tap formula explicitly records prerelease versions so Homebrew can distinguish beta updates. Until publication, the installation command is not available.

Manual installation: download the archive matching your Mac and `SHA256SUMS` from the same release. Run `shasum -a 256 -c SHA256SUMS` in the download directory (download both named archives for the complete checksum check), extract the archive and add its directory to PATH. Keep `lib/` beside `appledevicescmd` and preserve the accompanying notices. Both archives contain the same universal payload. Beta archives are ad-hoc signed, without Developer ID notarization; they do not provide Apple-verified publisher identity.

## Prerequisites and first checks

- macOS 15 or later for the executable; native video needs macOS 26 or later. The live physical evidence currently comes from macOS 27.2.1, Xcode 27.2 and one iPhone 13 mini running iOS 27.2.1. Building another architecture does not verify its device behavior.
- A full Xcode installation selected with `xcode-select`, its license accepted and developer components installed. The CLI dynamically uses installed Apple developer frameworks; Command Line Tools alone are insufficient for physical control.
- A paired, trusted, connected device. Enable Developer Mode and, for UI input, Settings → Developer → Enable UI Automation. Keep the device awake and unlocked for the tested flows. Readiness reports prerequisites; it does not prove every operation works.

```sh
appledevicescmd devices physical
appledevicescmd physical <hardware-UDID> readiness
appledevicescmd physical <hardware-UDID> screenshot screen.png
appledevicescmd physical <hardware-UDID> tree
appledevicescmd physical <hardware-UDID> button home
```

Use a fresh screenshot/tree after actions to check effects. Input receipts acknowledge dispatch, not application behavior. Physical coordinates are normalized 0...1. A command can partially change the device before failing. There is no automatic input replay or fallback to a non-Apple helper.

For an MCP host, configure the installed `appledevicescmd` executable with argument `mcp`. The host controls tool approvals. Stdout is the protocol channel; diagnostics use stderr. Avoid running independent controllers against the same device. SIGINT/SIGTERM and MCP EOF attempt owned cleanup, but forced exit, crashes and disconnection do not guarantee it.

## Feedback

Report the release version, host macOS/Xcode versions, device model/OS, exact command with private values removed, expected behavior and stderr. Screenshots, app lists, paths, logs and files under the working directory's `tmp/` may contain personal data; review them before sharing. Never upload pairing records, credentials or commercial application binaries.

Known beta gaps include intermittent recording startup, keyframe/crash/disconnect recovery, independent controller ownership, incomplete simulator input migration and limited validation across other Apple families. Android is outside the project scope. See the repository's feature-status and verification docs for scoped evidence.
