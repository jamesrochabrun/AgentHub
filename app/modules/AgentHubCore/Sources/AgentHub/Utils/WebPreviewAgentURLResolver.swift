//
//  WebPreviewAgentURLResolver.swift
//  AgentHub
//
//  Resolves the best agent-provided localhost URL for web preview, falling
//  back to the session JSONL file when monitor state has not populated yet.
//

import Foundation

enum WebPreviewAgentURLResolver {
  static func resolve(
    for session: CLISession,
    detectedLocalhostURL: URL?,
    claudeDataPath: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
  ) async -> URL? {
    if let detectedLocalhostURL,
       let sanitizedURL = LocalhostURLNormalizer.sanitize(detectedLocalhostURL) {
      return sanitizedURL
    }

    guard let sessionFilePath = sessionFilePath(for: session, claudeDataPath: claudeDataPath) else {
      return nil
    }

    return await Task.detached(priority: .utility) {
      guard let content = try? String(contentsOfFile: sessionFilePath, encoding: .utf8) else {
        return nil
      }

      return LocalhostURLNormalizer.extractLastURL(from: content)
    }.value
  }

  static func sessionFilePath(
    for session: CLISession,
    claudeDataPath: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
  ) -> String? {
    if let sessionFilePath = session.sessionFilePath {
      return sessionFilePath
    }

    let encodedPath = session.projectPath.claudeProjectPathEncoded
    return "\(claudeDataPath)/projects/\(encodedPath)/\(session.id).jsonl"
  }
}
