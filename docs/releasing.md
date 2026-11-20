# Preparing a beta release

Distribution follows the prebuilt-archive model used by [cmagic](https://github.com/kikeenrique/cmagic/tree/d84805469c29a836f9328609a8cc6aef16c52cc2/mise/tasks) and its [Homebrew formula](https://github.com/kikeenrique/homebrew-tap/blob/main/Formula/cmagic.rb): GitHub release archives, SHA-256 checksums and a tap formula that installs without compiling on the tester's Mac.

The source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero), configured locally as `origin`. The first beta, [v0.1.0-beta.1](https://github.com/kikeenrique/manzanero/releases/tag/v0.1.0-beta.1), was published on 2026-11-18 after a manual rehearsal of the workflow ([record](verification.md#first-beta-published)). Manzanero uses the [MIT license](../license); release archives include it alongside the separate third-party notices.

## Build and review locally

`Sources/Manzanero/Version.swift` is the single CLI/MCP version source. Increment it for each beta; never replace assets for an already published version.

```sh
mise run test
mise run package
mise run test:package
mise run release:formula <github-owner/repository>
```

Output is under `tmp/dist/<version>/`:

- one Apple silicon archive, `manzanero-aarch64-apple-darwin.tar.gz` (v0.1.0-beta.1 shipped a universal binary under two names; an Intel slice cannot work, because Xcode 27 does not run on Intel);
- `SHA256SUMS`;
- a dynamic-linkage report;
- generated `manzanero.rb`.

The package task builds for arm64 with prefix maps that keep the checkout's absolute path out of the binary (lwIP's assertions embed `__FILE__`), removes machine-specific runtime paths, signs ad hoc and smoke-tests native version/help. The archive test checks extraction, the signature, that the executable is arm64 with a macOS 26.6 deployment target and carries no absolute path of the checkout, notices and CLI execution through a Homebrew-style symlink. The formula declares `arch: :arm64`, `macos: :tahoe` and Xcode 27.0 at run time; Homebrew names macOS by major version only, so the 26.6 line is held by the executable's deployment target and by `manzanero doctor`.

Swift 6.4+ is needed by the resolved graph. Apple’s `swift-stdlib-tool` bundles compatibility libraries when needed; the verified optimized beta needed none. Homebrew preserves payload layout in libexec and symlinks the executable into bin.

Applicable package/transitive notices and Package.resolved are included. No Apple device framework or non-Apple device helper is bundled. The release is not Developer ID signed/notarized; no signing identity is required for this local beta path.

## GitHub workflow

The workflow uses its repository name at runtime rather than assuming a remote URL.

| Trigger | Result |
| --- | --- |
| Manual workflow dispatch | Build/test and upload `beta-dist`; no publication |
| Pushed matching `v<version>` tag | Build/test/package, create a draft prerelease with assets, then publish it |

Source version and tag must agree. Existing releases are refused to preserve immutable tap checksums. `contents: write` is limited to the publishing job.

The workflow selects Xcode 27.2 (`/Applications/Xcode_27.2.app`) on the `xcode-27` image, following its [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). The `macos-26` image tops out at Xcode 26.6 (Swift 6.3); `xcode-27` is still a GitHub [preview](https://github.com/actions/runner-images/issues/14404) and defaults to Xcode 27.1, so the path is selected explicitly. Each run records the actual Xcode and Swift versions. A CI build is not live-device verification. See the [CI review](ci-review.md) for the original failure and subsequent validation.

## CI and caching

`.github/workflows/ci.yml` builds and tests pushes to `main` and pull requests, and validates mise tasks. A newer run for the same ref cancels an older CI run. Release runs for the same ref are serialized without cancellation to avoid interrupting publication.

Both workflows use the same mise tasks and cache these generated paths:

| Cache | Paths | Reuse |
| --- | --- | --- |
| SwiftPM dependencies | `tmp/swift-cache` | Shared between ordinary CI and packaging |
| Debug products/compiler modules | `.build`, `tmp/clang-cache` | Shared between ordinary CI and packaging |
| Release products/checkouts | `tmp/release-build` | Packaging only |

Keys include the runner OS/architecture, a fingerprint of Xcode and Swift versions, and `Package.swift`/`Package.resolved`. Build-product keys also include the commit, with restore prefixes for incremental reuse. Debug and release products remain separate. The project-level mise environment sets the compiler cache path so nested tasks use the same root cache.

Caches contain disposable generated state. Moving a checkout can invalidate absolute paths inside compiler modules; delete the affected caches under `tmp/` and rebuild rather than changing source to work around stale output.

## Publish a beta

First run the workflow manually to inspect its artifacts without publishing:

```sh
gh workflow run release.yml --ref main
```

After validation, repeat the identifier check and the secrets scan of the [public-readiness audit](public-readiness.md#audit-before-the-first-release-2026-11-18), update `Sources/Manzanero/Version.swift`, commit and push the version change, wait for CI on that commit, then run, with the new version:

```sh
mise run release v0.1.0-beta.2
```

Run the pushes and this task from your own terminal. A shell inside an agent session has no access to the SSH key: on 2026-11-18 the task created the local tag there and then failed at the push; run again from a terminal, it reused the tag and published.

Use the tag matching the committed version. The task rejects a dirty worktree (leaving `tmp/` out of that check, since it is untracked on purpose) or mismatched version, creates a missing tag, and reuses an existing tag only when it points at HEAD. It pushes that tag to `origin`; this triggers real prerelease publication. It never moves a tag or overwrites release assets. If a published release needs changes, choose a new version.

## Update the tap

After publishing, copy the attached formula to `Formula/manzanero.rb` in [kikeenrique/homebrew-tap](https://github.com/kikeenrique/homebrew-tap). Check URLs/checksums, run `brew style` on it there and `brew audit --strict --online kikeenrique/tap/manzanero` once Homebrew's clone of the tap has it (`brew audit` takes a name, not a path), test an actual `brew install` and `brew test`, then commit/push the tap change.

For v0.1.0-beta.1 this was done on 2026-11-18 ([record](verification.md#homebrew-install-from-the-tap)). The formula attached to that release needed its blocks reordered to pass `brew style`, and it still names an Intel archive and macOS 15; the generator has since changed to one Apple silicon archive with `arch: :arm64`, `macos: :tahoe` and Xcode 27.0, and the tap's beta.1 formula was replaced with that shape the same day: `brew style` found no offenses (the explicit `version` is accepted beside the `url`), `brew audit --strict --online` had no findings, and a reinstall passed ([record](verification.md#the-taps-formula-apple-silicon-only)). So a formula from the generator can now go into the tap unchanged.

The release repository's default token is not assumed to write to the separate tap. Formula generation produces a reviewable artifact; cross-repository automation needs a separately configured narrow token or GitHub App. No token is stored here.

The [public-readiness review](public-readiness.md) was completed before the first publication. See [tester setup](beta-testing.md) for the installation experience.
