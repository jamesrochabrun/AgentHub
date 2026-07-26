---
name: agenthub-session-naming
description: Fast AgentHub workflow for naming or renaming the current Claude or Codex session. Use whenever the user asks to name, rename, or suggest names for the current session.
user-invocable: false
allowed-tools:
  - AskUserQuestion
  - mcp__agenthub__name_session
---

# AgentHub Session Naming

1. Immediately call `name_session` with no arguments. Do not inspect files, run git, or analyze the full conversation first.
2. Use the returned metadata and at most the first three user messages to create exactly three concise options. Every option must be lowercase kebab-case with no spaces, ideally 2-5 words and no longer than needed (for example, `fix-session-naming`).
3. For Claude, make `claudeSessionName` the recommended first option when present. If Claude already exposes the current session name in its own context, use that the same way. Otherwise prefer a descriptive branch name over the worktree directory name.
4. Ask the user to choose, using an interactive choice UI when available and allowing a custom answer.
5. After the user chooses, immediately call `name_session` again with `name` set to that choice. The tool normalizes custom answers into lowercase kebab-case. Do not claim the session was renamed until this call succeeds.
