# Public repository readiness review

Reviewed 2026-11-14 against `7022375`, before initial GitHub publication. Recommendation: complete the items below before publishing unchanged. This is a source/history privacy and release-readiness review, not legal clearance or a guarantee that every possible secret format has been detected.

## Secret and artifact checks

- Gitleaks 8.30.1, default detection rules, 100% redaction and allow-comments disabled: no findings in the tracked HEAD snapshot or across all 88 reachable commits (`--all --full-history`). The tool ran locally; source and reports were not uploaded. Private reports are `tmp/public-audit/tracked-secrets.json` and `history-secrets.json`.
- No tracked screenshots, movies, DMGs/IPAs, pairing records, `.env` files, private-key/certificate exports, provisioning profiles or phone crash reports were found at HEAD. An added-file history search found none of those artifact categories either.
- Targeted checks found no occurrence of the designated test phone's actual hardware UDID or resolved CoreDevice UUID in tracked files or reachable history. Test fixtures contain identifier-shaped strings; these must remain synthetic.
- Ignored `tmp/` contains real device data and research artifacts. It must remain excluded from Git and from any manually uploaded source zip. The binary packaging task selects its own payload and does not archive the working directory.

These results reduce the risk of publishing credentials; they do not prove that ignored local artifacts are safe to share or that arbitrary private information is absent.

## Items to resolve

| Priority | Finding | Recommended action |
| --- | --- | --- |
| Before open-source publication | No root project license. Third-party notices do not license this project's own code. | Choose a project license, add it at the root, and reflect it in the README/formula. Preserve existing third-party licenses. |
| Privacy/portability | `.codex/config.toml:7` and `AGENTS.md:3` contain a developer-specific absolute home path. The tracked Codex file also distributes local execution configuration. These entered in the initial commit. | Keep personal Codex permissions local and make shared repository instructions self-contained/portable. Decide whether the historical path needs removal before the first push. |
| Owner preference | Git author/committer metadata uses a real name and email address. | Confirm that identity should be public, or use the owner's GitHub noreply address for the public history. Changing a current Git setting does not alter old commits. |
| Public positioning | README and roadmap lead with device-control tooling parity/replication language. | Describe the independent tool's actual Apple-device capabilities and current limitations. Retain accurate, attributed comparisons/provenance in supporting material. |
| Provenance review | `docs/ANALYSIS.md` and `docs/ACCESSIBILITY-PROTOCOL.md` describe static inspection of a commercial framework, including symbols/addresses. The inspected commercial binary is not tracked or packaged. | Review what should be published and the applicable upstream terms. These notes need an explicit publication decision; renaming the project does not replace that review. Do not claim a different development history. |
| Documentation accuracy | Several historical sections still describe retired helper backends and earlier verification limits. | Make the current path clear before beta onboarding. Label retained history consistently and check CLI help against implemented behavior. |

No history was rewritten, author identity changed, license selected or repository published by this review. Initial release hosting is still an owner decision. A history rewrite changes commit IDs and needs coordination; if a real credential is ever found, revoke/rotate it before considering removal from history.

## Suggested public introduction

> appledevicescmd is an independent Swift command-line tool for inspecting and automating Apple devices, with an optional MCP server for AI agents. It uses Apple frameworks and developer tools for screenshots, accessibility inspection, app operations, physical input and video recording. The project is in beta; support and verification vary by feature and device family.

Use the feature-status table as the source of supported claims. A comparison to another product can be factual and separately attributed; there is no need to make “a clone of device-control tooling” the project's public identity. Keep necessary notices and honest implementation provenance. This review does not establish affiliation with Apple, device-control tooling or Proxyman.

References: [GitHub licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository), [GitHub sensitive-history guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
