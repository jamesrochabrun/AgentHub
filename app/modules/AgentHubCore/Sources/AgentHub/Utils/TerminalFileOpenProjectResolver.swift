//
//  TerminalFileOpenProjectResolver.swift
//  AgentHub
//
//  Resolves the project root used by the inline file explorer for terminal
//  Cmd+Click file opens.
//

import Foundation

enum TerminalFileOpenProjectResolver {
  static func projectPath(
    forFile filePath: String,
    sessionProjectPath: String,
    repositories: [SelectedRepository],
    fileManager: FileManager = .default
  ) -> String {
    let resolvedFilePath = normalize(filePath)
    let resolvedSessionProjectPath = normalize(sessionProjectPath)

    if isPath(resolvedFilePath, within: resolvedSessionProjectPath) {
      return resolvedSessionProjectPath
    }

    if let selectedRoot = selectedProjectRoot(
      containing: resolvedFilePath,
      repositories: repositories
    ) {
      return selectedRoot
    }

    if let gitRoot = gitRoot(containing: resolvedFilePath, fileManager: fileManager) {
      return gitRoot
    }

    return URL(fileURLWithPath: resolvedFilePath)
      .deletingLastPathComponent()
      .standardizedFileURL
      .path
  }

  private static func selectedProjectRoot(
    containing filePath: String,
    repositories: [SelectedRepository]
  ) -> String? {
    let candidates = repositories.flatMap { repository in
      [repository.path] + repository.worktrees.map(\.path)
    }
    .map(normalize)
    .filter { isPath(filePath, within: $0) }

    return candidates.max { $0.count < $1.count }
  }

  private static func gitRoot(containing filePath: String, fileManager: FileManager) -> String? {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory)
    var current = exists && isDirectory.boolValue
      ? filePath
      : URL(fileURLWithPath: filePath).deletingLastPathComponent().path

    while !current.isEmpty {
      let gitPath = (current as NSString).appendingPathComponent(".git")
      if fileManager.fileExists(atPath: gitPath) {
        return normalize(current)
      }

      let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
      if parent == current {
        return nil
      }
      current = parent
    }

    return nil
  }

  private static func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  private static func isPath(_ path: String, within rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }
}
