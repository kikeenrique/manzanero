# Public repository readiness

The project uses the [MIT license](../license), and its public source repository is [kikeenrique/manzanero](https://github.com/kikeenrique/manzanero). The first beta's release assets were published on 2026-11-18 and its formula is in the [tap](https://github.com/kikeenrique/homebrew-tap).

## Publication checklist

| Item | Status |
| --- | --- |
| Root license | MIT, selected by the owner. The license is included in beta archives and declared in the Homebrew formula. Separate notices in `ThirdParty/` retain their own terms. |
| Repository instructions | Portable instructions replace the personal home-directory import. Local execution permissions remain in ignored `.codex/config.toml`. |
| Git identity | Keep existing author and committer names and email addresses, as requested by the owner. |
| History privacy | Complete: all 95 existing commits were rewritten to remove personal home paths, local execution configuration and the private investigation document. Targeted checks passed across reachable history; author/committer identities and timestamps were preserved. On 2026-11-18 a second, small rewrite removed the test phone's UDID from 11 commits ([below](#audit-before-the-first-release-2026-11-18)). |
| Documentation | Describe supported operations and distinguish implementation from observed device behavior. See [verification](verification.md). |
| Project description | Independent Apple-device wording is used in current files and historical revisions, including source and test identifiers. Targeted checks across reachable history passed. The server identifier rename passed all 314 tests with no build errors or warnings. |
| Hosting and releases | Public source repository created; v0.1.0-beta.1 published as a prerelease on 2026-11-18. The formula is in the tap and a real Homebrew install passed on one Mac ([record](verification.md#homebrew-install-from-the-tap)). That first beta shipped a universal binary, an Intel block in its formula and a macOS 15 claim, none of which the tool can honour; the sources are corrected for the next beta, and the tap's formula was corrected the same day. See [releasing](releasing.md). |

History cleanup changes commit IDs. `tmp/` is untracked working space: never publish that directory or include it in a source archive. Required attribution remains in [dependencies](dependencies.md) and `ThirdParty/`.

## Audit before the second beta, 2026-11-21

Done on the pushed history before `v0.1.0-beta.2` was tagged, by the steps of the first audit below.

- **Device identifiers.** Every identifier of the development Mac's paired devices and simulators (UDIDs, ECIDs, serial numbers, CoreDevice and host UUIDs), the account name and the devices' own names, searched in every revision and every commit message. The night before, one simulator UUID of that Mac, in a test fixture since 2026-11-19 and not yet pushed, was replaced in history by the fixture UUID `11111111-2222-3333-4444-555555555555`. Found now, already pushed: the phone's own name, "iPhone 13m", in a quoted instruction in the roadmap (reworded) and in a verification line removed earlier. A device name reaches nothing; history was left as it is.
- **Secrets.** Gitleaks 8.30.1 over every reachable commit: one finding, `RemotePairing.swift:18`, a line that reads a variable named `privateKey` into CryptoKit, not a key. No other finding. The pairing identities the tool stores live under Application Support, never in the repository.
- **The archive.** The first local package for beta.2 carried the checkout's absolute path, the builder's home directory included, eleven times: lwIP's assertions embed `__FILE__`. The package task now builds with a C macro prefix map (`-fmacro-prefix-map`; Swift's `-file-prefix-map` was tried too and dropped, because it gave the release build 30 warnings about precompiled modules it could no longer find) and `test:package` fails on an executable that carries the checkout's path; the rebuilt archive has none.

## Audit before the first release, 2026-11-18

Done before any tag exists, because a published tag makes a later history change expensive.

- **A device identifier was found and removed.** A check of tracked files for this project's test phone and Mac found the phone's hardware UDID in one test file, in two lines, added on 2026-11-17 and already pushed. At the owner's decision it was replaced with the test fixture's UDID in the file and in history (`git filter-repo --replace-text`, contents and messages). The 11 commits from that one to the tip have new IDs; the 242 before it are unchanged. Authors, committers and dates were preserved, and the only difference between the old and new trees is those two lines. The build and all 702 tests passed afterwards. The owner force-pushed the rewritten `main` before the release was tagged. GitHub can keep the replaced commits reachable by their IDs for some time after a force push; only GitHub Support can purge them at once.
- **Other identifiers.** Across every revision: no other hardware UDID than test fixtures, no CoreDevice or host UUID of the test machines, no home-directory path, no email address in file contents, no network name.
- **Secrets.** Gitleaks 8.30.1, default rules, full redaction, allow-comments disabled: no findings in the rewritten history (every reachable commit) and none in an export of the 323 tracked files. Source and reports were not uploaded.
- **Tracked files.** No movies, app packages, pairing records, `.env` files, key or certificate exports, provisioning profiles or crash reports; the three tracked images are the project's own artwork in `docs/assets/`.

A UDID is not a credential, and the device cannot be reached with it; it was removed because no device identifier belongs in the repository. These are results for the state checked, not a guarantee about what is added later: repeat the identifier check and the scan before each release.
## Earlier audit

The local audit on 2026-11-14 used Gitleaks 8.30.1 against the then-current tracked snapshot and all 88 then-reachable commits. Both scans reported no findings with default rules, full redaction and allow-comments disabled. Source and reports were not uploaded.

That audit also found no tracked screenshots, movies, commercial app packages, pairing records, `.env` files, key or certificate exports, provisioning profiles or phone crash reports. Targeted checks found no designated-phone identifiers in tracked files or history.

These are historical results, not a guarantee that every private value is absent. The owner requested no additional secrets scan during this cleanup. Targeted checks for removed paths, files and references still verify the requested history changes.
## Public description

> Manzanero is an independent Swift command-line tool for inspecting and automating Apple devices, with an optional MCP server for agents.

Lead with actual capabilities and limitations. Retain attribution for implementation references and avoid implying affiliation with Apple.

[GitHub's licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository) explains why a root license matters for open-source reuse.
