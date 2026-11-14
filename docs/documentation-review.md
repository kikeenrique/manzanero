# Documentation maintenance

The documentation separates four kinds of information:

1. **Current use:** commands a reader can run through supported routes.
2. **Implemented but unverified:** code whose live behavior is not established.
3. **Historical evidence:** earlier implementations, successes and failed probes.
4. **Implementation references:** Apple interfaces and attributed open-source protocol research.

This distinction matters because the project replaced several helper-backed paths while retaining their source and test records.

## Reader paths

- Start with [README](../readme.md), [beta setup](beta-testing.md) and [readiness](readiness.md).
- Use focused guides for [input](native-input.md), [screens](screen-understanding.md), [AX](direct-accessibility.md), [recording](recording.md), [Build & Run](build-run.md) and [MCP](mcp.md).
- Maintain the project using [dependencies](dependencies.md), [tasks](development-tasks.md), [releasing](releasing.md) and [roadmap](roadmap.md).
- Consult [verification](verification.md), [transport](transport.md) and [AX wire contracts](accessibility-protocol.md) for evidence/design detail.

## Corrections made in the readability pass

The 2026-11-14 rewrite removed retired helper installation from current usage guides, corrected the effective Swift 6.4 build requirement, exposed the separate UI-readiness meaning, and updated recording descriptions to the owned pixel-buffer route and five-minute/interaction evidence.

Repeated “now implemented” chronology and intermediate test-count/artifact-UUID lists were condensed. Material failures remain in verification/research: ineffective dispatches, denied AVC output access, first-frame/packet startup failures, ambiguous cleanup and transient wake.

The accompanying help-text correction removes stale AX restrictions and retired pairing setup from current guidance. Source routing and scoped verification remain necessary: a command planner or MCP catalog entry alone is not availability proof.

Validation for this pass checked 135 local links/anchors, 41 current command forms through query-free `--dry-run`, and 36 local verification checkpoint references. The CLI built without errors/warnings and its help smoke check passed. Gitleaks found no detected secrets in the rewritten README/docs. No physical-device operation was run for this documentation task.

## Reviewing a future change

Check these before describing a capability as available:

- Does the shared service reach an executable route permitted by runtime policy?
- Do argument names, defaults, ranges and output fields match source/task help?
- Does the evidence exercise the current backend, rather than a retired helper?
- Are native acceptance, visible effect and cleanup separate?
- Are failures, limitations and device/OS/tool versions retained?
- Are examples actionable from a source checkout, with existing parent paths where required?
- Do local links/anchors resolve, and does README lead to the right page?
- Are private identifiers, screenshots, credentials and local paths excluded?

Only run meaningful validation for the change. A docs-only edit needs source/command/link review, not a new physical-device action. Never turn a passing build or fixture into a broad hardware claim.

## Earlier review context

Earlier reviews clarified Build & Run, saved reports versus live trace, handoff and agent access. Later reviews separated helper-backed captures from direct replacements. Those corrections are reflected in the current guides; dated facts remain in [verification](verification.md).

The [public-readiness review](public-readiness.md) is a separate privacy/licensing/publication checkpoint. Documentation cleanup does not select a license, rewrite Git identity/history or provide legal clearance.
