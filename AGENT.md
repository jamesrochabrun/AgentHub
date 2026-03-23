# AgentHub

Native macOS app for monitoring and managing Claude Code and Codex CLI sessions in real-time. Entirely local — no data leaves the machine.

## Tech Stack

- **Platform:** macOS 14.0+ / SwiftUI
- **Language:** Swift (Swift 6.0 tools version, `.v5` language mode)
- **State management:** `@Observable` macro — never use `ObservableObject`
- **Concurrency:** Swift actors, `async/await`, `Task`, `withTaskGroup`
- **Persistence:** UserDefaults (settings), SQLite via GRDB (session metadata)
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

## Code Style

- **Indentation:** 2 spaces (not tabs)
- Use `@Observable` macro — never `ObservableObject`
- Use `async/await` and actors — never completion handlers
- Services that do I/O are Swift actors (e.g., `CLISessionMonitorService`, `SessionFileWatcher`)
- Use `@MainActor` on ViewModels and UI-bound classes
- UserDefaults keys are namespaced under `com.agenthub.` (see `AgentHubDefaults`)

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

### Command Palette

`CommandPaletteView` — Cmd+K for quick session/repository/action access.

### Keyboard Shortcuts

Cmd+K (palette), Cmd+N (new session), Cmd+B (sidebar), Cmd+[/] (navigate sessions), Escape (dismiss).

## Dependencies

| Package | Purpose |
|---|---|
| ClaudeCodeSDK | Claude Code CLI integration |
| PierreDiffsSwift | Split-pane diff rendering |
| SwiftTerm (local fork) | PTY terminal emulation |
| swift-markdown-ui | Markdown rendering |
| GRDB.swift | SQLite ORM for session metadata |
| HighlightSwift | Syntax highlighting |
| Yams | YAML parsing for themes |
| Sparkle | Auto-updates with EdDSA verification |

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
- Session metadata DB: managed by `SessionMetadataStore` via GRDB

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
