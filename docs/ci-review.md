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

## Test starvation on small runners

After the compile fix, hosted runs failed in different tests each time: [run 43665298767](https://github.com/kikeenrique/manzanero/actions/runs/43665298767) in socket-deadline and OCR tests, and [run 43699105452](https://github.com/kikeenrique/manzanero/actions/runs/43699105452) (at `1086b65`) in `EOFDeadlineArmsOnceAndCompletionDisarmsIt` and both cases of `shutdownCancelsOwnedWorkAndDrainsItsCleanupBeforeReturning`, each about 4.4 s into a 5.1 s test phase. GitHub documents three cores for its standard arm64 macOS runners (the job log does not print the count), so the Swift concurrency cooperative pool that Swift Testing runs every test on has about three threads.

The failing tests shared one pattern, also present in tests that had not failed yet:

- Waiting for another task by spinning (`while !done, now < limit { await Task.yield() }`) against a 2 s wall-clock limit. Spinners keep pool threads and cores busy, so the work they wait for, and Dispatch timers used by the product watchdogs, can be delayed past the limit.
- Running a blocking C schedule (with a 10 s gap) as a pool task while the test needed another pool thread to cancel it.
- Product deadlines measured on the wall clock (`StreamingToolRunner`'s process timeout) in tests that were not about the deadline.

Setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` shrinks the pool locally and reproduced eight failures at `1086b65`: the five `StreamingToolRunner` tests, both Swift-task cancellation tests for the Digitizer and Indigo schedules, and `shutdownCancelsOwnedWorkAndDrainsItsCleanupBeforeReturning`. The EOF-deadline failure was not reproduced locally; its cause is inferred from the hosted log.

Changes:

- `Tests/ManzaneroTests/TestConcurrency.swift` adds `TestSignal` (wait for an event without holding a thread), the shared `ManualTestClock`, and `DedicatedThreadExecutor` with a `.dedicatedThread` trait that runs a test, or each test of a suite, on its own thread while staying inside its Swift task.
- Every spin-wait in the default suite now waits on a signal, with `.timeLimit(.minutes(1))` so a lost signal fails instead of hanging.
- The Digitizer and Indigo cancellation tests run their schedules as tasks that prefer a dedicated thread, so `Task.isCancelled` still reaches the C callback.
- Suites whose synchronous bodies block on sockets, C schedules or child processes run on dedicated threads.
- `StreamingToolRunner.run` takes an injectable clock (`ContinuousClock` by default, unchanged for callers). Its tests use a manual clock; the timeout test expires it only after the child has written output.

Swift Testing's `.serialized` trait was not used: it only orders tests within one suite and does not stop that suite from starving the others.

Remaining wall-clock checks are about real time: the child-process timeouts and their elapsed bounds in `StreamingToolRunner`, `ToolRunner` and recording tests, the socket transport deadlines (now on dedicated threads), and short "nothing happened yet" pauses that cannot fail because a runner is slow.

Product code still blocks pool threads: `ToolRunner` waits synchronously, and the native input, accessibility and media paths call blocking C functions that poll `Task.isCancelled`, all from `CommandService` on the cooperative pool. A long physical gesture or recording served over MCP therefore holds a pool thread for its whole duration. Moving that work onto dedicated executors is a larger design change and has not been made.
