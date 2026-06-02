import Foundation

public enum WorktreeNaming {
  public static func sanitizeBranchName(_ branch: String) -> String {
    var name = branch

    if let slashIndex = name.firstIndex(of: "/"),
       !name.hasPrefix("feature/") && !name.hasPrefix("bugfix/") && !name.hasPrefix("hotfix/") {
      let prefix = String(name[..<slashIndex])
      if prefix == "origin" || prefix == "upstream" || prefix == "remote" {
        name = String(name[name.index(after: slashIndex)...])
      }
    }

    return name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
  }

  public static func worktreeDirectoryName(for branch: String, repoName _: String? = nil) -> String {
    sanitizeBranchName(branch)
  }

  /// Returns a branch name guaranteed not to collide with an existing branch in
  /// `takenBranches` or — via its derived worktree directory — an existing
  /// worktree directory in `takenDirectoryNames`. If the requested name is free
  /// it is returned unchanged; otherwise `-2`, `-3`, … is appended until a free
  /// name is found. This lets multi-worktree creation succeed even when a name
  /// is already taken (a leftover from a previous run, or a duplicate within the
  /// same batch) instead of failing on `git worktree add -b`.
  public static func availableBranchName(
    for requested: String,
    takenBranches: Set<String>,
    takenDirectoryNames: Set<String>
  ) -> String {
    func isTaken(_ candidate: String) -> Bool {
      takenBranches.contains(candidate)
        || takenDirectoryNames.contains(worktreeDirectoryName(for: candidate))
    }

    guard isTaken(requested) else { return requested }

    var suffix = 2
    while isTaken("\(requested)-\(suffix)") {
      suffix += 1
    }
    return "\(requested)-\(suffix)"
  }
}
