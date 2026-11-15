# Preparing a beta release

Distribution follows the prebuilt-archive model used by [cmagic](https://github.com/kikeenrique/cmagic/tree/d84805469c29a836f9328609a8cc6aef16c52cc2/mise/tasks) and its [Homebrew formula](https://github.com/kikeenrique/homebrew-tap/blob/main/Formula/cmagic.rb): GitHub release archives, SHA-256 checksums and a tap formula that installs without compiling on the tester's Mac.

The source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero), configured locally as `origin`. The initial beta release is not published. Manzanero uses the [MIT license](../license); release archives include it alongside the separate third-party notices.

## Build and review locally

`Sources/Manzanero/Version.swift` is the single CLI/MCP version source. Increment it for each beta; never replace assets for an already published version.

```sh
mise run test
mise run package
mise run test:package
mise run release:formula <github-owner/repository>
```

Output is under ignored `tmp/dist/<version>/`:

- two byte-identical universal macOS archives under architecture-specific names;
- `SHA256SUMS`;
- a dynamic-linkage report;
- generated `manzanero.rb`.

The package task builds each architecture, combines with lipo, removes machine-specific runtime paths, signs ad hoc and smoke-tests native version/help. The archive test checks extraction, signatures, architectures, notices and CLI execution through a Homebrew-style symlink.

Swift 6.4+ is needed by the resolved graph. Apple’s `swift-stdlib-tool` bundles compatibility libraries when needed; the verified optimized beta needed none. Homebrew preserves payload layout in libexec and symlinks the executable into bin.

Applicable package/transitive notices and Package.resolved are included. No Apple device framework or non-Apple device helper is bundled. The release is not Developer ID signed/notarized; no signing identity is required for this local beta path.

## GitHub workflow

The workflow uses its repository name at runtime rather than assuming a remote URL.

| Trigger | Result |
| --- | --- |
| Manual workflow dispatch | Build/test and upload `beta-dist`; no publication |
| Pushed matching `v<version>` tag | Build/test/package, create a draft prerelease with assets, then publish it |

Source version and tag must agree. Existing releases are refused to preserve immutable tap checksums. `contents: write` is limited to the publishing job.

The workflow selects Xcode 26.6 on `macos-26`, following the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). Local checks have passed, but the workflow itself has not yet run. A CI build is not live-device verification.

## Update the tap

After publishing, copy the attached formula to `Formula/manzanero.rb` in [kikeenrique/homebrew-tap](https://github.com/kikeenrique/homebrew-tap). Check URLs/checksums, test actual Homebrew installation and `brew test`, then commit/push the tap change.

The release repository's default token is not assumed to write to the separate tap. Formula generation produces a reviewable artifact; cross-repository automation needs a separately configured narrow token or GitHub App. No token is stored here.

Before first publication, complete the [public-readiness review](public-readiness.md). See [tester setup](beta-testing.md) for the intended installation experience.
