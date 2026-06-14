# Headless Test Quarantine

The `AgentHubCore` test suite now runs headlessly (`./scripts/test.sh`). When it was
first wired up, tests failed or hung — none had ever run outside Xcode's Cmd+U.
They are temporarily disabled with `.disabled("headless-quarantine: …; see TestQuarantine.md")`
so the gate is green. **Each is a real follow-up**, grouped by root cause below. Re-enable
by removing the `.disabled(...)` trait once the underlying issue is fixed.

## CI gate status

CI (`.github/workflows/test.yml`) gates on the **fast `swift test` packages only**
(`AgentHubCLI`, `AgentHubGitHub`, `SimulatorPreview`, `Storybook`) — stable and ~5 min.

The **`AgentHubCore` suite is intentionally not run in CI**: it costs ~20 min just to
compile, has a flaky timing tail (clusters B/C below), and the runner's Xcode (16.2,
capped by macOS 14) differs from local dev (newer beta), so CI results diverge from what
developers see. It runs **locally** instead — agents run the targeted tests for any code
they change (CLAUDE.md / AGENTS.md), and `./scripts/test.sh` / `/test` runs it in full.

The quarantines below still matter for the **local** core suite (keep it green locally).
To put AgentHubCore back in CI as a real gate, harden the timing tests (injectable
clocks / deterministic awaits) so it's stable on slow runners, then add a core job.

How to run only these (to iterate): remove the trait and run
`cd app/modules/AgentHubCore && xcodebuild test -scheme AgentHubCore-Tests -destination 'platform=macOS' -test-timeouts-enabled YES -only-testing:<Target>/<SuiteType>/<method>`.

---

## A. Git subprocess deadlock on non-git paths (product concurrency bug) — HANG

`GitDiffService.runGitCommand` (`AgentHubGitDiff/Services/GitDiffService.swift:877`) spawns
`/usr/bin/git` and reads stdout/stderr via `Pipe()` + `readToEnd()` + `readGroup.wait()`.
Under **concurrent** spawning (parallel tests), pipe write-end FDs are inherited by sibling
git children, so `readToEnd()` never sees EOF until the unrelated children exit — the call
blocks until the 30s `gitCommandTimeout` fires. Raw `git rev-parse --show-toplevel` on a
non-git dir returns in 0.00s, so this is purely the Swift Process/pipe handling, not git.

**Fix direction:** set close-on-exec on the pipe FDs (or use `posix_spawn_file_actions`),
and/or fast-fail `findGitRoot` when libgit2 already reported "no repository" instead of
falling back to the CLI. Affects the whole app's git layer — review carefully.

- `DiffAvailabilityServiceTests` → "Non-git path is unavailable"
- `TerminalFileOpenProjectResolverTests` → `fallsBackToParentDirectoryWhenNoKnownRootContainsFile` — same git-Process deadlock; hangs on CI runners (60s timeout)
- (also the root cause behind `LocalDiffSummaryService`/`WebPreviewResolver` non-git slowness)

## B. Reactive/async delivery timing (test fragility, product-adjacent)

> **CI note:** most cluster-B timing tests are *flaky* (not deterministically broken) on the
> slow/contended CI runner — they pass locally and intermittently on CI. Because the
> `AgentHubCore` CI step is **advisory** (non-blocking), these don't gate merges; they're not
> all `.disabled` (only the chronic/hanging offenders are). Harden them (injectable clocks /
> deterministic awaits) and flip the core step to required.

These poll `waitUntil { … }` / `await condition()` for state that arrives via Combine
`.values` async sequences or real `Date.now`/sleep-based throttles. Values sent between
awaits get dropped, or the timing window is too tight under headless parallel load.

**Fix direction:** make delivery deterministic (await the publisher directly / inject a
clock / pump the run loop) rather than wall-clock polling. The `CLISessionsViewModel`
subscription is `setupSubscriptions()` at `CLISessionsViewModel.swift:1849` (`for await …
repositoriesPublisher.values`).

- `FocusedSessionLaunchTargetResolverTests` → "Preselect accepts a path inside a tracked worktree"
- `FocusedSessionLaunchTargetResolverTests` → "Preselect accepts a path inside a tracked main repository"
- `LazyBrowseSessionsLoadingTests` → "Idle repository changes still trigger Claude hook sync"
- `WebPreviewInspectorViewModelTests` → "Toolbar text edits do not mutate live preview without source text mapping"
- `WebPreviewInspectorViewModelTests` → "Font-size units stay detached and color picker writes CSS color values" — debounced-write timing, flaky on CI
- `WebPreviewInspectorViewModelTests` → "Toolbar edits are propagated to the live preview before the debounced write" — debounced-write timing, flaky on CI
- `WorktreeBranchNamingServiceTests` → "Explicit user cancellation stops naming without falling back" (also slow/hang)
- `GitWorktreeServiceTests` → "Cancels in-flight worktree creation and cleans up generated artifacts"
- `WorktreeManagementServiceTests` (AgentHubCLI) → "Cancels in-flight worktree creation and cleans generated artifacts" — passes locally, flaky on CI runners
- `DiffAvailabilityServiceTests` → "Fast evaluator keeps the minimum floor" (#379 throttle)
- `GitDiffServiceTests` → "fast evaluator keeps the minimum floor" (#379 throttle)
- `GitDiffServiceTests` → "invalidate succeeds after the adaptive window elapses" (#379 throttle)

## C. Temp-dir symlink path normalization

macOS temp dirs (`/var/folders/…`, `/tmp`) are symlinks to `/private/…`. Fixtures pass the
unresolved path; some product comparisons resolve symlinks and some don't, so prefix/equality
checks mismatch. `WorktreeModuleResolver.normalizedDirectoryPath` and
`CLISessionsViewModel.isProjectPath` do raw prefix matching without `resolvingSymlinksInPath()`.

**Fix direction:** resolve symlinks consistently (either normalize in the product path helpers,
or resolve fixture temp paths). Decide whether product code *should* canonicalize.

- `GitDiffServiceTests` → "branch changes are scoped to the selected worktree"
- `SpotlightProjectFileSearchServiceTests` → "Ranks Spotlight paths and filters directories and paths outside the project"
- `WorktreeSettingsInventoryTests` → "Delete worktree for nested session removes the worktree root" (may overlap with B)

## D. Deterministic product-vs-test drift / latent bugs (decide which side is right)

- `CodexTimestampParserTests` → "Returns nil for invalid timestamps" — **product bug**:
  the strict byte-parser rejects `2026-02-31`, but the `ISO8601DateFormatter` fallback
  (`CodexTimestampParser.swift`) leniently rolls it to Mar 3. Either reject in the fallback
  or relax the test.
- `EmbeddedTerminalLaunchBuilderTests` → 2 tests asserting `shellCommand.contains("/bin/sh")`,
  but the MCP-config JSON escapes slashes as `\/bin\/sh`. Test expectation is too literal
  (or the builder should encode with `.withoutEscapingSlashes`).
- `InlineEditStyleReconcilerTests` → "Forwards request fields…": system prompt no longer
  contains `"preserve the semantic change"`. Prompt text drifted vs the test.
- `SpotlightProjectFileSearchServiceTests` → "Escapes quoted query literals…": the
  backslash-escape branch in `SpotlightQueryBuilder.escapeQuotedString` appears unreachable
  because `\` is consumed as a path separator by the filename-component extraction first.
