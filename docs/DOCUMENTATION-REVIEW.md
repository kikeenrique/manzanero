# Documentation review — 2026-11-11

Reviewed the root README and all existing files in `docs/` against the current Swift/Rust sources, Cargo and Swift manifests, test output, local investigation artifacts, installed tool help, and current vendor pages. This review corrects documentation; it does not establish missing runtime behavior.

## Findings corrected

| Priority | Finding | Correction and evidence |
| --- | --- | --- |
| High | Quick-start examples used `appledevicescmd` without putting the Swift executable on PATH. The helper-only PATH was insufficient. | README and dependency setup now include both `.build/debug` and `tmp/bin`. Mise debug/release builds and generated task help were checked. |
| High | “Physical discovery” implied a physical-only list, although the implementation forwards unfiltered CoreDevice JSON. | README and roadmap state that simulators can appear. Filtering remains an implementation gap; documentation no longer claims it exists. |
| High | Pairing cleanup promised removal after cancellation without distinguishing future cancellation from process termination. | Dependency and verification records describe the drop guard accurately. It handles ordinary errors/dropped futures; SIGINT/SIGKILL/host-crash cleanup is unverified and may leave a partial file. The tests exercise guard destruction, not killed processes. |
| High | A generic “JSON errors” statement applied a Rust bridge behavior to the whole CLI. | README and dependency notes distinguish bridge JSON errors from the Swift runner's text wrapper. Uniform machine-readable CLI errors remain unimplemented. |
| Medium | The roadmap called a mixed list “required” without showing which items came from the user, vendor sources, or engineering proposals. It omitted explicit Watch coverage. | Roadmap now separates those origins and includes per-feature sources and implementation evidence. Android remains an open scope question. |
| Medium | The earlier explanation classified Build & Run as an engineering proposal, but the vendor documents it. | It is now a sourced parity feature, linked to [Build & Run]([private reference removed]). The CLI implementation is still missing. |
| Medium | The investigation still said opening/disassembling the framework was the next step, although later paragraphs recorded that work. | Investigation now states the current Hopper state and preserves relevant addresses without obsolete next-step instructions. |
| Medium | Current instructions depended on the Python build helper, and historical verification entries read like current setup. | The helper is removed in favor of mise tasks. Current setup uses mise; historical results are explicitly scoped to their revision. |
| Medium | Wi-Fi setup was nested under AXe, and the upstream-repository reference was ambiguous. | Dependency sections now have the correct hierarchy and distinguish the upstream idevice manifest from this project's Swift manifest. |
| Medium | Raw accessibility protocol work could be mistaken for a physical UI hierarchy. | README, roadmap, and a dedicated [protocol note](ACCESSIBILITY-PROTOCOL.md) say that `ax-snapshot` returns an experimental callback archive with `parsedHierarchy: false`. No live tree or selector behavior is claimed. |
| Low | README mentioned a local OCR fixture as though a fresh checkout supplied it, and the investigation implied an old licensing discrepancy was current. | Local-only fixture assumptions were removed from setup; OCR's failure is recorded without assigning an unproven cause. Current vendor statements are distinguished from historical observations. |

## Material limits retained

- No live physical input, Wi-Fi pairing/reconnection, or physical accessibility snapshot has been verified.
- The only recorded successful input flow is the simulator home-screen tree → Settings label tap → Settings tree.
- OCR's initial fixture execution failed. Automatic screenshot/OCR fallback is not implemented.
- Internal media negotiation for HID authentication is not a user-facing streaming or recording feature.
- The vendor's current public feature list and the inspected 0.9.0/build 90 binary are different evidence sources. Static strings and symbols do not prove live invocation order or feature availability on every OS.
- Several parity features remain absent, including parsed physical accessibility, streaming/recording, physical text entry, Xcode-format app-container export/replacement, saved reports, Build & Run, agent handoff, and MCP. Raw app-container listing/pull/push plans were added in `dd01a90`; their app-container behavior remains unverified live. See [ROADMAP.md](ROADMAP.md).

## Validation

The initial review used the `cd0a1ca` baseline: mise task definitions validated; cached debug and release bridge builds succeeded; the bridge's ten tests and Swift's thirteen test functions passed. Command examples were compared with the parsers/help, dry-run arguments were checked, and local Markdown file links were checked. These checks validate the instructions and synthetic behavior, not live physical-device functionality. The later `dd01a90` verification record reports 17 Swift test functions; neither count establishes the current unfinished working tree's build status.

## Second review against committed baseline and working tree

Reviewed the README and all seven documents again against `dd01a90`, current source/manifests, mise tasks, and recorded verification. Rechecked the vendor's [iPhone setup]([private reference removed]), [saved reports]([private reference removed]), and [Build & Run]([private reference removed]) pages on 2026-11-11.

| Priority | Finding | Disposition |
| --- | --- | --- |
| High | The working tree advertises report/log commands, but the Rust entry point declares `mod logs` and calls `logs::capture` without a corresponding `src/logs.rs` or `src/logs/mod.rs`. Earlier successful builds cannot substantiate this draft. | Unfinished implementation, left untouched by this documentation task. The roadmap now identifies its committed baseline and excludes draft changes. The optional bridge needs completion and a fresh build/test before these commands can be documented as available. |
| Medium | This review's outstanding-feature list still described all app-data transfer as absent after `dd01a90` added raw container command plans. | Corrected to distinguish raw file plans from missing `.xcappdata` packaging/replacement and unverified app-container permissions. |
| Medium | The investigation inferred working OCR fallback from static MCP tool descriptions. | Reworded as intended behavior with no observed runtime fallback. |
| Medium | “Crash reports and logs” could turn a saved-report parity item into an assumed live log-streaming requirement. | Roadmap now names saved reports, spins, logs, and diagnostics. The vendor page documents list/read/save/delete operations; continuous live OS logs need separate scope/evidence. |
| Low | The validation paragraph's 13-test count could be read as current. | Bound it to `cd0a1ca` and linked the later verification context. No build/test success is claimed for unfinished source. |

Validation for this second pass: source/document comparison, vendor-page checks, local Markdown target checks, and `git diff --check`. No device operation or new runtime verification was performed. Existing implementation changes remain outside this documentation commit.

### Subsequent implementation follow-up

The missing log module was implemented after this review. The report/log verification entry in [VERIFICATION.md](VERIFICATION.md) records fresh Swift/Rust tests and bridge builds, plus live CLI report listing. The high-priority draft-build finding above is resolved by that work. Report downloads and live OS-log capture remain unverified; saved-report parity remains incomplete.

Build & Run was subsequently added with explicit scheme selection and verified project/Debug and workspace/Release simulator flows. The historical missing-feature references above do not describe that later implementation; see its [contract and remaining limits](BUILD-RUN.md) and verification entry. Physical deployment remains unverified.
