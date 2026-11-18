# Documentation maintenance

The documentation separates four kinds of information:

1. **Current use:** commands a reader can run through supported routes.
2. **Implemented but unverified:** code whose live behavior is not established.
3. **Historical evidence:** earlier implementations, successes and failed probes.
4. **Implementation references:** Apple interfaces and attributed open-source protocol research.

This distinction matters because the project replaced several helper-backed paths. Their sources are gone (git history keeps them); their results stay in [verification](verification.md#retired-implementations) as history.

## Reader paths

- Start with [README](../readme.md), [beta setup](beta-testing.md) and [readiness](readiness.md).
- Use focused guides for [input](native-input.md), [typing](physical-typing.md), [screens](screen-understanding.md), [AX](direct-accessibility.md), [recording](recording.md), [Build & Run](build-run.md), [app logs](app-logs.md), [simulators](simulator-input.md), [other families](other-families.md), [errors](errors.md) and [MCP](mcp.md).
- Maintain the project using [dependencies](dependencies.md), [tasks](development-tasks.md), [releasing](releasing.md) and the [roadmap](roadmap.md).
- Three pages track progress and must agree: [feature status](feature-status.md) (inventory), the [roadmap](roadmap.md) (achieved and pending) and the [live check plan](live-check-plan.md) (hardware runs still owed). [Verification](verification.md) is the dated record they rest on.
- Consult [verification](verification.md), [transport](transport.md) and [AX wire contracts](accessibility-protocol.md) for evidence/design detail. Research notes (`*-research.md`, [keyboard layouts](keyboard-layouts.md)) and the [argument parser proposal](cli-argument-parser-proposal.md) are historical records with a status line at the top.

## Corrections made in the readability pass

The 2026-11-14 rewrite removed retired helper installation from current usage guides, corrected the effective Swift 6.4 build requirement, exposed the separate UI-readiness meaning, and updated recording descriptions to the owned pixel-buffer route and five-minute/interaction evidence.

Repeated “now implemented” chronology and intermediate test-count/artifact-UUID lists were condensed. Material failures remain in verification/research: ineffective dispatches, denied AVC output access, first-frame/packet startup failures, ambiguous cleanup and transient wake.

The accompanying help-text correction removes stale AX restrictions and retired pairing setup from current guidance. Source routing and scoped verification remain necessary: a command planner or MCP catalog entry alone is not availability proof.

Validation for this pass checked 135 local links/anchors, 41 current command forms through query-free `--dry-run`, and 36 local verification checkpoint references. The CLI built without errors/warnings and its help smoke check passed. Gitleaks found no detected secrets in the rewritten README/docs. No physical-device operation was run for this documentation task.

## Consistency pass, 2026-11-16

After two days of features that each updated only their nearest docs, every page was checked against the built CLI's help, dry runs and the MCP tool list rather than against other pages. The roadmap was rewritten as achieved and pending work. Corrections included waits, the device lease, container files, physical Build & Run, physical `console`/`last-crash` and the probe app, all described as unverified on hardware although [verification](verification.md) records phone runs; simulator `screen` described as having no tree; physical `set-value` described as refused; and retired helper sources described as kept. All relative links resolved, every documented `manzanero` command line parsed with `--dry-run` or was checked against `--help`, and no device or simulator was contacted.

## Consistency pass, 2026-11-18

After the first beta, every page except the dated research files was read against a list of what the night of 2026-11-17 and the following day had changed: the Apple silicon, macOS 26.6 and Xcode 27 requirement, `doctor`'s requirement entry, selection by value, the off-edge press and the browser PID, the masked read-back, the screenshot display note, the second pass of error categories, handoff finished, the RTCP result, the log relay, the Duo runs, and the release. About sixty statements were corrected, among them a readme that still said no beta was published, a tester guide that described two archives, guides that named `--id` and `--label` only, and summary sentences in the verification record that later sections contradict, which got "Later:" notes rather than rewrites. The roadmap was rewritten again as achieved and pending work, renumbered. All 644 relative links and anchors resolved, the documented commands were compared with the CLI's command definitions, the MCP guide lists the 46 tools the server defines, and no device or simulator was contacted for the pass.

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
