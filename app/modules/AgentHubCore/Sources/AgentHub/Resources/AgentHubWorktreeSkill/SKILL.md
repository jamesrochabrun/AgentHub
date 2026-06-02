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

1. Read the user's request and infer independent subtasks semantically. If the request includes explicit independent numbered or bulleted work streams, preserve each list item as a subtask; otherwise do not split only because of punctuation, commas, semicolons, or conjunctions.
2. Call `agent_hub_planning` before creating any sessions. Pass the original prompt and, when the request clearly contains multiple independent work streams, pass those preserved or inferred subtasks as `subtasks`.
3. Present the proposed assignments and include task, provider/agent, model when available, branch, rationale, and launch prompt.
4. Wait for explicit user approval.
5. Call `agenthub_create_worktree_sessions` only for approved assignments. Pass one task per assignment with explicit `provider`, `branch`, and `prompt`.

For a single-task request, still call `agent_hub_planning` with one inferred subtask so the provider and branch are explicit before approval.

## List Or Delete Task Sessions

Use `agenthub_list_worktrees` before destructive cleanup when the target or session impact is unclear. Use `agenthub_delete_worktree` only after the user identifies the session to delete.

## Boundaries

Do not use these AgentHub task tools for generic planning, fan-out, background work, or subagent requests unless the user explicitly invoked this skill. Preserve the current harness's native subagent and background-task capabilities.
