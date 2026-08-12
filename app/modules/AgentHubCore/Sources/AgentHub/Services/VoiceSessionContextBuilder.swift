//
//  VoiceSessionContextBuilder.swift
//  AgentHub
//
//  Builds the compact session roster injected into the realtime voice
//  instructions at connect time. Names and statuses only — no session IDs,
//  so the model still has to call list_sessions before acting, and the
//  snapshot stays cheap in model context.
//

import Foundation

public enum VoiceSessionContextBuilder {
  public static let maximumSessions = 10
  public static let maximumCharacters = 1_000

  public static func make(summary: VoiceSessionsSummary) -> String? {
    guard !summary.sessions.isEmpty else { return nil }
    let ordered = summary.sessions.sorted {
      $0.secondsSinceActivity < $1.secondsSinceActivity
    }
    let count = ordered.count
    var lines = ["\(count) session\(count == 1 ? "" : "s"):"]
    var total = lines[0].count
    var included = 0
    for session in ordered.prefix(maximumSessions) {
      let line = describe(session, isTarget: session.id == summary.targetSessionId)
      guard total + line.count <= maximumCharacters else { break }
      lines.append(line)
      total += line.count
      included += 1
    }
    guard included > 0 else { return nil }
    if count > included {
      lines.append("…and \(count - included) more.")
    }
    return lines.joined(separator: "\n")
  }

  private static func describe(
    _ session: VoiceSessionSummary,
    isTarget: Bool
  ) -> String {
    let repo = (session.worktree as NSString).lastPathComponent
    var line = "- \(session.name) (\(session.provider.rawValue), \(repo), \(session.status))"
    if session.pendingApprovalTool != nil {
      line += ", needs approval"
    }
    if isTarget {
      line += " — current target"
    }
    return line
  }
}
