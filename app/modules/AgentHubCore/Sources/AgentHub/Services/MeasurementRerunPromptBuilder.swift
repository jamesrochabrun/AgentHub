import AgentHubCLIKit
import Foundation

/// Builds the prompt that asks a session to re-run one of its own measurements.
///
/// Re-running goes back through the agent rather than executing the stored
/// query directly: the query is arbitrary shell/SQL the agent wrote, and the
/// agent is already the thing allowed to run commands in this session. That
/// keeps AgentHub out of the code-execution business entirely — clicking ↻
/// can do nothing the session could not already do on its own.
enum MeasurementRerunPromptBuilder {
  /// Measurements without a stored query cannot be refreshed — there is nothing to
  /// re-execute, and asking the agent to reconstruct one would silently change
  /// the measurement, which defeats the point of re-running.
  static func canRerun(_ record: MeasurementRecord) -> Bool {
    guard let query = record.query else { return false }
    return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func prompt(for record: MeasurementRecord) -> String? {
    guard canRerun(record), let query = record.query else { return nil }

    return """
      Re-run a measurement you recorded earlier in this session and refresh its card in AgentHub.

      Measurement id: \(record.id)
      Title: \(record.title)

      Run this exactly as written — do not rewrite, "improve", or re-derive it, because the \
      point of re-running is that the measurement stays comparable to the earlier one:

      ```
      \(query.trimmingCharacters(in: .whitespacesAndNewlines))
      ```

      Then call agenthub_record_measurement with:
      - id: "\(record.id)" — required, so the existing card refreshes instead of a duplicate appearing
      - title: "\(record.title)" — unchanged
      - chart/table built from the new numbers
      - claim rewritten to state what the new numbers say, including how they moved since the \
      previous run if the difference matters
      - caveats that still apply

      If the command fails or its output no longer parses, say so plainly and do not record a \
      measurement — a card that silently keeps stale numbers is worse than one that is obviously out of date.
      """
  }
}
