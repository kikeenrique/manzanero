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

The first run on the `xcode-27` image ([run 43703221214](https://github.com/kikeenrique/manzanero/actions/runs/43703221214), at `54c08c3`) passed every starvation-sensitive test but failed two recording tests, `recordingTimerStartsAfterFirstFrameAndWaitsForFinalization` and `ignoredInterruptCannotHangFinalization`. Both gave their `/usr/bin/python3` fixture a 2 s startup deadline and both hit it (3.26 s and 3.39 s, which is the startup deadline plus each test's finalization wait). `/usr/bin/python3` is an xcrun shim. On that fresh image the toolchain shims were cold: `xcodebuild -version` and `swift --version` each took about 4 s in the "Record toolchain" step. Warm, the shim starts in tens of milliseconds locally, so the failure was not reproduced and its cause is inferred from the log. Both tests now keep the 30 s default for every deadline they do not test. The success path still finishes as soon as the fixture reports its marker or exits. `missingFirstFrameTimesOutAndStopsChild` keeps its 0.1 s startup deadline because a slow launch fails it the expected way.

Swift Testing's `.serialized` trait was not used: it only orders tests within one suite and does not stop that suite from starving the others.

Remaining wall-clock checks are about real time: the child-process timeouts and their elapsed bounds in `StreamingToolRunner`, `ToolRunner` and recording tests, the socket transport deadlines (now on dedicated threads), and short "nothing happened yet" pauses that cannot fail because a runner is slow.

Product code still blocks pool threads: `ToolRunner` waits synchronously, and the native input, accessibility and media paths call blocking C functions that poll `Task.isCancelled`, all from `CommandService` on the cooperative pool. A long physical gesture or recording served over MCP therefore holds a pool thread for its whole duration. Moving that work onto dedicated executors is a larger design change and has not been made.

## Toolchain on hosted runners

The earlier workflows selected `/Applications/Xcode_26.6.app` on `macos-26`; hosted logs recorded Xcode 26.6 (17F113) and Apple Swift 6.3.3 on image `macos-26-arm64` 20261102.0473.1. That image's [inventory](https://github.com/actions/runner-images/blob/macos-26-arm64/20261102.0473/images/macos/macos-26-arm64-Readme.md) lists Xcode 26.0.1 through 26.6 only.

Xcode 27.2 (27B52, the local toolchain) is installed at `/Applications/Xcode_27.2.app` on the `xcode-27` image ([inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), release `xcode-27-arm64/20261104.0337` and the newer prerelease `20261112.0361`). That image is a GitHub [preview](https://github.com/actions/runner-images/issues/14404): its default Xcode is 27.1 and queueing can be slower. Both workflows now run on `xcode-27` and select the 27.2 path explicitly; `xcode-select` fails the job if the path disappears. `.github/actionlint.yaml` declares the label, which actionlint's built-in list does not know yet.

Other observations from the hosted logs, not changed:

- `actions/cache` saves only when the job succeeds, so while CI was red every run started without SwiftPM or build caches.
- Debug and release build caches are keyed by commit, so every green push stores a new full `.build`; the repository cache quota will evict older entries.
- `brew install xcsift` is unpinned. A formatter release can change parsing or summaries without a repository change.
- The build and test tasks report warnings but do not fail on them.
