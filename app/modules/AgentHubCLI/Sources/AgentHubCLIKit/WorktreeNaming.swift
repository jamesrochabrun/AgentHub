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
}
