# AgentHub — Agent Guidelines

## Architecture Overview

AgentHub is a native macOS app (SwiftUI, Swift 6.0 tools / `.v5` language mode) that monitors and manages Claude Code and Codex CLI sessions in real-time. Everything runs locally — no data leaves the machine.

### Core Architecture Principles

1. **Protocol-driven services** — Every service is defined as a protocol. Concrete implementations are injected via `AgentHubProvider`. This enables mocking and testability throughout the codebase.
2. **Actor isolation for I/O** — Services performing file or network I/O are Swift actors, ensuring thread safety without manual locking.
3. **@Observable for state** — All observable state uses the `@Observable` macro. Never use `ObservableObject` or `@Published`.
4. **@MainActor ViewModels** — ViewModels are `@MainActor`-isolated and drive the UI layer via SwiftUI bindings.
5. **Composable views** — SwiftUI views are small, focused components. Large views are broken into extracted subviews.

### Data Flow

```
JSONL session files on disk
  → SessionFileWatcher (kqueue DispatchSource, incremental byte-offset reads)
  → SessionJSONLParser (structured state from raw lines)
  → SessionMonitorState (Combine publisher)
  → CLISessionsViewModel (@MainActor, drives UI)
  → SwiftUI Views (composable components)
```

### Provider Abstraction

Claude and Codex are supported through shared protocols:

- `SessionMonitorServiceProtocol` — session discovery and repo management
- `SessionFileWatcherProtocol` — real-time file monitoring
- `SessionSearchServiceProtocol` — full-text search

Concrete types: `CLISessionMonitorService` / `CodexSessionMonitorService`, `SessionFileWatcher` / `CodexSessionFileWatcher`.

## Service Design Rules

- **Always define a protocol first** — never depend on concrete service types directly
- ViewModels and other consumers receive dependencies as protocol types
- `AgentHubProvider` is the service locator; tests substitute mock implementations
- Actors implement protocols for thread-safe I/O; mocks can be plain classes

## CLI Launch & Persistence Invariants

- Read `AccessorySessions.md` before editing accessory terminal panes, sub-session launch/detection, terminal workspace linked-session restore, or `session_relationships`.
- AI override flags are applied only when starting a new CLI session, never when resuming an existing one
- AgentHub-created worktrees live as sibling directories beside the main repository. Do not create a repo-local `.worktrees` folder or add `.worktrees/` to `.git/info/exclude`.
- Worktree Git roots stay at the repository root. For monorepos, do not try to create `ios`/`android` subdirectory Git roots; launch agents from the requested subdirectory inside the repo-root worktree instead.
- Preserve the distinction between `worktree.path` and `launchPath`: register, group, delete, and clean up using the worktree root; start the embedded terminal and detect pending session files using the launch path when one is provided.
- Sparse agent worktree creation is the default for launched agent worktrees that start from a tracked subdirectory. Infer the sparse owner path from project markers near the launch path, keep repo-root starts as full checkouts unless sparse was explicitly requested, and use `fullCheckout` only when the whole repository must be materialized.
- Sparse profiles must be installed before checkout materialization and must not break repo hooks. Keep shared support paths such as `.agents`, `.claude`, `.claude-plugin`, `scripts/git_hooks_support`, and `scripts/git_support` in inferred or explicit agent profiles when those paths exist.
- Never disable sparse checkout as an expansion strategy. Add paths with `git sparse-checkout add -- <path>` or route through the shared expansion helper when one exists.
- Empty or unsupported saved provider settings must fall back to the CLI's own defaults instead of emitting override flags
- UserDefaults is only for app/UI preferences. Session/workspace management state must live in SQLite via `SessionMetadataStore`.
- Never add `AgentHubDefaults` keys for selected repositories, monitored session IDs, session restore state, repo mappings, terminal workspace state, or terminal/dev-server process cleanup state.
- `managed_processes` is the SQLite authority for app-spawned terminal/dev-server cleanup. Process rows must store only process identity/routing metadata needed for cleanup (PID, process group, process start time, kind/provider/session/project context), never prompts, full environment, terminal contents, or other sensitive runtime payloads.
- Schema changes must append a new `DatabaseMigrator` migration. Never edit, rename, reorder, or delete existing migration identifiers or bodies.
- Table versions are the ordered `vN_*` migration identifiers in `SessionMetadataStore`; do not add ad hoc per-table schema version columns unless a table-specific encoded payload requires one.
- Production migrations must be additive or explicit data transforms. Do not use broad `delete`, `drop table`, `clearAll()`, or `eraseDatabaseOnSchemaChange` in app migrations.
- Every `SessionMetadataStore` schema change must include a migration-preservation test that seeds the current baseline DB and proves existing rows survive migration.
- Process cleanup must verify persisted PID identity before terminating. If PID start time/process group no longer matches the row, delete the stale row without killing.
- Process group cleanup is only allowed for groups AgentHub owns. Persist/use a process group only when the child is its own group leader (`pgid == pid`); inherited PGIDs must fall back to PID-only termination.
- Keep launch/crash-recovery cleanup broad, but user-triggered orphan cleanup must be scoped to inactive terminal rows for the relevant provider/PIDs. It must not sweep dev-server rows or active terminals.

```swift
protocol SessionSearchServiceProtocol {
  func search(query: String, in sessions: [CLISession]) async -> [SearchResult]
}
```

## Testing Requirements

- All services and ViewModels **must have unit tests**
- Use protocol-based mocks to isolate the unit under test
- Tests live in `AgentHubTests/` mirroring the source structure
- Use `async` test methods for actor-based services
- Prefer deterministic tests — inject controlled data, don't depend on filesystem state
- Cover critical paths: session discovery, JSONL parsing, state transitions, file watcher lifecycle

### Running tests (headless)

**MANDATORY: whenever you change app code under any `Sources/`, run the _targeted_ tests for the
affected area before finishing, and report real pass/fail.** "It builds" is not evidence a test
passes. Don't run the whole suite for every edit — target what you touched; run the full suite only
before a PR. There is intentionally **no** git pre-commit/pre-push hook; running tests is the agent's
responsibility.

- **Targeted (on code changes):** map source → test (`Services/GitDiffService.swift` →
  `GitDiffServiceTests`) and run only that:
  - Core: `cd app/modules/AgentHubCore && xcodebuild test -scheme AgentHubCore-Tests -destination 'platform=macOS' -test-timeouts-enabled YES -skipPackagePluginValidation -only-testing:AgentHubTests/<SuiteType>` (`<SuiteType>` = the test `struct` name).
  - Sub-module (`AgentHubGitHub`, `Storybook`, `SimulatorPreview`, `AgentHubCLI`): `cd app/modules/<Module> && swift test --filter <TestName>`.
- **Full gate (before a PR, or `/test`):** `./scripts/test.sh`. **CI
  (`.github/workflows/test.yml`) gates on the fast packages only** — the `AgentHubCore` suite runs
  locally, not in CI (slow + timing-flaky on CI's older Xcode; see `TestQuarantine.md`), so running
  it locally on your changes matters. `swift test` on `AgentHubCore` does **not** work
  (CodeEditSymbols xcassets); use the script / the `AgentHubCore-Tests` scheme.
- swift-testing runs `@Test`s in parallel **off the main thread** — AppKit-touching suites must be `@MainActor`.
- Quarantined tests (`.disabled("headless-quarantine: …")`) are known-broken, not passing — see
  `TestQuarantine.md` / issue #380; don't re-enable without fixing the root cause.

## Web Preview Behavior

- Prefer agent-provided localhost URLs for web preview when available
- If monitor state has not populated yet, recover the latest localhost URL directly from the session JSONL file before falling back to static preview
- If an agent-provided localhost preview fails to load, fall back to static HTML in this order: root `index.html`, then other discovered HTML files
- Changes to web preview precedence or fallback behavior must include unit tests

## Global Session Panel

The floating global Sessions panel lives in the reusable `AgentHubGlobalSessionPanel` Swift module (`app/modules/AgentHubCore/Sources/AgentHubGlobalSessionPanel`). Keep panel UI, AppKit presenter code, keyboard navigation, sorting, and cleanup-suggestion logic in that module.

- `AgentHubCore` owns shared contracts only: hotkey registration, `GlobalSessionControlPanelCoordinator`, `GlobalSessionControlPanelPresenting`, and `GlobalSessionSelectionRouter`.
- The app target injects the concrete `AppKitGlobalSessionControlPanelPresenter` through `AgentHubProvider`'s presenter factory.
- Do not move panel SwiftUI/AppKit implementation back into `AgentHubCore`; avoid Core importing `AgentHubGlobalSessionPanel`, which would create a module cycle.
- Changes to panel ordering, navigation, or cleanup suggestions belong in `AgentHubGlobalSessionPanelTests`.

## MCP UI

AgentHub has MCP UI support wired through the reusable `AgentHubMCPUI` Swift module (`app/modules/AgentHubCore/Sources/AgentHubMCPUI`). Use this module for MCP app resources and rendering instead of creating feature-local WKWebView wrappers or duplicate MIME/resource models.

- MCP UI resources use `AgentHubMCPUIResource` with the app MIME profile `text/html;profile=mcp-app`.
- Render in-app MCP UI HTML with `AgentHubMCPUIResourceView` / `AgentHubMCPUIWebView`.
- Put feature-specific resource builders in the owning feature/module, but have them emit `AgentHubMCPUIResource`.
- Escape generated HTML text with `AgentHubMCPUIHTML.escape(_:)`.

### MCP Apps (agent-driven rendering)

AgentHub renders MCP app UIs an agent produces during a Claude or Codex session in a dedicated side panel, driven by the agent's tool calls (no proactive server discovery). Read **`MCPApps.md`** before editing MCP app detection (`detectedMCPAppInvocations`/`detectedMCPAppResources` in the parsers), resolution (`CLISessionsViewModel.ensureMCPAppRenderItems`), rendering (`MCPAppSidePanelView`), the on-demand gateway (`MCPAppDiscoveryService`), or the bridge push in `AgentHubMCPUIResourceView`. `MCPApps.md` documents the current state and remaining gaps.

### Storybook Mode

Storybook-enabled projects swap the Preview button for a Storybook button (never both). `WebPreviewMode { .app, .storybook }` routes the preview pane; the storybook server runs at compound key `"{sessionId}:storybook"` in `DevServerManager` so it coexists with the primary app server. Read **Storybook** in `README.md` before editing this area.

## Simulator Preview

Read `SimulatorPreview.md` before editing the live simulator preview module, `SimulatorPreviewSidePanelView`, the `.simulator` side-panel route, `onShowSimulatorPreview` callbacks, `AgentHubProvider.simulatorStreamService`, anything named `HotReload*`, `PreviewHost*`, or `SimulatorHotReloadController`.

The panel mirrors and controls an iOS Simulator in-app, supports element-aware annotation pins, and can arm hot reload plus the Previews tab by inserting generated support dylibs at launch. Preserve the documented invariants: no host Screen Recording/Accessibility prompts, no network exposure beyond loopback preview-host access, no writes into the user's repo, truthful hot-reload pill states, `simctl launch --stdout` instead of `--console-pty`, and never inserting SnapshotPreviews' stock `Snapshotting` dylib beside the live mirror.

## GitHub PR/CI Observation

Read `GitHubMonitor.md` before editing GitHub PR/check observation, session-row GitHub state, GitHub panel refresh behavior, or related tests.

Key invariants:

- Shared GitHub PR/check observation lives in `AgentHubGitHub` behind `GitHubPRObservationServiceProtocol`; UI code should consume the protocol rather than starting per-view polling loops.
- `AgentHubProvider.gitHubPRObservationService` is the shared service used by the GitHub panel, monitoring cards, and side-panel session rows.
- Session rows must stay quiet when the current branch has no PR. Only render compact row GitHub state when a `currentBranchPR` exists.
- Preserve launch performance: initial GitHub refresh work must remain delayed, bounded, activity-driven, or manually triggered.
- Keep no-PR CLI output non-fatal. GitHub CLI's "no pull requests found for branch ..." response maps to a nil PR, not a row-level error.
- Changes to polling cadence, target deduplication, no-PR parsing, row visibility, or refresh behavior need focused unit tests in `AgentHubGitHubTests` or matching UI/view-model tests.

## Git Diff Loading (performance)

`AgentHubGitDiff` has two backends: **libgit2** (`LibGit2DiffBackend`, default, faster on normal repos) and **native git** (`GitDiffService.nativeChangedFiles`, used only for `.unstaged`/`.staged` listing on large worktrees where libgit2's single-threaded `git_diff_index_to_workdir` is far slower). Invariants:

- Route `.unstaged`/`.staged` listing to native git only when `.git/index > GitDiffService.defaultLargeWorktreeIndexByteThreshold` (~4 MB). Threshold is injectable via `init`; tests force the gate with `largeWorktreeIndexByteThreshold: 0`. Small repos keep libgit2.
- **Never gate `.branch`** — libgit2 tree↔tree is already fast.
- The native list path must match libgit2 output (status, renames, line counts) — covered by the parity test; keep it green.
- Probe modes cheap-first (`branch → staged → unstaged`) in `GitDiffView` auto-select and `DiffAvailabilityService`; `DiffMode` declaration order drives both `allCases` and the picker tab order.
- Do **not** write `core.untrackedCache`/`core.fsmonitor` to the user's repo — measured as a no-op on actively-modified worktrees and it mutates user repo state.
- Benchmark with `swift run --package-path app/modules/AgentHubCore -c release DiffBench [path]` (`DiffBench` target; not shipped).

## Claude Code Approval Hook Invariants

AgentHub installs Claude Code hooks to surface pending approvals in real time (see `CLAUDE.md` → "Approval Detection"). `PermissionRequest` is the only hook event that represents a real pending approval; `PreToolUse` is only an observed tool/mode signal used to track dynamic permission-mode changes. When modifying `ClaudeHookInstaller`, `ClaudeHookSidecarWatcher`, `SessionFileWatcher`, `ApprovalClaimStore`, or `HookPendingStalenessFilter`, these invariants must hold:

- The **only** file written inside a user's repo is `{project}/.claude/settings.local.json`. Never create files under `.claude/hooks/`, never touch `.claude/settings.json`, never modify `.gitignore`.
- Merge must preserve every unrelated key and every non-AgentHub hook entry. Our entry is identified by the absolute path to the shared script.
- The hook script stays claim-gated so external Terminal sessions in tracked worktrees remain silent no-ops.
- `auto` and bypass permission modes must suppress `pendingToolUse`, `awaitingApproval`, and approval notifications, including when the mode changes mid-session.
- Install is driven by the repositories subscription, not per-session — Claude Code reads `settings.local.json` once at session start.
- Launch reconcile and terminate flush must run synchronously (blocking `applicationDidFinishLaunching` / `applicationWillTerminate` via semaphore) so AppKit can't kill cleanup mid-flight.

## SwiftUI View Guidelines

- Views must be **small, focused, and composable** — one responsibility per view
- When a view body exceeds ~40–50 lines, extract subviews into dedicated structs
- Extract repeated patterns into reusable components (e.g., `StatusBadge`, `SectionHeader`)
- Use `ViewModifier` for shared styling and behavior
- Keep business logic in ViewModels — views handle layout and presentation only
- Use `@Environment` for shared dependencies; avoid passing services through many init layers
- Use `@Binding` for two-way parent-child data flow
- Name views descriptively: `SessionStatusIndicator` not `StatusView`

## Code Style

- 2-space indentation (no tabs)
- `@Observable` macro — never `ObservableObject`
- `async/await` and actors — never completion handlers
- `@MainActor` on ViewModels and UI-bound classes
- UserDefaults preference keys namespaced under `com.agenthub.`

## Git Commits

- Never add "Co-Authored-By: Claude" or any Claude co-author line
