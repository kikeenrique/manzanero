# Beta binary distribution

The distribution model follows [cmagic's release task/workflow](https://github.com/kikeenrique/cmagic/tree/d84805469c29a836f9328609a8cc6aef16c52cc2/mise/tasks) and its [tap formula](https://github.com/kikeenrique/homebrew-tap/blob/main/Formula/cmagic.rb): prebuilt GitHub release archives, per-archive SHA-256 and a formula that installs the binary without compiling on the tester's Mac. This project targets macOS only. No device helper or Apple framework is redistributed.

## Local preparation

`Sources/AppleDevicesCMD/Version.swift` is the single version source for CLI/MCP metadata. Start with `0.1.0-beta.1`; bump it for each new beta. Never replace assets belonging to an existing published version.

```sh
mise run test
mise run package
mise run test:package
mise run release:formula <github-owner/repository>
```

Artifacts are written to ignored `tmp/dist/<version>/`: two byte-identical universal macOS archives, `SHA256SUMS`, a dynamic-linkage report and the generated `appledevicescmd.rb`. The build uses the committed Package.resolved and Swift 6.4+ (the pinned swift-collections manifest requires it). Each architecture is built separately, combined with Apple's lipo and ad-hoc signed. The native architecture runs version/help smoke checks. Intel device functionality still needs independent verification. Packaging refuses non-system dynamic dependencies and retains upstream/transitive license and notice files from the resolved source graph.

Apple's `swift-stdlib-tool` copies required Swift compatibility libraries under `lib/` when needed; the archive preserves the Swift runtime license. The locally verified optimized beta binary needed no supplemental library, unlike the debug build. Build-machine rpaths are removed and replaced by `@loader_path/lib`. Homebrew installs the payload in libexec and symlinks the executable into bin, keeping runtime lookup intact. No non-Apple runtime dependency is bundled.

The executable/runtime libraries are ad-hoc signed, not Developer ID signed/notarized. No signing identity or App Store provisioning is needed for this beta packaging. Before public licensing claims, choose a project license; this checkout currently carries third-party notices but no root project license. The formula deliberately does not invent one.

## GitHub workflow

The checkout must first be hosted in the chosen GitHub repository. The release workflow uses that repository's name at runtime; it does not assume a remote URL. A manual workflow dispatch builds/tests and uploads `beta-dist` artifacts without publishing. A pushed `v<version>` tag verifies the source version, runs tests, packages and publishes a GitHub prerelease with immutable archives, checksums and the generated formula. Existing releases are refused rather than overwritten. `contents: write` is limited to the publishing job.

The macOS runner selects Xcode 26.6, matching the [official macos-26 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). Local verification on newer Xcode does not substitute for running this workflow. A successful CI build is not live physical-device verification.

## Tap update

After release publication, use the attached `appledevicescmd.rb` as `Formula/appledevicescmd.rb` in [kikeenrique/homebrew-tap](https://github.com/kikeenrique/homebrew-tap). Check the release URLs/checksums, run Homebrew installation and `brew test`, then commit/push the formula update. Testers can then install `kikeenrique/tap/appledevicescmd`.

The release workflow intentionally does not assume its repository-scoped GitHub token can write to a separate tap. The formula is a reviewable release artifact; updating the tap is a separate step. Cross-repository automation can use a narrowly scoped GitHub App or token if configured later. No token is stored in this repository.
