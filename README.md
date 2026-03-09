# AgentHub

A native macOS app for managing Claude Code and Codex CLI sessions. Monitor sessions in real-time, run multiple terminals in parallel, preview diffs, create worktrees, launch multi-provider sessions, and more — all from a single hub.

<img width="1913" height="1079" alt="Hub" src="https://github.com/user-attachments/assets/99518d02-8ca6-458a-900c-bfd1f4e57419" />

Full screen mode

https://github.com/user-attachments/assets/c616c904-d165-4516-8478-afb810c13606

Custom Theme

https://github.com/user-attachments/assets/d4462101-a42b-446c-8491-9a4344539ac6

Shortcuts 

https://github.com/user-attachments/assets/ee453a78-e417-488a-96c7-20732d1d1f60

## Features

- **Multi-provider support** — Monitor and launch Claude Code and Codex sessions side by side
- **Real-time session monitoring** — Watch all sessions update live via file-system watchers (no polling)
- **Embedded terminal** — Full PTY terminal (SwiftTerm) inside each monitoring card; resume or start sessions without leaving the app
- **Hub panel** — Unified view of all sessions across providers with single, list, 2-column, and 3-column grid layouts
- **Resizable list cards** — In list mode, monitoring cards can be resized with a preview guide for a smoother, less distracting resize experience
- **Inline diff review** — Full split-pane diff view with inline editor to send change requests directly to Claude
- **Git worktree management** — Create and delete worktrees from the UI; launch sessions on new branches
- **Remix with provider picker** — Branch any session into an isolated git worktree and continue it in Claude or Codex; the original session's transcript is passed as context to the new session
- **Multi-session launcher** — Launch parallel sessions across Claude and Codex with manual prompts or AI-planned orchestration (Smart mode)
- **Mermaid diagrams** — Detects Mermaid diagram syntax in session output and renders it natively; diagrams can be exported as images
- **Web preview** — Auto-detects project type, starts dev servers for framework projects, and live-reloads static HTML
- **iOS Simulator run destination** — Build, install, and launch your app on any booted iOS Simulator directly from a session card; cancel at any phase (Building / Installing / Launching) via a stop button; boot-readiness check times out after 90 seconds to prevent hangs
- **Plan view** — Renders Claude-generated plan files with markdown and syntax highlighting; switch to Review mode to annotate individual lines and send batch feedback directly to Claude's interactive plan prompt
- **Global search** — Search across all session files with ranked results
- **Usage stats** — Track token counts, costs, and daily activity per provider (menu bar or popover)
- **Command palette** — Quick access to sessions, repositories, and actions via Cmd+K
- **Pending changes preview** — Review Edit/Write/MultiEdit tool diffs before accepting
- **Custom themes** — Ship with default and Sentry themes; load custom YAML themes with hot-reload
- **Image & file attachments** — Drag-and-drop files into sessions
- **Session naming** — Rename any session with custom names (SQLite-backed)
- **Notification sounds** — Configurable audio alert when a tool call awaits approval
- **Privacy-first** — Runs entirely on your machine; no data is collected or transmitted

Parallel execution with Claude Code and Codex

https://github.com/user-attachments/assets/c20c1f3e-745d-4a39-8599-37ad242b3ae6

Plan view with inline review and batch feedback

https://github.com/user-attachments/assets/b7661b65-dc58-4f8e-a4c5-df1e17a4076d

Mermaid diagram rendering with image export

https://github.com/user-attachments/assets/f6a304de-fc7c-4024-94c6-9e2222210dff

## Requirements

- macOS 14.0+
- [Claude Code CLI](https://claude.ai/claude-code) installed and authenticated
- [Codex CLI](https://openai.com/index/introducing-codex/) installed (optional, for Codex features)

## Installation & Updates

Download the latest release from [GitHub Releases](https://github.com/jamesrochabrun/AgentHub/releases). The app is code-signed and notarized by Apple.

Updates are delivered automatically via [Sparkle](https://sparkle-project.org/) with EdDSA signature verification. You'll be prompted when a new version is available.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+K** | Open command palette |
| **Cmd+N** | New session |
| **Cmd+B** | Toggle sidebar |
| **Cmd+,** | Open settings |
| **Cmd+[** | Navigate to previous session |
| **Cmd+]** | Navigate to next session |
| **Cmd+\\** | Toggle focus mode (single ↔ previous layout) |
| **Cmd++** | Increase terminal font size |
| **Cmd+-** | Decrease terminal font size |
| **Escape** | Dismiss maximized card / side panel / sheet |

### Diff View

| Shortcut | Action |
|---|---|
| **Return** | Send inline comment to Claude |
| **Cmd+Return** | Add comment to review collection |
| **Shift+Return** | Insert newline in editor |
| **Escape** | Close inline editor or diff view |

### Embedded Terminal

| Shortcut | Action |
|---|---|
| **Cmd+C** | Copy selected text |
| **Cmd+V** | Paste |
| **Cmd+A** | Select all |

### Command Palette

| Shortcut | Action |
|---|---|
| **Up / Down** | Navigate items |
| **Return** | Execute selected action |
| **Escape** | Close palette |

## Hub Layouts

The monitoring panel supports multiple layout modes:

| Mode | Description |
|---|---|
| **Single** | One session at full size with optional side panel (diff, plan, web preview) |
| **List** | Vertical card list grouped by provider |
| **2-Column** | Two-column grid |
| **3-Column** | Three-column grid |

Any card can be maximized to full panel with a click (Escape to restore).
In list mode, cards can be resized with a drag preview that commits on release.

## Session States

| Status | Description |
|---|---|
| Thinking | Claude/Codex is processing |
| Executing Tool | Running a tool call |
| Awaiting Approval | Tool requires user confirmation |
| Waiting for User | Awaiting input |
| Idle | Session inactive |

## Configuration

### Display Mode

AgentHub supports two display modes:

- **Menu Bar Mode** (default) — Stats appear in the system menu bar
- **Popover Mode** — Stats appear as a toolbar button in the app window

Toggle between modes in the app settings.

### Session Data

AgentHub reads Claude Code session data from:

```
~/.claude/projects/{encoded-path}/{sessionId}.jsonl
```

### Codex Data

AgentHub reads Codex session data from `~/.codex/`:

- **Session files:** `~/.codex/sessions/{date-path}/` (JSONL format)
- **History file:** `~/.codex/history.jsonl`

### Custom Themes

Place YAML theme files in `~/Library/Application Support/AgentHub/themes/`. Themes are hot-reloaded on save.

```yaml
name: My Theme
version: 1
author: Your Name
colors:
  brand:
    primary: "#7C3AED"
    secondary: "#6D28D9"
    tertiary: "#5B21B6"
  backgrounds:
    dark: "#1A1A2E"
    light: "#FFFFFF"
```

## Contributing

- **One PR per feature or bug fix.** Each pull request should address a single, focused change.
- **Keep PRs small.** Small, reviewable diffs get merged faster and are easier to reason about.
- **AI-generated code is welcome** as long as the PR represents one cohesive feature or fix.
- **Unrelated changes bundled together will not be reviewed or accepted.** If you have multiple fixes, open separate PRs for each.

## Privacy

AgentHub runs entirely on your machine. It does not collect, transmit, or store any data externally. The app simply reads your local CLI session files to display their status.

## License

MIT
