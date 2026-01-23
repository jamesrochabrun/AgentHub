# AgentHub

Manage all sessions in Claude Code. Easily create new worktrees, run multiple terminals in parallel, preview edits before accepting them, make inline changes directly from diffs, and more.

https://github.com/user-attachments/assets/865123c9-ff8a-4675-a789-f807294efc6f

## Features

- **Works immediately** - No setup required, works with your Claude Code plan
- **Observe sessions in real-time** - Monitor all your Claude Code sessions
- **Search across all sessions** - Find any session instantly
- **Run sessions in parallel** - Create and manage multiple Claude Code sessions in the hub
- **Create worktrees** - Easily spin up new git worktrees from the UI
- **Preview and edit diffs** - Make inline changes directly from the diff view
- **Codex support** - Coming soon

## Requirements

- macOS 14.0+
- [Claude Code CLI](https://claude.ai/claude-code) installed and authenticated

## Configuration

### Display Mode

AgentHub supports two display modes:

- **Menu Bar Mode** (default) - Stats appear in the system menu bar
- **Popover Mode** - Stats appear as a toolbar button in the app window

Toggle between modes in the app settings.

### Session Data

AgentHub reads Claude Code session data from:

```
~/.claude/projects/{encoded-path}/{sessionId}.jsonl
```

## Session States

| Status | Description |
|--------|-------------|
| Thinking | Claude is processing |
| Executing Tool | Running a tool call |
| Awaiting Approval | Tool requires user confirmation |
| Waiting for User | Awaiting input |
| Idle | Session inactive |

## License

MIT
