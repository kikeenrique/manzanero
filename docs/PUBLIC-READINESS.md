# Public repository readiness

The audit against `7022375` on 2026-11-14 found no detected credentials, but recommended cleanup and owner decisions before publication. It is a source/history privacy review, not legal clearance or a guarantee that every private value is absent.

## Scan results

Gitleaks 8.30.1 scanned the tracked snapshot and all 88 then-reachable commits with default rules, full redaction and allow-comments disabled. Both scans had no findings. The tool ran locally; source/reports were not uploaded.

No screenshots, movies, commercial DMGs/IPAs, pairing records, `.env` files, key/certificate exports, provisioning profiles or phone crash reports were found in tracked HEAD or the added-file history search. Targeted checks found no actual designated-phone UDID/CoreDevice UUID in tracked files/history.

These results apply to that audited commit. Ignored `tmp/` contains real device and investigation data; it is not safe to publish wholesale or include in a source zip. Private scan reports remain under `tmp/public-audit/`.

## Before publishing

| Item | Action |
| --- | --- |
| Root license absent | Choose the project's license; preserve separate third-party notices and reflect the decision in the README/formula. |
| Personal agent configuration | Make repository instructions portable and keep local execution permissions private. The audited `.codex/config.toml` and `AGENTS.md` include a developer-specific home path. |
| Git identity | Confirm whether the recorded author name/email should be public. Changing current Git configuration does not change old commits. |
| Commercial-framework research | Decide what to publish after reviewing the original inspection notes and applicable terms. No commercial binary is tracked or packaged; that alone is not legal clearance. |
| Documentation | Keep current supported routes distinct from historical helpers and accurately state device-verification limits. |
| Release hosting | Select the GitHub repository, run the workflow and publish/test the actual tap formula. |

No history, author identity or license was changed by the audit. History rewriting changes commit IDs and needs coordination. If a real credential is discovered, revoke/rotate it before considering history removal; see [GitHub's guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

## Public description and provenance

A useful introduction is:

> appledevicescmd is an independent Swift command-line tool for inspecting and automating Apple devices, with an optional MCP server for agents.

Lead with actual capabilities and limitations. Factual comparisons can remain in supporting material; “a clone of device-control tooling” need not be the project's public identity. Changing the headline does not change development history or replace attribution.

[ANALYSIS.md](ANALYSIS.md) retains the commercial-framework inspection provenance, and [dependencies](DEPENDENCIES.md) identify independent references and notices. The project does not claim affiliation with Apple, device-control tooling or Proxyman.

[GitHub's licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository) explains why a root license matters for open-source reuse.
