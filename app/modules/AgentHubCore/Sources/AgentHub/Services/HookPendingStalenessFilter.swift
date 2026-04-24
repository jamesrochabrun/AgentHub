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
/// Wall-clock timestamps drift between the Python hook process and
/// Claude's Node process. In practice both resolve to the same
/// `gettimeofday` source, so genuine skew is in the low-ms range. The
/// epsilon exists to absorb that and nothing more — **not** to serve as a
/// debounce window. A larger value (e.g. one second) would keep an already
/// resolved approval visible as pending long enough for a fast turn to
/// commit entirely within the grace period, leaving the UI stuck on
/// stale state until some unrelated JSONL activity arrived. 100ms is
/// comfortably above realistic cross-process skew and well below the
/// minimum duration a user can perceive a false pending flash.
///
/// Legacy whole-second sidecar lines from pre-millisecond builds used to
/// motivate a larger window, but `wipeAll` clears the approvals directory
/// at every launch/terminate, so those entries don't survive past one
/// app restart.
public enum HookPendingStalenessFilter {
  public static let stalenessEpsilon: TimeInterval = 0.1

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
