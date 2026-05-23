# Accessory Sessions

Accessory sessions are Claude or Codex sessions that run inside a parent session's accessory terminal pane. They are persisted as directed session relationships so the parent can restore its child panes on relaunch.

## User Flow

- When a Claude or Codex session starts inside a parent session's accessory terminal pane, AgentHub watches for the provider's real session JSONL file.
- When the provider writes that file, AgentHub resolves the child session ID, stores a parent -> child edge, and saves the terminal workspace snapshot.
- On relaunch, the parent workspace snapshot restores linked child panes with `claude -r <sessionId>` or `codex resume <sessionId>`.

## Passive Detection

Accessory shell panes are also watched for manual starts. When a shell pane appears, AgentHub records a provider-specific JSONL baseline for both Claude and Codex. A later JSONL file is attached only when it:

- was not present in the baseline,
- was written after the shell-pane context started,
- matches the pane working directory,
- resolves to exactly one provider session.

This avoids shell aliases, command wrappers, repository file edits, and command interception. Manual detection is for newly created sessions; arbitrary old resumed sessions should not be attached unless the provider emits a clear new matching session signal.

## Persistence Model

Session relationships live in SQLite table `session_relationships`.

- `sourceProvider`, `sourceSessionId`: parent session identity.
- `targetProvider`, `targetSessionId`: child session identity.
- `kind`: currently `accessoryChild`.
- `origin`: `explicit` for programmatic accessory launches, `detected` for passive JSONL detection.
- `createdAt`, `updatedAt`: routing metadata only.

Do not store prompts, terminal contents, full environment, transcripts, or other runtime payloads in relationship rows.

Terminal layout still lives in `terminal_workspaces`. `TerminalWorkspaceTabSnapshot` may include linked-session metadata for a child pane. The graph row says the relationship exists; the workspace snapshot says where the child pane appears. If a user closes a child pane, remove only that active accessory edge.

## Module Boundary

Session identity, relationship records, relationship-store protocols, Codex session metadata scanning, and accessory JSONL detection live in `AgentHubSessionGraph`. `AgentHubCore` owns SQLite migrations/store implementation and SwiftUI/ViewModel orchestration. Terminal surfaces should not infer graph edges directly; they only expose workspace snapshots, pane working directories, and linked-session markers for the graph coordinator to persist.

## Pending Parents

If a child session resolves before its parent pending session has a real session ID, keep the relationship in memory under the pending terminal key. When the parent resolves, rewrite the relationship with the real parent session ID and persist the current workspace snapshot.

If the parent never resolves, do not persist a graph edge. The child remains discoverable through normal provider session discovery.

## Schema Rules

- Append a new `DatabaseMigrator` migration for every schema change.
- Never edit, rename, reorder, or delete existing migration identifiers or migration bodies.
- Treat ordered `vN_*` migrations in `SessionMetadataStore` as schema versions.
- Production migrations must be additive or explicit data transforms.
- Do not use broad deletes, `drop table`, `clearAll()`, or `eraseDatabaseOnSchemaChange` in production migrations.
- Every `SessionMetadataStore` schema change must include a migration-preservation test that seeds the current baseline database and proves existing rows survive migration.
- Future `session_relationships` changes must include relationship-store tests and migration-preservation coverage.
