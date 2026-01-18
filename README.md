# AgentHub

A macOS SwiftUI library for real-time monitoring and management of Claude Code CLI sessions.

## Prerequisites

- **macOS 14.0+**
- **[Claude Code CLI](https://claude.ai/claude-code)** installed and authenticated
- **Xcode 15+** (for integration)

## Installation

Add AgentHub to your Swift Package Manager dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/jamesrochabrun/AgentHub", from: "1.0.0")
]
```

Then add to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["AgentHub"]
)
```

## How It Works

### Session Discovery

AgentHub reads Claude Code session data from:

```
~/.claude/projects/{encoded-path}/{sessionId}.jsonl
```

Each session is a JSONL file containing message history, tool usage, and token metrics. AgentHub monitors these files in real-time using file system watchers.

### Claude CLI Integration

AgentHub can launch Claude Code sessions via Terminal:

- **Resume session:** `claude -r {sessionId}`
- **New session:** Opens Claude in a specified directory

## Integration

```swift
import AgentHub
import SwiftUI

@main
struct MyApp: App {
  @State private var provider = AgentHubProvider()

  var body: some Scene {
    WindowGroup {
      AgentHubSessionsView()
        .agentHub(provider)
    }
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra(
      isInserted: Binding(
        get: { provider.displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      AgentHubMenuBarContent()
        .environment(\.agentHub, provider)
    } label: {
      AgentHubMenuBarLabel(provider: provider)
    }
    .menuBarExtraStyle(.window)
  }
}
```

`AgentHubProvider` is the central service provider that:
- Creates and wires all services (monitor, stats, git)
- Configures the `ClaudeCodeClient` for Terminal integration
- Provides view models with proper dependency injection

The `AgentHubSessionsView` provides the complete UI - a split view with repository browser and session monitoring panel.

## User Experience

### Left Panel: Repository Browser

- Add repositories via folder picker (persisted in UserDefaults)
- Hierarchical tree showing:
  - Repositories
  - Git worktrees
  - Sessions (with branch, message count, last activity)
- Actions per session:
  - Monitor (watch real-time updates)
  - Resume (launch Terminal with `claude -r`)
  - Open new session
  - Copy session ID

### Right Panel: Monitoring Dashboard

- Active sessions with real-time metrics:
  - Token usage (input/output/cache)
  - Current status (thinking, executing tool, awaiting approval, idle)
  - Model and duration
  - Cost estimation
- Toggle monitoring per session

### Code Changes View

- Full-screen diff viewer for all file modifications
- Shows Edit, Write, and MultiEdit tool calls
- File-by-file navigation
- Unified/split diff rendering via PierreDiffsSwift

#### Inline Editor

Click any line in the diff view to open an inline editor. Type a question about that line and submit to resume the session in Terminal with your question as context.

**Requirements:** The inline editor requires `claudeClient` to be properly configured. Without it, line clicks are disabled since the editor needs the client to launch Terminal with the resumed session.

The client flows through:
```
AgentHubProvider.claudeClient
    → CLISessionsViewModel.claudeClient
    → MonitoringPanelView
    → MonitoringCardView
    → CodeChangesView
    → InlineEditorOverlay
```

### Worktree Management

- Create new git worktrees from the UI
- Select base branch, specify new branch name
- Automatic directory setup

### Notifications

- Alert sound when a tool awaits approval (configurable 5-second timeout)
- Visual status indicators

### Global Stats Display

AgentHub can display global Claude Code statistics (total tokens, cost, sessions across all repos) in two modes:

#### Menu Bar Mode (Default)

Stats appear as a menu bar extra in the system menu bar:

```swift
@main
struct YourApp: App {
  @State private var statsService = GlobalStatsService()
  @State private var displaySettings = StatsDisplaySettings() // defaults to .menuBar

  var body: some Scene {
    WindowGroup {
      ContentView(
        statsService: statsService,
        displaySettings: displaySettings
      )
    }

    MenuBarExtra(
      isInserted: Binding(
        get: { displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      GlobalStatsMenuView(service: statsService)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sparkle")
        Text(statsService.formattedTotalTokens)
      }
    }
    .menuBarExtraStyle(.window)
  }
}
```

#### Popover Mode

Stats appear as a toolbar button in the top-right corner of the app window:

```swift
@main
struct YourApp: App {
  @State private var statsService = GlobalStatsService()
  @State private var displaySettings = StatsDisplaySettings(defaultMode: .popover)

  var body: some Scene {
    WindowGroup {
      ContentView(
        statsService: statsService,
        displaySettings: displaySettings
      )
      .toolbar(removing: .title)
    }
  }
}

// In ContentView:
var body: some View {
  CLISessionsListView(viewModel: viewModel)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack {
          Spacer()
          if let settings = displaySettings,
             settings.isPopoverMode,
             let service = statsService {
            GlobalStatsPopoverButton(service: service)
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
}
```

#### Configuration

The display mode is controlled by `StatsDisplaySettings`:

```swift
// Menu bar mode (default)
let settings = StatsDisplaySettings()

// Popover mode
let settings = StatsDisplaySettings(defaultMode: .popover)
```

The setting persists via UserDefaults with key `"StatsDisplayMode"`.

## Session States

| Status | Description |
|--------|-------------|
| Thinking | Claude is processing |
| Executing Tool | Running a tool call |
| Awaiting Approval | Tool requires user confirmation |
| Waiting for User | Awaiting input |
| Idle | Session inactive |

## Dependencies

| Package | Purpose |
|---------|---------|
| ClaudeCodeSDK | Claude CLI configuration and launch |
| PierreDiffsSwift | Diff rendering |

## Architecture

```
AgentHub/
├── Models/           # Data structures (CLISession, SessionMonitorState)
├── Services/         # Core logic (file watching, parsing, git operations)
├── ViewModels/       # UI state management
├── UI/               # SwiftUI views
└── Utils/            # Git detection helpers
```

Key services:
- `CLISessionMonitorService` - Main orchestrator (Swift actor)
- `SessionFileWatcher` - Real-time JSONL file monitoring
- `GitWorktreeService` - Worktree creation/management
- `TerminalLauncher` - Claude CLI invocation

## License

MIT
