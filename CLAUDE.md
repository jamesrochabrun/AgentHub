# AgentHub

Native macOS app for monitoring and managing Claude Code and Codex CLI sessions in real-time. Entirely local — no data leaves the machine.

## Tech Stack

- **Platform:** macOS 14.0+ / SwiftUI
- **Language:** Swift (Swift 6.0 tools version, `.v5` language mode)
- **State management:** `@Observable` macro — never use `ObservableObject`
- **Concurrency:** Swift actors, `async/await`, `Task`, `withTaskGroup`
- **Persistence:** UserDefaults (app/UI preferences only), SQLite via GRDB (`SessionMetadataStore` for session/workspace state)
- **File watching:** kqueue-based `DispatchSource` — no polling

## Project Structure

```
app/
  AgentHub/                    # App target (entry point, AppDelegate, ContentView)
  modules/
    AgentHubCore/              # Swift Package — all core logic lives here
      Sources/AgentHub/
        Configuration/         # AgentHubProvider, AgentHubConfiguration, environment keys
        Design/                # Theme system (ThemeManager, ThemeFileWatcher, YAML themes)
        Intelligence/          # Smart mode / AI orchestration (IntelligenceViewModel)
        Models/                # CLISession, SessionMonitorState, SessionStatus, etc.
        Services/              # File watchers, parsers, git, search, stats, metadata store
        UI/                    # All SwiftUI views
        Utils/                 # Helpers, extensions, constants
        ViewModels/            # CLISessionsViewModel, MultiSessionLaunchViewModel, etc.
  AgentHubTests/
  AgentHubUITests/
```

## Architecture

### Data Flow

```
~/.claude/projects/{encoded-path}/{sessionId}.jsonl   (Claude sessions)
~/.codex/sessions/{date-path}/                        (Codex sessions)
    → SessionFileWatcher (kqueue DispatchSource, byte-offset incremental reads)
    → SessionJSONLParser (parses JSONL lines into structured state)
    → SessionMonitorState (published via Combine)
    → CLISessionsViewModel (@MainActor, drives UI)
    → SwiftUI Views (MonitoringCardView, etc.)
```

### Provider Abstraction

Both Claude and Codex are supported through shared protocols:

- `SessionMonitorServiceProtocol` — session discovery and repository management
- `SessionFileWatcherProtocol` — real-time file monitoring with state publishing
- `SessionSearchServiceProtocol` — full-text search across sessions

Concrete implementations: `CLISessionMonitorService` / `CodexSessionMonitorService`, `SessionFileWatcher` / `CodexSessionFileWatcher`.

### Environment Injection

`AgentHubProvider` is the central service locator, injected via SwiftUI environment:
```swift
.environment(\.agentHub, provider)
```
`AgentHubModifier` also injects: `statsService`, `displaySettings`, `themeManager`, `runtimeTheme`.

### Key Models

- `CLISession` — Core session entity (id, projectPath, branchName, isWorktree, status, messages)
- `SessionMonitorState` — Real-time state: status, token counts, tool calls, pending approvals
- `SessionStatus` — Enum: `.thinking`, `.executingTool(name:)`, `.waitingForUser`, `.awaitingApproval(tool:)`, `.idle`
- `SelectedRepository` / `CLISessionGroup` / `WorktreeBranch` — Hierarchical grouping
- `OrchestrationPlan` / `OrchestrationSession` — AI-generated parallel task plans

### Key ViewModels

- `CLISessionsViewModel` — Main ViewModel (~1,950 lines), manages all session state, selection, monitoring
- `MultiSessionLaunchViewModel` — Parallel session launcher (manual + smart mode)
- `IntelligenceViewModel` — Calls Claude Code SDK to generate orchestration plans

## Services & Testability

### Protocol-Driven Services

All services must be defined as **protocols (interfaces)** first, with concrete implementations separate. This enables easy mocking and unit testing.

```swift
// Define the interface
protocol SessionMonitorServiceProtocol {
  func discoverSessions(in directory: URL) async throws -> [CLISession]
  func startMonitoring(session: CLISession) async
}

// Concrete implementation
actor CLISessionMonitorService: SessionMonitorServiceProtocol { ... }

// Test mock
final class MockSessionMonitorService: SessionMonitorServiceProtocol { ... }
```

- Every service must have a corresponding protocol — never depend on concrete types directly
- ViewModels and other consumers receive services via protocol types, not implementations
- Use `AgentHubProvider` to wire concrete implementations; tests substitute mocks
- Actors implement protocols for thread-safe I/O services; mocks can be simple classes

### Testing Requirements

- All services and ViewModels **must have unit tests** — code must be well tested
- Use protocol-based mocks to isolate units under test
- Test files live in `AgentHubTests/` and mirror the source structure
- Cover critical paths: session discovery, JSONL parsing, state transitions, file watching lifecycle
- Use `async` test methods for testing actor-based services
- Prefer deterministic tests — inject controlled data rather than relying on file system state

### Database Migration Rules

- Session/workspace management state belongs in `SessionMetadataStore` / SQLite, not UserDefaults.
- Do not add `AgentHubDefaults` keys for selected repositories, monitored session IDs, session restore state, repo mappings, terminal workspace state, or terminal/dev-server process cleanup state.
- `managed_processes` is the SQLite authority for app-spawned terminal/dev-server cleanup. Store only process identity/routing metadata needed for cleanup (PID, process group, process start time, kind/provider/session/project context), never prompts, full environment, terminal contents, or other sensitive runtime payloads.
- Never edit, rename, reorder, or delete existing `DatabaseMigrator` migrations. Add a new `vN_*` migration for every schema change.
- Treat the ordered `vN_*` migration identifiers in `SessionMetadataStore` as table versioning. Do not add ad hoc per-table schema version columns unless a table-specific encoded payload requires one.
- Production migrations must preserve existing rows. Do not use broad `delete`, `drop table`, `clearAll()`, or `eraseDatabaseOnSchemaChange` in migrations.
- Any `SessionMetadataStore` schema change must add or update migration-preservation tests that seed the current baseline database and verify all existing metadata still reads back after migration.
- Process cleanup must verify persisted PID identity before terminating. If PID start time/process group no longer matches the row, delete the stale row without killing.
- Process group cleanup is only allowed for groups AgentHub owns. Persist/use a process group only when the child is its own group leader (`pgid == pid`); inherited PGIDs must fall back to PID-only termination.
- Keep launch/crash-recovery cleanup broad, but user-triggered orphan cleanup must be scoped to inactive terminal rows for the relevant provider/PIDs. It must not sweep dev-server rows or active terminals.

## SwiftUI View Guidelines

### Composability

- Views should be **small, focused, and composable** — each view does one thing well
- When a view body exceeds ~40–50 lines, break it into smaller **extracted subviews**
- Prefer creating dedicated component views over using large inline closures

```swift
// Prefer this:
struct MonitoringCardView: View {
  var body: some View {
    VStack {
      StatusHeaderView(status: status)
      ContextWindowBar(usage: usage)
      ToolActivityFeed(tools: tools)
    }
  }
}

// Avoid this: one massive body with hundreds of lines
```

### View Patterns

- Extract repeated UI patterns into reusable components (e.g., `StatusBadge`, `SectionHeader`)
- Use `ViewModifier` for shared styling and behavior (e.g., card backgrounds, hover effects)
- Keep view logic minimal — delegate business logic to ViewModels
- Use `@Environment` for injecting shared dependencies, not init parameters passed through many layers
- Prefer value types (`struct`) for views — never use classes for SwiftUI views
- Use `@Binding` for two-way data flow between parent and child views
- Use descriptive view names that reflect their purpose (e.g., `SessionStatusIndicator`, not `StatusView`)

## Code Style

- **Indentation:** 2 spaces (not tabs)
- Use `@Observable` macro — never `ObservableObject`
- Use `async/await` and actors — never completion handlers
- Services that do I/O are Swift actors (e.g., `CLISessionMonitorService`, `SessionFileWatcher`)
- Use `@MainActor` on ViewModels and UI-bound classes
- UserDefaults preference keys are namespaced under `com.agenthub.` (see `AgentHubDefaults`)

## UI/UX Patterns

### Navigation

`NavigationSplitView` with sidebar + detail. Sidebar shows repository tree with sessions grouped by worktree branch.

### Hub Layouts

Four monitoring panel layouts: Single, List, 2-Column, 3-Column grid. Persisted via `@AppStorage`.

### Session Cards

Each `MonitoringCardView` shows:
- Status indicator (thinking/executing/waiting/idle)
- Context window usage bar
- Tool activity feed
- Toggle between Monitor mode (live readout) and Terminal mode (embedded PTY via SwiftTerm)
- Can be maximized to full panel (Escape to restore)

### Side Panels

In Single layout, a side panel can show: `GitDiffView` (split-pane diff), `PlanView` (markdown), `WebPreviewView` (WKWebView), `PendingChangesView`.

### Web Preview Precedence

- Prefer agent-provided localhost URLs when a session exposes one
- If monitor state is still catching up, recover the latest localhost URL from the session JSONL file before choosing a static preview
- If that external localhost preview fails to load, fall back to static HTML: root `index.html` first, then other discovered HTML files
- Changes to this behavior require unit tests

### Storybook Mode

When a project has Storybook configured, the Preview button is replaced with a Storybook button — never both. Routing is gated by `WebPreviewMode { .app, .storybook }`; the storybook server runs under the compound `DevServerManager` key `"{sessionId}:storybook"` alongside the primary app server. Detection lives in the standalone `Storybook` Swift module (`app/modules/Storybook/`, pure Foundation). See **Storybook** in `README.md` for detection rules, script-port handling, and the prompt auto-accept.

### Command Palette

`CommandPaletteView` — Cmd+K for quick session/repository/action access.

### Keyboard Shortcuts

Cmd+K (palette), Cmd+N (new session), Cmd+B (sidebar), Cmd+[/] (navigate sessions), Cmd+\ (toggle focus mode), Escape (dismiss).

## Dependencies

| Package | Purpose |
|---|---|
| Canvas | Web preview element inspection and prompt/context capture |
| ClaudeCodeSDK | Claude Code CLI integration |
| PierreDiffsSwift | Split-pane diff rendering |
| SwiftTerm (local fork) | PTY terminal emulation |
| swift-markdown-ui | Markdown rendering |
| GRDB.swift | SQLite ORM for session metadata |
| HighlightSwift | Syntax highlighting |
| Yams | YAML parsing for themes |
| Sparkle | Auto-updates with EdDSA verification |

## Terminal Enhancements

The embedded terminal uses a fork of SwiftTerm (`jamesrochabrun/SwiftTerm`, branch `agenthub`) with modular additions in `Sources/SwiftTerm/AgentHub/`. All new code lives in that directory to minimize merge conflicts with upstream.

### Features

| Feature | Shortcut | Description |
|---------|----------|-------------|
| **Search** | `Cmd+F` | Built-in find bar with regex, case-sensitive, whole-word toggles |
| **Cmd+Click URLs** | `Cmd+Click` | Opens plain URLs in browser (no OSC 8 required) |
| **Cmd+Click file paths** | `Cmd+Click` | Opens file in inline Files panel (configurable: AgentHub / VS Code / Xcode) |
| **Theme integration** | Automatic | Terminal background and cursor follow active YAML theme (dark mode) |
| **OSC 133 tracking** | — | Semantic prompt boundary tracking (foundation for future features) |

### Fork Architecture

- **Branch:** `agenthub` — all additions live here; `main` tracks upstream
- **New files:** `Sources/SwiftTerm/AgentHub/` — PlainURLDetection, FilePathDetection, SemanticPromptTracker, MarkStore, SmartSelectionEngine
- **Upstream changes:** Minimal — `cellDimension` and `displayBuffer` exposed as public, `requestOpenFile` delegate added
- **Merge upstream:** `git fetch upstream && git merge upstream/main` into `agenthub`

### Settings

- **Open files with** — Choose AgentHub (inline), VS Code, or Xcode for Cmd+Click file paths
- **Terminal colors** — YAML themes can define `terminal.background` and `terminal.cursor` hex colors

## Common Commands

```bash
# Build (via Xcode)
xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub build

# Run tests
xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub test
```

## Session Data Paths

- Claude sessions: `~/.claude/projects/{encoded-path}/{sessionId}.jsonl`
- Claude history: `~/.claude/history.jsonl`
- Claude stats: `~/.claude/stats-cache.json`
- Codex sessions: `~/.codex/sessions/{date-path}/`
- Codex history: `~/.codex/history.jsonl`
- Custom themes: `~/Library/Application Support/AgentHub/Themes/`
- Approval hook script: `~/Library/Application Support/AgentHub/hooks/agenthub-approval.sh`
- Approval sidecars: `~/Library/Application Support/AgentHub/approvals/{sessionId}.jsonl`
- Session claims: `~/Library/Application Support/AgentHub/claims/{sessionId}`
- Session metadata/workspace DB: managed by `SessionMetadataStore` via GRDB

## Approval Detection (Claude only)

Claude Code buffers `tool_use` blocks until the turn commits, so JSONL alone can't surface pending approvals during the prompt. A `PreToolUse` hook writes to a sidecar directory we watch; JSONL stays primary and the hook fills the gap. Codex has no equivalent mechanism — `CodexSessionFileWatcher` hardcodes `pendingToolUse: nil`.

- `ClaudeHookInstaller` — writes our hook entry into `{project}/.claude/settings.local.json`. Driven by the repositories subscription (Claude Code reads settings once at session start). Preserves every other key and every non-AgentHub hook entry.
- `ClaudeHookSidecarWatcher` — per-session kqueue watcher over `approvals/`, merges into `ParseResult.pendingToolUses` at `buildMonitorState`.
- `ApprovalClaimStore` — claim markers gate the script so external Terminal sessions in tracked worktrees are silent no-ops.
- `HookPendingStalenessFilter` — drops hook entries that JSONL has already moved past (100ms epsilon).

**Invariants when editing this area:** only `.claude/settings.local.json` is ever written inside a user's repo (never `.claude/hooks/`, never `.gitignore`); our merge identifies its own entry by the absolute script path; launch reconcile and terminate flush both block on a semaphore so AppKit can't kill cleanup mid-flight.

## Important Patterns

- File watchers use byte-offset tracking to read only new JSONL lines (never re-read entire files)
- Combine publishers bridge actor-isolated services to `@MainActor` ViewModels
- `Task.detached` is used for file I/O off the actor's isolation context
- `withTaskGroup` for parallel worktree detection and metadata reading
- Terminal PTY state is preserved across pending-to-real session transitions
- `TerminalProcessRegistry` tracks child PIDs for cleanup on app termination
- Theme system: built-in themes (Claude, Codex, Bat, Xcode) + YAML hot-reload via `ThemeFileWatcher`
- Approval notifications: `ApprovalNotificationService` sends macOS alerts when tools await confirmation

## Git Commits

- Never add "Co-Authored-By: Claude" or any Claude co-author line
