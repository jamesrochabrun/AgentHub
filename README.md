# AgentHub

A native macOS app for managing Claude Code and Codex CLI sessions. Monitor sessions in real-time, run multiple terminals in parallel, preview diffs, browse GitHub pull requests and issues, create worktrees, launch multi-provider sessions, and more — all from a single hub.

## Demo

<img width="1913" height="1079" alt="Hub" src="https://github.com/user-attachments/assets/99518d02-8ca6-458a-900c-bfd1f4e57419" />

[Point to code](https://x.com/jamesrochabrun/status/2036492646039036003?s=20)

<img width="1911" height="1077" alt="Image" src="https://github.com/user-attachments/assets/f9e15c46-b907-4d7b-9b8e-f9dbcad06da4" />

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
- **Auxiliary Hub shell** — Toggle a session-scoped shell dock from the Hub with **Cmd+J**; it follows the selected session's worktree and preserves shell state per session
- **Resizable list cards** — In list mode, monitoring cards can be resized with a preview guide for a smoother, less distracting resize experience
- **Inline diff review** — Full split-pane diff view with inline editor to send change requests directly to Claude
- **GitHub support** — Browse pull requests and issues for the current repository, inspect PR diffs and CI checks, and send GitHub context back into a session
- **File explorer and built-in editor** — Browse the project tree, jump to files with Cmd+P, edit files in-app with syntax highlighting, and save changes without leaving AgentHub
- **Git worktree management** — Create and delete worktrees from the UI; launch sessions on new branches
- **Managed build cache storage** — AgentHub-started Xcode and Swift builds write rebuildable cache data under `~/Library/Caches/AgentHub`, with a Settings panel to inspect and clear disk usage
- **Remix with provider picker** — Branch any session into an isolated git worktree and continue it in Claude or Codex; the original session's transcript is passed as context to the new session
- **Multi-session launcher** — Launch parallel sessions across Claude and Codex with manual prompts or AI-planned orchestration (Smart mode)
- **Mermaid diagrams** — Detects Mermaid diagram syntax in session output and renders it natively; diagrams can be exported as images
- **Web preview** — Prefers agent-started localhost servers, recovers recent localhost URLs from session files when needed, and falls back to static HTML (`index.html` first) when no live preview is available
- **Web preview batch updates** — Inspect elements or crop regions in the live web preview, queue multiple requested updates with structured context, and attach the batch to your next terminal message — no copy-paste needed
- **Storybook support** — Auto-detects Storybook-enabled projects (`.storybook/` config, `storybook` npm script, or `@storybook/*` devDependencies) and replaces the Preview button with a one-click Storybook launcher; the dev server is started under a compound key so it can run alongside your primary app server
- **iOS Simulator run destination** — Build, install, and launch your app on any booted iOS Simulator directly from a session card; cancel at any phase (Building / Installing / Launching) via a stop button; boot-readiness check times out after 90 seconds to prevent hangs
- **Plan view** — Renders Claude-generated plan files with markdown and syntax highlighting; switch to Review mode to annotate individual lines and send batch feedback directly to Claude's interactive plan prompt
- **Global search** — Search across all session files with ranked results
- **Usage stats** — Track token counts, costs, and daily activity per provider (menu bar or popover)
- **Command palette** — Quick access to sessions, repositories, and actions via Cmd+K
- **Pending changes preview** — Review Edit/Write/MultiEdit tool diffs before accepting
- **Custom themes** — bundled YAML themes (Singularity, Nebula, Helios, Rigel, Vela, Antares, Sentry, plus a Ghostty-only theme) with terminal ANSI palettes, custom backgrounds where applicable, and WCAG-compliant contrast; load custom YAML themes with hot-reload
- **Terminal font picker** — Choose from 9 monospace fonts: SF Mono, JetBrains Mono, GeistMono, Fira Code, Cascadia Mono, Source Code Pro, Menlo, Monaco, Courier New
- **Image & file attachments** — Drag-and-drop files into sessions
- **Session naming** — Rename any session with custom names (SQLite-backed)
- **Notification sounds** — Configurable audio alert when a tool call awaits approval
- **Privacy-first** — Runs entirely on your machine; no data is collected or transmitted
- **Process cleanup** — When a monitored Hub card is removed, AgentHub terminates both the card terminal and the auxiliary Hub shell process tree so shell/CLI sessions are not left orphaned

Parallel execution with Claude Code and Codex

https://github.com/user-attachments/assets/c20c1f3e-745d-4a39-8599-37ad242b3ae6

Plan view with inline review and batch feedback

https://github.com/user-attachments/assets/b7661b65-dc58-4f8e-a4c5-df1e17a4076d

Mermaid diagram rendering with image export

https://github.com/user-attachments/assets/f6a304de-fc7c-4024-94c6-9e2222210dff

## GitHub Support

AgentHub can surface repository GitHub data directly inside the app through the GitHub CLI. GitHub access in AgentHub requires `gh` to be installed and authenticated.

- Browse pull requests and issues for the active repository
- Open the current branch PR directly from the session card
- Review PR overview content, changed files, CI checks, and comments
- Render PR file diffs with the same inline diff viewer used elsewhere in AgentHub
- Send PR or issue context back into the active Claude Code or Codex session

### GitHub Setup

GitHub features are optional, but any GitHub access in AgentHub depends on the GitHub CLI:

1. Install [`gh`](https://cli.github.com/).
2. Authenticate with `gh auth login`.
3. Open any GitHub repository in AgentHub and use the `GitHub` action from the session UI.

## File Explorer

AgentHub includes a built-in file explorer and editor for supported text files. Open the quick file picker with **Cmd+P** to jump directly to a file, then edit and save changes from inside the side panel without leaving the app.

File explorer, quick open, and built-in editor

https://github.com/user-attachments/assets/6d263d11-6648-42e7-9335-04aa51a33296

## Storybook

When AgentHub detects a Storybook configuration in a project, the regular **Preview** button on each session card is replaced by a dedicated **Storybook** button. Clicking it spawns the Storybook dev server (via `npm run storybook`) and opens the web preview pane pinned to the Storybook URL — independently of any other dev server the agent has running.

### Detection

A project is treated as Storybook-enabled if **any** of these is true:

- A `.storybook/` directory exists at the project root
- `package.json` has a `"storybook"` or `"storybook:dev"` script entry
- `package.json` devDependencies contains any `@storybook/*` package

Detection lives in the standalone `Storybook` Swift module (`app/modules/Storybook/`), which has zero dependencies and can be reused outside `AgentHubCore`.

### How it runs

- The Storybook server is keyed by `"{sessionId}:storybook"` in `DevServerManager`, so it coexists with your primary dev server (Vite, Next, etc.) under the plain `sessionId` key.
- If your `storybook` npm script already pins a port (e.g. `storybook dev -p 6006`), AgentHub honors that port instead of trying to override it — npm appends extra args after the script's, and Storybook only respects the first `-p`, so passing our own would desync the bind port from the tracked port.
- If port 6006 is in use and Storybook prompts to use an alternate port, AgentHub auto-accepts; the actual port is captured from Storybook's `Local: http://localhost:N/` ready banner.
- The web preview pane in Storybook mode resolves URLs from the storybook server slot only; it does not follow the agent's app-server URL changes, so the Storybook view stays pinned even if the agent restarts the primary dev server.

## Requirements

- macOS 14.0+
- [Claude Code CLI](https://claude.ai/claude-code) installed and authenticated
- [Codex CLI](https://openai.com/index/introducing-codex/) installed (optional, for Codex features)
- [GitHub CLI](https://cli.github.com/) installed and authenticated (optional overall, required for GitHub access/features)

## Installation & Updates

Download the latest release from [GitHub Releases](https://github.com/jamesrochabrun/AgentHub/releases). The app is code-signed and notarized by Apple.

Updates are delivered automatically via [Sparkle](https://sparkle-project.org/) with EdDSA signature verification. You'll be prompted when a new version is available.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **Cmd+K** | Open command palette |
| **Cmd+P** | Quick open files |
| **Cmd+N** | New session |
| **Cmd+B** | Toggle sidebar |
| **Cmd+J** | Toggle Hub auxiliary shell |
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

### File Explorer

| Shortcut | Action |
|---|---|
| **Cmd+P** | Open quick file picker |
| **Cmd+S** | Save current file in file editor |
| **Escape** | Close quick file picker or file editor |

### Embedded Terminal

| Shortcut | Action |
|---|---|
| **Cmd+C** | Copy selected text |
| **Cmd+V** | Paste |
| **Cmd+A** | Select all |
| **⌥↩ / ⌘↩ / ⇧↩** | Insert newline (configurable in Settings → Terminal) |

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

## Plan Mode

Plan mode lets Claude read and analyze your codebase without executing any changes.
Toggle it on or off with **Shift+Tab** inside the prompt editor in the multi-session launcher.
When active, a teal indicator appears below the prompt.

| Provider | Behavior |
|---|---|
| **Claude** | Launched with `--permission-mode plan`; reads files and plans but does not write or execute |
| **Codex** | Not available — the Codex CLI has no flag to start in plan mode |

> **Why isn't Codex supported?** Codex's plan mode (`ModeKind::Plan`) is a TUI-only collaboration mode that can only be toggled interactively inside the running terminal. The CLI always starts in Default mode with no override flag. When plan mode is active in AgentHub, the Codex provider pill is disabled to avoid confusion. Track upstream support at [openai/codex #12738](https://github.com/openai/codex/issues/12738).

## Configuration

AgentHub's settings window includes tabs for:

- **General** — Notifications and app-wide behavior such as opening the file explorer in a modal window
- **Configuration** — Claude and Codex CLI commands, provider-specific defaults, and Smart mode
- **Worktrees** — Defaults for creating and cleaning up git worktrees
- **Storage** — AgentHub build-cache usage, cleanup target, per-workspace cache controls, and advanced cache deletion
- **Appearance** — Flat session layout, terminal preferences, and theme selection
- **Developer** — Debug-only development controls

### Display Mode

AgentHub supports two display modes:

- **Menu Bar Mode** (default) — Stats appear in the system menu bar
- **Popover Mode** — Stats appear as a toolbar button in the app window

Toggle between modes in the app settings.

### Storage

AgentHub redirects build cache data it creates while running Xcode and Swift builds to:

```
~/Library/Caches/AgentHub
```

This cache contains rebuildable build products, SwiftPM package data, and per-workspace intermediates. It is disk usage, not memory usage, and it does not include your source code.

Open **Settings → Storage** to see total usage, the cache folder, the cleanup target, and per-workspace cache rows. **Keep** protects a workspace cache from size-based cleanup, **Delete Cache** removes one workspace cache, and **Free Up Disk Space** removes eligible caches that AgentHub can recreate. The advanced **Delete Every Cache** action reclaims the most disk space; the tradeoff is that the next build or test for affected projects may be slower while Xcode and SwiftPM recreate packages and build intermediates.

### Provider Defaults

Provider defaults are applied only when AgentHub starts a new embedded CLI session. Resume flows keep the original session configuration and do not inject new model or approval flags.
These settings are persisted locally in AgentHub's SQLite metadata store.

#### Claude

AgentHub maps Claude defaults to the installed CLI flags:

- `Model` → `--model <model>`
- `Effort` → `--effort <low|medium|high>`
- `Allowed Tools` → `--allowedTools <tool...>`
- `Denied Tools` → `--disallowedTools <tool...>`

The Claude tool lists in Settings accept either comma-separated values or one pattern per line. AgentHub normalizes both forms before launching the session.

#### Codex

AgentHub maps Codex defaults to the current interactive CLI flags:

- `Model` → `--model <model>`
- `Approval` → `-a untrusted|on-request|never` or `--full-auto`
- `Effort` → `-c model_reasoning_effort="low|medium|high|xhigh"`

These mappings are verified in unit tests against the current CLI surface exposed by `codex --help` and `claude --help`.

### Claude Code approval hook

AgentHub detects pending `Edit` / `Write` / `MultiEdit` / `Bash` / etc. approvals in real time by installing a small **Claude Code PreToolUse hook**. Without it, Claude Code's CLI only writes the pending `tool_use` block to disk after the turn commits — which means AgentHub can't surface an "Awaiting Approval" state (or preview a pending diff) until *after* you've answered the prompt. Enabling the hook is what makes the `eye` / Edits button and the `awaitingApproval` sidebar status appear *during* the approval window.

**What gets written to your repo.** Exactly one key inside **`{project}/.claude/settings.local.json`**, which Claude Code treats as personal/gitignored by default. We never touch `.claude/settings.json` (the shared, checked-in file), never add files under `.claude/hooks/`, and never modify your `.gitignore`. The hook script itself lives outside your repo at `~/Library/Application Support/AgentHub/hooks/agenthub-approval.sh`.

**What we promise to preserve.** Every other key in `settings.local.json` — `permissions`, `env`, `mcpServers`, and any hook entries you or other tools have added — stays byte-for-byte. Our entry is identified by the absolute path of the installed script, so uninstall removes only that entry and leaves everything else alone.

**Lifecycle.** Hooks install per worktree when a repo is added to AgentHub, stay installed while the repo is tracked, and are removed when you remove the repo, toggle the feature off in **Settings → General → Enable approval hooks**, or quit the app. External Claude Code sessions in the same worktree (e.g. started from Terminal.app) run the hook but it exits silently — a small ~50ms claim-file check makes sure AgentHub only observes sessions it's actively tracking.

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
