import Foundation

public struct WorktreeSessionCounts: Codable, Equatable, Sendable {
  public let claude: Int
  public let codex: Int

  public init(claude: Int = 0, codex: Int = 0) {
    self.claude = claude
    self.codex = codex
  }

  public var total: Int {
    claude + codex
  }
}

public struct WorktreeSessionCounter: Sendable {
  private let claudeDataPath: String
  private let codexDataPath: String

  public init(
    claudeDataPath: String = "~/.claude",
    codexDataPath: String = "~/.codex"
  ) {
    self.claudeDataPath = (claudeDataPath as NSString).expandingTildeInPath
    self.codexDataPath = (codexDataPath as NSString).expandingTildeInPath
  }

  public func countSessions(for worktrees: [WorktreeInfo]) -> [String: WorktreeSessionCounts] {
    let worktreePaths = worktrees.map { Self.normalizedPath($0.path) }
    guard !worktreePaths.isEmpty else { return [:] }

    var claudeSessionsByWorktree: [String: Set<String>] = [:]
    for session in claudeSessions() {
      guard let worktreePath = Self.bestMatchingWorktree(
        for: session.projectPath,
        in: worktreePaths
      ) else {
        continue
      }
      claudeSessionsByWorktree[worktreePath, default: []].insert(session.id)
    }

    var codexSessionsByWorktree: [String: Set<String>] = [:]
    for session in codexSessions() {
      guard let worktreePath = Self.bestMatchingWorktree(
        for: session.projectPath,
        in: worktreePaths
      ) else {
        continue
      }
      codexSessionsByWorktree[worktreePath, default: []].insert(session.id)
    }

    var counts: [String: WorktreeSessionCounts] = [:]
    for path in worktreePaths {
      counts[path] = WorktreeSessionCounts(
        claude: claudeSessionsByWorktree[path]?.count ?? 0,
        codex: codexSessionsByWorktree[path]?.count ?? 0
      )
    }
    return counts
  }

  private func claudeSessions() -> [(id: String, projectPath: String)] {
    let historyPath = (claudeDataPath as NSString).appendingPathComponent("history.jsonl")
    guard let contents = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
      return []
    }

    var sessions: [(id: String, projectPath: String)] = []
    contents.enumerateLines { line, _ in
      guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = json["sessionId"] as? String,
            let projectPath = json["project"] as? String else {
        return
      }
      sessions.append((id: sessionId, projectPath: projectPath))
    }
    return sessions
  }

  private func codexSessions() -> [(id: String, projectPath: String)] {
    let sessionsRoot = URL(fileURLWithPath: codexDataPath)
      .appendingPathComponent("sessions", isDirectory: true)

    guard let enumerator = FileManager.default.enumerator(
      at: sessionsRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var sessions: [(id: String, projectPath: String)] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "jsonl",
            let session = codexSessionMeta(from: url.path) else {
        continue
      }
      sessions.append(session)
    }
    return sessions
  }

  private func codexSessionMeta(from path: String) -> (id: String, projectPath: String)? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    guard let firstLine = Self.readFirstLine(from: handle),
          let data = firstLine.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "session_meta",
          let payload = json["payload"] as? [String: Any],
          let sessionId = payload["id"] as? String,
          let cwd = payload["cwd"] as? String else {
      return nil
    }

    return (id: sessionId, projectPath: cwd)
  }

  private static func bestMatchingWorktree(for projectPath: String, in worktreePaths: [String]) -> String? {
    let normalizedProjectPath = normalizedPath(projectPath)
    return worktreePaths
      .filter { path in
        normalizedProjectPath == path || normalizedProjectPath.hasPrefix(path + "/")
      }
      .max { $0.count < $1.count }
  }

  private static func normalizedPath(_ path: String) -> String {
    var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private static func readFirstLine(from handle: FileHandle) -> String? {
    let chunkSize = 16_384
    let maxBytes = 262_144
    var data = Data()

    while data.count < maxBytes {
      let remaining = min(chunkSize, maxBytes - data.count)
      guard remaining > 0 else { break }
      guard let chunk = try? handle.read(upToCount: remaining),
            !chunk.isEmpty else {
        break
      }

      if let newlineIndex = chunk.firstIndex(of: 0x0A) {
        data.append(chunk.prefix(upTo: newlineIndex))
        return String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      }

      data.append(chunk)
      if chunk.count < remaining {
        break
      }
    }

    guard !data.isEmpty, data.count < maxBytes else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
  }
}
