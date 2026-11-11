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
- Several parity features remain absent, including parsed physical accessibility, streaming/recording, physical text entry, app data transfer, reports/logs, Build & Run, agent handoff, and MCP. See [ROADMAP.md](ROADMAP.md).

## Validation

Mise task definitions validated; cached debug and release bridge builds succeeded; the bridge's ten tests and Swift's thirteen test functions passed. Current command examples were compared with the parsers/help, dry-run arguments were checked, and local Markdown file links were checked. These checks validate the instructions and synthetic behavior, not live physical-device functionality.
