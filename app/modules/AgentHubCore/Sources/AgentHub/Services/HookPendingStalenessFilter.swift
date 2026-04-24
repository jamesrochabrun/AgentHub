import Foundation

/// Decides whether a hook-sourced `PendingToolInfo` is still live or has
/// been invalidated by subsequent JSONL activity.
///
/// ## Why this exists
///
/// `ClaudeHookSidecarWatcher` keeps sidecar files on disk across
/// `stopWatching` so that a user who toggles monitoring off **during** an
/// approval can toggle it back on and recover the pending state (the JSONL
/// hasn't written the `tool_use` block yet and would otherwise have nothing
/// to offer). That preservation opens an edge case: if the user approves
/// the tool in the CLI while AgentHub isn't tracking the session, the
/// hook's `PostToolUse` invocation finds no claim file and exits silently
/// — so the sidecar keeps its `pending` line with no matching `resolved`.
/// When monitoring resumes, a naive merge would promote the stale entry to
/// `.awaitingApproval` even though the approval already happened.
///
/// ## The invariant we exploit
///
/// Claude Code CLI only writes **any** JSONL entry — thinking, text,
/// `tool_use`, `tool_result` — when the containing turn commits. The turn
/// can't commit until every tool in it resolves. So if JSONL's latest
/// activity timestamp is newer than the hook's `pending` timestamp, the
/// corresponding approval must have been answered: the sidecar is stale
/// and should be ignored.
///
/// ## Why the epsilon
///
/// Wall-clock timestamps drift between processes. The hook runs in a
/// separate Python process; Claude writes JSONL from Node. Even now that
/// the hook emits millisecond precision there's still genuine skew on the
/// order of tens of milliseconds. We also need to absorb legacy sidecar
/// lines from earlier builds that were written with whole-second
/// truncation. A one-second grace window covers both cleanly without
/// making the stale-detection meaningfully slower to kick in (a turn that
/// actually resolved will have JSONL activity at least that far past the
/// hook timestamp once the result block lands).
public enum HookPendingStalenessFilter {
  public static let stalenessEpsilon: TimeInterval = 1.0

  public static func filter(
    hookPending: SessionJSONLParser.PendingToolInfo?,
    lastActivityAt: Date?,
    epsilon: TimeInterval = stalenessEpsilon
  ) -> SessionJSONLParser.PendingToolInfo? {
    guard let hookPending else { return nil }
    if let lastActivityAt,
       lastActivityAt.timeIntervalSince(hookPending.timestamp) > epsilon {
      return nil
    }
    return hookPending
  }
}
