---
name: agenthub-task-manager
description: User-invoked AgentHub workflow for planning a multi-part request and delegating its independent subtasks to parallel AgentHub agent sessions. Use only when the user explicitly invokes this skill to plan, create, list, or clean up AgentHub task sessions.
disable-model-invocation: true
user-invocable: true
allowed-tools:
  - ToolSearch
  - AskUserQuestion
  - mcp__agenthub__agent_hub_planning
  - mcp__agenthub__agenthub_create_worktree_sessions
  - mcp__agenthub__agenthub_list_worktrees
  - mcp__agenthub__agenthub_delete_worktree
---

# AgentHub Task Manager

Use this workflow only because the user explicitly invoked this skill to plan and delegate work to parallel AgentHub agent sessions.

## Plan And Create Task Sessions

1. Read the user's request and infer the independent subtasks yourself. Preserve explicit numbered or bulleted work streams as separate subtasks; do not split ordinary prose just because of punctuation, commas, semicolons, or conjunctions.
2. Call `agent_hub_planning`, passing the original prompt and the subtasks you inferred as `subtasks`. AgentHub does not split for you — with no `subtasks` it plans the whole prompt as a single task.
3. Review the returned assignments and the `harnessCapabilities` block — each harness's **real installed skills and MCP servers**. AgentHub launches a **harness** (Claude Code or Codex), not a model, so present only the harness, never a model name. When multiple harnesses are installed, each subtask comes with a *suggested* harness plus the `matchedCapabilities` that drove it. Confirm or override every suggestion by matching the subtask to the harness whose **actual tools** fit — e.g. a profiling subtask → the harness that has an xctrace/profiler tool; a SwiftUI subtask → the harness with a swiftui skill. Decide from the listed capabilities, never from a harness's general reputation, and cite the matching skill/tool in your rationale.
4. Present the final assignments (task, chosen harness + why, branch, launch prompt) and wait for explicit user approval.
5. Call `agenthub_create_worktree_sessions` only for approved assignments. Pass one task per assignment with explicit `provider`, `branch`, and `prompt`. Include `startPath` when the task belongs to a subdirectory; AgentHub uses it to create a sparse worktree and then launch the agent from that same relative path. Use `fullCheckout: true` only when the task genuinely needs the whole repository materialized.

For a single-task request, still call `agent_hub_planning` with one subtask so the agent and branch are explicit before approval.

## List Or Delete Task Sessions

Use `agenthub_list_worktrees` before destructive cleanup when the target or session impact is unclear. Use `agenthub_delete_worktree` only after the user identifies the session to delete.

## Boundaries

Do not use these AgentHub task tools for generic planning, fan-out, background work, or subagent requests unless the user explicitly invoked this skill. Preserve the current harness's native subagent and background-task capabilities.
