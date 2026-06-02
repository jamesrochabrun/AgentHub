---
name: agenthub-worktrees
description: User-invoked AgentHub workflow for planning and creating AgentHub-managed git worktree sessions. Use only when the user explicitly invokes this skill to plan, create, list, or delete AgentHub worktrees.
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

# AgentHub Worktrees

Use this workflow only because the user explicitly invoked this skill for AgentHub worktrees.

## Create Worktrees

1. Read the user's request and infer independent worktree subtasks semantically. If the request includes explicit independent numbered or bulleted work streams, preserve each list item as a subtask; otherwise do not split only because of punctuation, commas, semicolons, or conjunctions.
2. Call `agent_hub_planning` before creating worktrees. Pass the original prompt and, when the request clearly contains multiple independent work streams, pass those preserved or inferred subtasks as `subtasks`.
3. Present the proposed assignments and include task, provider/agent, model when available, branch, rationale, and launch prompt.
4. Wait for explicit user approval.
5. Call `agenthub_create_worktree_sessions` only for approved assignments. Pass one task per assignment with explicit `provider`, `branch`, and `prompt`.

For a single worktree request, still call `agent_hub_planning` with one inferred subtask so the provider and branch are explicit before approval.

## List Or Delete Worktrees

Use `agenthub_list_worktrees` before destructive cleanup when the target or session impact is unclear. Use `agenthub_delete_worktree` only after the user identifies the worktree to delete.

## Boundaries

Do not use AgentHub worktree tools for generic planning, fan-out, background work, or subagent requests unless the user explicitly invoked this skill for AgentHub worktrees. Preserve the current harness's native subagent and background-task capabilities.
