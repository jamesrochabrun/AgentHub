//
//  CodexSessionFileScanner.swift
//  AgentHub
//
//  Helpers for scanning Codex session files under ~/.codex/sessions.
//

import Foundation

public struct CodexSessionMeta: Sendable {
  public let sessionId: String
  public let projectPath: String
  public let branch: String?
  public let startedAt: Date?
  public let sessionFilePath: String

  public init(
    sessionId: String,
    projectPath: String,
    branch: String?,
    startedAt: Date?,
    sessionFilePath: String
  ) {
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.branch = branch
    self.startedAt = startedAt
    self.sessionFilePath = sessionFilePath
  }
}

public enum CodexSessionFileScanner {
  private static let firstLineChunkSize = 16_384
  private static let maxFirstLineBytes = 262_144

  public static func listSessionFiles(codexDataPath: String) -> [String] {
    let sessionsRoot = (codexDataPath as NSString).expandingTildeInPath + "/sessions"
    let rootURL = URL(fileURLWithPath: sessionsRoot)

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var results: [String] = []

    for case let url as URL in enumerator {
      guard url.pathExtension == "jsonl" else { continue }
      results.append(url.path)
    }

    return results
  }

  public static func readSessionMeta(from path: String) -> CodexSessionMeta? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    guard let firstLine = readFirstLine(from: handle),
          let jsonData = firstLine.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
      return nil
    }

    guard let type = json["type"] as? String, type == "session_meta" else { return nil }
    guard let payload = json["payload"] as? [String: Any] else { return nil }
    guard let sessionId = payload["id"] as? String,
          let cwd = payload["cwd"] as? String else {
      return nil
    }

    let startedAt = parseTimestamp(payload["timestamp"] as? String) ?? parseTimestamp(json["timestamp"] as? String)
    let git = payload["git"] as? [String: Any]
    let branch = git?["branch"] as? String

    return CodexSessionMeta(
      sessionId: sessionId,
      projectPath: cwd,
      branch: branch,
      startedAt: startedAt,
      sessionFilePath: path
    )
  }

  private static func parseTimestamp(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  private static func readFirstLine(from handle: FileHandle) -> String? {
    var data = Data()

    while data.count < maxFirstLineBytes {
      let remaining = min(firstLineChunkSize, maxFirstLineBytes - data.count)
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

    guard !data.isEmpty, data.count < maxFirstLineBytes else {
      return nil
    }

    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
  }
}
