# CI and release workflow review

The release setup follows cmagic's shared mise tasks, universal macOS archives, checksums, manual nonpublishing workflow and tag-triggered publication. This review adds its missing ordinary CI, cache persistence and guarded release command while retaining immutable release assets.

## Original failure

[Run 43658281613](https://github.com/kikeenrique/manzanero/actions/runs/43658281613), at `e5f51f2`, failed while compiling `Tests/ManzaneroTests/MCPToolOperations.swift`. Swift rejected a task closure in the parameterized shutdown/drain test as an unsafe sending boundary. Packaging never started.

The test now explicitly marks that task closure `@Sendable`, requiring the compiler to check its shared actor/mutex captures. Strict concurrency remains enabled; no unsafe conformance or weakened checking was added. Hosted validation is required because the local toolchain is Apple Swift 6.4.2/Xcode 27.2 while CI selects Xcode 26.6.

## Changes

- Build/test CI runs on main pushes and pull requests, using the project's mise tasks and device-free native sender tests.
- Dependency and debug caches are shared by CI and packaging; release products have a separate cache. Keys distinguish OS, architecture, compiler toolchain, package inputs and build commits.
- Superseded ordinary CI runs are cancelled. Release runs on a ref are serialized without cancellation.
- `mise run release <version>` checks a clean worktree, the declared version and any existing tag before pushing a tag. Published assets remain immutable.
- The compiler cache is defined at project level in mise, preventing task-relative cache paths. Stale local compiler output from the checkout rename was moved aside under ignored `tmp/`.

## Validation

The clean generated-output rebuild passed all 314 local Swift tests with no errors or warnings. Device-free native multitouch and gesture sender tests passed. All 49 mise tasks validated, actionlint and Bash syntax checks passed, and 130 local documentation links were checked. Hosted validation of these changes has not completed.

Release-task checks use a temporary Git repository and local bare remote, never the public repository. They cover invalid/mismatched versions, a dirty worktree, initial tag creation/push, retry reuse and refusal to move an existing tag.

These checks do not establish live-device behavior or publish a beta. The cmagic reference was reviewed at [`d848054`](https://github.com/kikeenrique/cmagic/tree/d84805469c29a836f9328609a8cc6aef16c52cc2).
