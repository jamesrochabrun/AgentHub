import Foundation

public struct SessionNamingContext: Equatable, Sendable {
  public let worktreeName: String
  public let branchName: String?
  public let claudeSessionName: String?

  public init(
    worktreeName: String,
    branchName: String?,
    claudeSessionName: String?
  ) {
    self.worktreeName = worktreeName
    self.branchName = branchName
    self.claudeSessionName = claudeSessionName
  }
}

public protocol SessionNamingContextProviding {
  func context(
    provider: WorktreeLaunchProvider,
    projectPath: String,
    sessionId: String?
  ) -> SessionNamingContext
}

public struct SessionNamingContextProvider: SessionNamingContextProviding {
  private let homeDirectory: URL
  private let fileManager: FileManager

  public init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
  }

  public func context(
    provider: WorktreeLaunchProvider,
    projectPath: String,
    sessionId: String?
  ) -> SessionNamingContext {
    let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
    let gitRoot = findGitRoot(from: projectURL)
    let branchName = gitRoot.flatMap(readBranchName)
    let claudeSessionName = provider == .claude
      ? readClaudeSessionName(projectPath: projectURL.path, sessionId: sessionId)
      : nil

    return SessionNamingContext(
      worktreeName: (gitRoot ?? projectURL).lastPathComponent,
      branchName: nonEmpty(branchName),
      claudeSessionName: nonEmpty(claudeSessionName)
    )
  }

  private func findGitRoot(from projectURL: URL) -> URL? {
    var candidate = projectURL
    while true {
      if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { return nil }
      candidate = parent
    }
  }

  private func readBranchName(gitRoot: URL) -> String? {
    let gitURL = gitRoot.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
      return nil
    }

    let headURL: URL
    if isDirectory.boolValue {
      headURL = gitURL.appendingPathComponent("HEAD")
    } else {
      guard let gitFile = try? String(contentsOf: gitURL, encoding: .utf8),
            let gitDirectory = gitFile
              .split(separator: "\n")
              .first(where: { $0.hasPrefix("gitdir:") })
              .map({ String($0.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces) })
      else {
        return nil
      }
      let resolvedGitDirectory = URL(
        fileURLWithPath: gitDirectory,
        relativeTo: gitDirectory.hasPrefix("/") ? nil : gitRoot
      ).standardizedFileURL
      headURL = resolvedGitDirectory.appendingPathComponent("HEAD")
    }

    guard let head = try? String(contentsOf: headURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      head.hasPrefix("ref: refs/heads/")
    else {
      return nil
    }
    return String(head.dropFirst("ref: refs/heads/".count))
  }

  private func readClaudeSessionName(projectPath: String, sessionId: String?) -> String? {
    let projectDirectory = homeDirectory
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(encodeClaudeProjectPath(projectPath), isDirectory: true)

    let sessionURL: URL?
    if let sessionId = nonEmpty(sessionId) {
      sessionURL = projectDirectory.appendingPathComponent("\(sessionId).jsonl")
    } else {
      sessionURL = newestJSONLFile(in: projectDirectory)
    }
    guard let sessionURL,
          let handle = try? FileHandle(forReadingFrom: sessionURL)
    else {
      return nil
    }
    defer { try? handle.close() }

    guard let data = try? handle.read(upToCount: 16_384),
          let content = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    for line in content.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let slug = nonEmpty(object["slug"] as? String)
      else {
        continue
      }
      return slug
    }
    return nil
  }

  private func newestJSONLFile(in directory: URL) -> URL? {
    guard let files = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    return files
      .filter { $0.pathExtension == "jsonl" }
      .max { lhs, rhs in
        let lhsDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let rhsDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
      }
  }

  private func encodeClaudeProjectPath(_ path: String) -> String {
    path
      .replacing("/", with: "-")
      .replacing(".", with: "-")
      .replacing("_", with: "-")
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }
}
