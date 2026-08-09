import Foundation

/// Resolves which project a measurement belongs to.
///
/// Measurements are keyed by project, not by session. A measurement about a repo,
/// a CSV, or a database is about *the data* — the session is only who asked.
/// Scoping to a session would hide last month's number from this month's
/// conversation, which is precisely when comparing it matters.
enum MeasurementProjectScope {
  /// The storage key for a measurement filed from a session.
  ///
  /// A worktree rolls up to its parent repository: an agent working in a
  /// sibling worktree is working on the same project, and splitting its
  /// measurements into a separate bucket would fragment the history the feature
  /// exists to accumulate.
  static func key(projectPath: String, parentRepoPath: String?) -> String {
    let preferred = parentRepoPath.flatMap { path -> String? in
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } ?? projectPath

    return normalized(preferred)
  }

  /// Expands `~`, resolves `..`, and drops a trailing slash so the same
  /// directory written three ways lands in one bucket.
  static func normalized(_ path: String) -> String {
    let expanded = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines))
      .expandingTildeInPath
    let standardized = (expanded as NSString).standardizingPath
    guard standardized.count > 1, standardized.hasSuffix("/") else {
      return standardized
    }
    return String(standardized.dropLast())
  }
}
