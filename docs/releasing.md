# Preparing a beta release

Distribution follows the prebuilt-archive model used by [cmagic](https://github.com/kikeenrique/cmagic/tree/d84805469c29a836f9328609a8cc6aef16c52cc2/mise/tasks) and its [Homebrew formula](https://github.com/kikeenrique/homebrew-tap/blob/main/Formula/cmagic.rb): GitHub release archives, SHA-256 checksums and a tap formula that installs without compiling on the tester's Mac.

The source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero), configured locally as `origin`. The first beta, [v0.1.0-beta.1](https://github.com/kikeenrique/manzanero/releases/tag/v0.1.0-beta.1), was published on 2026-11-18 after a manual rehearsal of the workflow ([record](verification.md#first-beta-published)); the second, [v0.1.0-beta.2](https://github.com/kikeenrique/manzanero/releases/tag/v0.1.0-beta.2), on 2026-11-21 by the steps below ([record](verification.md#second-beta-published)). Manzanero uses the [MIT license](../license); release archives include it alongside the separate third-party notices.

## Build and review locally

`Sources/Manzanero/Version.swift` is the single CLI/MCP version source; `mise run release` sets it. A published version's assets are never replaced.

```sh
mise run test
mise run package
mise run test:package
```

Output is under `tmp/dist/<version>/`:

- one Apple silicon archive, `manzanero-aarch64-apple-darwin.tar.gz` (v0.1.0-beta.1 shipped a universal binary under two names; an Intel slice cannot work, because Xcode 27 does not run on Intel);
- `SHA256SUMS`;
- a dynamic-linkage report.

The package task builds for arm64 with a C macro prefix map that keeps the checkout's absolute path out of the binary (lwIP's assertions embed `__FILE__`; Swift's own file prefix map is not used, because it broke the precompiled modules' paths), removes machine-specific runtime paths, signs ad hoc and smoke-tests native version/help. The archive test checks extraction, the signature, that the executable is arm64 with a macOS 26.6 deployment target and carries no absolute path of the checkout, notices and CLI execution through a Homebrew-style symlink. Homebrew names macOS by major version only, so the 26.6 line is held by the executable's deployment target and by `manzanero doctor`.

Swift 6.4+ is needed by the resolved graph. Apple’s `swift-stdlib-tool` bundles compatibility libraries when needed; the verified optimized beta needed none. Homebrew preserves payload layout in libexec and symlinks the executable into bin.

Applicable package/transitive notices and Package.resolved are included. No Apple device framework or non-Apple device helper is bundled. The package task signs ad hoc; the Developer ID signature and notarization are added on the human owner's Mac before a release is published ([notarization](#notarization)).

## GitHub workflow

The workflow uses its repository name at runtime rather than assuming a remote URL.

| Trigger | Result |
| --- | --- |
| Manual workflow dispatch | `mise run release:ci v<version> --no-release`: validate, test, package, upload `beta-dist`; no release |
| Pushed matching `v<version>` tag | `mise run release:ci <tag>`: validate, test, package and create a draft prerelease with the ad hoc archive and `SHA256SUMS`; the draft is published from the human owner's Mac once its binaries are signed and notarized |

The job is one mise task, so it runs on the human owner's Mac just as well; `mise run release` runs it there when no workflow run comes. Source version and tag must agree, and an existing release is left as it is. The job has `contents: write` to create the draft.

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

Optionally, build the archive in CI without creating any release, to look at it first:

```sh
gh workflow run release.yml --ref main
```

The release is one command, from the human owner's own terminal, on `main` with a clean tree:

```sh
mise run release v0.1.0-beta.3
```

It runs, in order, and stops at the first failure; running it again continues from where it stopped. Each step is a mise task, and nothing is edited by hand before, between or after them, documentation included: what a release carries is in its notes on GitHub.

1. `check:secrets` and `check:identifiers` on everything since the previous release tag; a finding stops the release, and nothing is written;
2. sets `Sources/Manzanero/Version.swift` to the version and commits it ("Set the version to <version>") unless it is set already, creates the tag (or reuses it at HEAD; a tag is never moved), and pushes `main` and the tag together in one atomic push;
3. waits for the release workflow the tag started (`release:ci` in CI) and its draft prerelease; when no run comes within three minutes, runs `release:ci` here; a release that exists already is not waited for;
4. `release:notarize`: Developer ID signing, notarization and publication ([notarization](#notarization)).

The Homebrew tap, [kikeenrique/homebrew-tap](https://github.com/kikeenrique/homebrew-tap), is another repository and follows a published release by its own means; no tap code lives here.

Run it from the human owner's own terminal. A shell inside an agent session has no access to the SSH key: on 2026-11-18 the task created the local tag there and then failed at the push; run again from a terminal, it reused the tag and published.

The task rejects a dirty worktree (leaving `tmp/` out of that check, since it is untracked on purpose) and a branch other than `main`. It never moves a tag or replaces a published release's assets; if a published release needs changes, choose a new version.

## Notarization

Signing with the Developer ID and notarization are the only release steps on the human owner's Mac; the signing identity and the notary credentials never go to CI. Since 2026-11-23; the trial passed that day ([record](verification.md#signing-and-notarization-trial)), and no notarized release has been published yet.

One-time setup:

1. An Apple Developer Program membership and a Developer ID Application certificate with its private key in this Mac's keychain (`security find-identity -v -p codesigning` lists it).
2. Notary credentials stored in the keychain, from the human owner's own terminal, so that no secret passes through an agent session. Either an app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords; the team ID is in the developer account's membership details):

   ```sh
   xcrun notarytool store-credentials manzanero-notary --apple-id <apple-id> --team-id <TEAMID>
   ```

   or an App Store Connect API key (Users and Access › Integrations › Team Keys, Developer role; the `.p8` is downloadable once and stays out of every repository): `xcrun notarytool store-credentials manzanero-notary --key <path.p8> --key-id <KEYID> --issuer <ISSUER>`. `xcrun notarytool history --keychain-profile manzanero-notary` checks it.
3. The identity in the untracked `.env.local`, which `mise.toml` loads: `MANZANERO_SIGN_IDENTITY=<SHA-1 hash>`, the 40-digit hash `security find-identity -v -p codesigning` prints, or its full name `"Developer ID Application: <name> (<TEAMID>)"`. Use the hash when the keychain holds two certificates of one name (a new one beside the one it replaces): `codesign` refuses an ambiguous name, and the task lists the hashes to choose from. The certificate must belong to the notary profile's team. `MANZANERO_NOTARY_PROFILE` names another profile than `manzanero-notary`.

`mise run release:notarize <version>` then:

- downloads the draft release's archive and `SHA256SUMS` and checks them (it refuses a release that is not a draft, so a published asset is never replaced);
- signs the bundled Swift runtimes and the executable with the Developer ID and a secure timestamp, the executable with the hardened runtime, and checks all three;
- submits a zip of the same files to the notary service and waits, without a time limit, until it answers; it requires `Accepted` and keeps the service's log beside the archive. Apple says notarization ends for most software within 5 minutes, for 98 percent within 15, and typically within an hour;
- waits until Gatekeeper's own assessment (`spctl --assess --type install`) reports the executable "Notarized Developer ID", at most 60 minutes (five minutes after acceptance in the trial, at once in a later run);
- packs the archive again as the package task does, writes `SHA256SUMS`, runs `test:package`, replaces the draft's archive and checksum and publishes it as a prerelease.

**A run that stops is continued by running it again.** Every call to Apple or GitHub is tried three times with a growing pause, and what each step achieved is kept in `tmp/dist/<version>/notarize/`: the signed files (reused while their signatures verify, never signed again), the submission's identifier (written before the wait, so a rerun asks the service about that submission and never uploads a second one; still in progress, it stops and says so), and markers for an accepted notarization and for Gatekeeper's assessment. Packing and checking the archive are repeated, and the upload replaces the draft's assets again; a release already published counts as done only if it carries the same archive. A notarization that ends `Invalid` or `Rejected` stops with its log, and `--restart` discards the kept state and starts again from signing. On 2026-11-23 a rerun after a finished run took 1 s and sent nothing, one with only the submission identifier kept asked the service about it and finished, and one after three failed uploads (a wrong profile name) reused the signed files and submitted once.

A bare executable cannot hold a stapled ticket (Apple: "it's not currently possible to staple tickets to them"), so `syspolicy_check distribution`, a local check of app bundles that demands one, always fails it; Gatekeeper fetches the ticket online the first time a downloaded copy runs. Through Homebrew the binary is not quarantined either way.

Before the first notarized release, check the signed binary on devices: the hardened runtime may refuse something the tool loads at run time (Apple's private frameworks). `mise run package`, then `mise run release:notarize <version> --local --no-publish` signs and notarizes that archive under `tmp/dist/<version>/` and changes no release; run `doctor`, a simulator tap and tree, and the phone's input, accessibility and recording with it.

The [public-readiness review](public-readiness.md) was completed before the first publication. See [tester setup](beta-testing.md) for the installation experience.
