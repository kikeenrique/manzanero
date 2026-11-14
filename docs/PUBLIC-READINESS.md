# Public repository readiness

The remaining publication decisions are the root license and, as the final step, GitHub hosting and release delivery. Publication has not happened.

## Publication checklist

| Item | Status |
| --- | --- |
| Root license | Pending owner selection. Preserve separate notices in `ThirdParty/` and reflect the license in the README and Homebrew formula. |
| Repository instructions | Portable instructions replace the personal home-directory import. Local execution permissions remain in ignored `.codex/config.toml`. |
| Git identity | Keep existing author and committer names and email addresses, as requested by the owner. |
| History privacy | Complete: all 95 existing commits were rewritten to remove personal home paths, local execution configuration and the private investigation document. Targeted checks passed across reachable history; author/committer identities and timestamps were preserved. |
| Documentation | Describe supported operations and distinguish implementation from observed device behavior. See [verification](VERIFICATION.md). |
| Project description | Independent Apple-device wording is used in current files and historical revisions, including source and test identifiers. Targeted checks across reachable history passed. The server identifier rename passed all 314 tests with no build errors or warnings. |
| Hosting and releases | Deferred until other preparation is complete. Select the repository, run the beta workflow and test the Homebrew formula. See [releasing](RELEASING.md). |

History cleanup changes commit IDs. Recovery copies and investigation artifacts stay under ignored `tmp/`; never publish that directory or include it in a source archive. Required attribution remains in [dependencies](DEPENDENCIES.md) and `ThirdParty/`.

## Earlier audit

The local audit on 2026-11-14 used Gitleaks 8.30.1 against the then-current tracked snapshot and all 88 then-reachable commits. Both scans reported no findings with default rules, full redaction and allow-comments disabled. Source and reports were not uploaded.

That audit also found no tracked screenshots, movies, commercial app packages, pairing records, `.env` files, key or certificate exports, provisioning profiles or phone crash reports. Targeted checks found no designated-phone identifiers in tracked files or history.

These are historical results, not a guarantee that every private value is absent. The owner requested no additional secrets scan during this cleanup. Targeted checks for removed paths, files and references still verify the requested history changes. Private audit reports remain under `tmp/public-audit/`.

## Public description

> appledevicescmd is an independent Swift command-line tool for inspecting and automating Apple devices, with an optional MCP server for agents.

Lead with actual capabilities and limitations. Retain attribution for implementation references and avoid implying affiliation with Apple.

[GitHub's licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository) explains why a root license matters for open-source reuse.
