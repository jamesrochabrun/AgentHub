import Foundation

/// Seeds the "changed source files" list from git when the panel opens, so
/// previews of files edited before AgentHub was watching (the usual agent
/// session) are immediately available — not just edits made after arming.
public enum GitChangedSwiftFiles {

  /// Parses `git status --porcelain` output into Swift file names
  /// (basenames, e.g. "HomeView.swift"), preserving git's order.
  public static func parse(porcelain: String) -> [String] {
    var files: [String] = []
    for line in porcelain.components(separatedBy: .newlines) {
      guard line.count > 3 else { continue }
      var path = String(line.dropFirst(3))
      // Renames are "R  old -> new"; the new path is what's on disk.
      if let arrow = path.range(of: " -> ") {
        path = String(path[arrow.upperBound...])
      }
      // Quoted paths (spaces/unicode) come wrapped in double quotes.
      path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      guard path.hasSuffix(".swift") else { continue }
      let fileName = (path as NSString).lastPathComponent
      if !files.contains(fileName) { files.append(fileName) }
    }
    return files
  }

  /// Runs `git status --porcelain` in the project and returns the changed
  /// Swift file names. Empty on any failure (not a git repo, no git, …).
  public static func changedFiles(inProjectAt projectPath: String) async -> [String] {
    await Task.detached(priority: .utility) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", projectPath, "status", "--porcelain"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
      } catch {
        return []
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return [] }
      return parse(porcelain: String(decoding: data, as: UTF8.self))
    }.value
  }
}
