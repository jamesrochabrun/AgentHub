//
//  VoiceSessionTranscriptReader.swift
//  AgentHub
//
//  Reads a session's JSONL transcript to recover the latest assistant response
//  text. Monitor state only keeps truncated activity previews, so the voice
//  agent needs this to actually read a session's answer back to the user.
//

import Foundation

public protocol VoiceSessionTranscriptReading: Sendable {
  func latestAssistantText(
    atPath path: String,
    provider: SessionProviderKind
  ) async -> String?

  func recentTurns(
    atPath path: String,
    provider: SessionProviderKind,
    turnLimit: Int
  ) async -> [VoiceTranscriptTurn]
}

public struct VoiceSessionTranscriptReader: VoiceSessionTranscriptReading {
  /// Spoken summaries never need more than this; it also bounds tool payloads
  /// sent to the realtime API.
  public static let maximumCharacters = 4_000
  /// Per-turn cap for history reads: enough to convey a prompt or answer
  /// without flooding the realtime context with a whole essay per turn.
  public static let maximumTurnCharacters = 700
  /// Total cap across all returned turns; oldest turns are dropped first.
  public static let maximumHistoryCharacters = 6_000
  public static let maximumTurnCount = 20

  public init() {}

  public func latestAssistantText(
    atPath path: String,
    provider: SessionProviderKind
  ) async -> String? {
    await Task.detached(priority: .utility) {
      guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
      }
      return Self.extractLatestAssistantText(fromJSONL: content, provider: provider)
    }.value
  }

  public func recentTurns(
    atPath path: String,
    provider: SessionProviderKind,
    turnLimit: Int
  ) async -> [VoiceTranscriptTurn] {
    await Task.detached(priority: .utility) {
      guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
      }
      return Self.extractRecentTurns(
        fromJSONL: content,
        provider: provider,
        turnLimit: turnLimit
      )
    }.value
  }

  public static func extractLatestAssistantText(
    fromJSONL content: String,
    provider: SessionProviderKind
  ) -> String? {
    switch provider {
    case .claude:
      extractLatestClaudeAssistantText(fromJSONL: content)
    case .codex:
      extractLatestCodexAssistantText(fromJSONL: content)
    }
  }

  /// Walks the transcript backwards collecting the trailing run of assistant
  /// text lines — the text after the turn's last tool result, which is the
  /// session's final answer. Assistant lines without text (thinking, tool_use)
  /// are skipped; a user line ends the run once any text has been collected.
  static func extractLatestClaudeAssistantText(fromJSONL content: String) -> String? {
    var collected: [String] = []
    var collectedCount = 0

    for line in content.split(separator: "\n").reversed() {
      guard let object = decodeObject(String(line)) else { continue }
      switch object["type"] as? String {
      case "assistant":
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
          continue
        }
        let texts = blocks.compactMap { block -> String? in
          guard block["type"] as? String == "text" else { return nil }
          return block["text"] as? String
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else { continue }
        collected.insert(text, at: 0)
        collectedCount += text.count
        if collectedCount >= maximumCharacters {
          return truncate(collected.joined(separator: "\n\n"))
        }

      case "user":
        if !collected.isEmpty {
          return truncate(collected.joined(separator: "\n\n"))
        }

      default:
        continue
      }
    }
    return collected.isEmpty
      ? nil
      : truncate(collected.joined(separator: "\n\n"))
  }

  /// Codex rollout files carry one complete `agent_message` payload per turn.
  static func extractLatestCodexAssistantText(fromJSONL content: String) -> String? {
    for line in content.split(separator: "\n").reversed() {
      guard let object = decodeObject(String(line)),
            object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "agent_message",
            let message = payload["message"] as? String else {
        continue
      }
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      return truncate(trimmed)
    }
    return nil
  }

  public static func extractRecentTurns(
    fromJSONL content: String,
    provider: SessionProviderKind,
    turnLimit: Int
  ) -> [VoiceTranscriptTurn] {
    let limit = min(max(1, turnLimit), maximumTurnCount)
    let turns = switch provider {
    case .claude:
      extractRecentClaudeTurns(fromJSONL: content, turnLimit: limit)
    case .codex:
      extractRecentCodexTurns(fromJSONL: content, turnLimit: limit)
    }
    return trimToHistoryBudget(turns)
  }

  /// Consecutive text lines from the same role merge into one turn, so a
  /// multi-line assistant answer reads as a single history entry.
  static func extractRecentClaudeTurns(
    fromJSONL content: String,
    turnLimit: Int
  ) -> [VoiceTranscriptTurn] {
    var turns: [VoiceTranscriptTurn] = []
    var currentRole: String?
    var currentTexts: [String] = []

    func finalizeCurrent() {
      guard let role = currentRole, !currentTexts.isEmpty else { return }
      turns.insert(
        VoiceTranscriptTurn(
          role: role,
          text: truncateTurn(currentTexts.joined(separator: "\n\n"))
        ),
        at: 0
      )
      currentRole = nil
      currentTexts = []
    }

    for line in content.split(separator: "\n").reversed() {
      guard let object = decodeObject(String(line)) else { continue }
      guard let role = object["type"] as? String,
            role == "assistant" || role == "user",
            object["isMeta"] as? Bool != true,
            let text = claudeMessageText(from: object) else {
        continue
      }
      if role == "user", isClaudeCommandNoise(text) { continue }
      if currentRole == role {
        currentTexts.insert(text, at: 0)
      } else {
        finalizeCurrent()
        if turns.count >= turnLimit { break }
        currentRole = role
        currentTexts = [text]
      }
    }
    finalizeCurrent()
    if turns.count > turnLimit {
      turns.removeFirst(turns.count - turnLimit)
    }
    return turns
  }

  static func extractRecentCodexTurns(
    fromJSONL content: String,
    turnLimit: Int
  ) -> [VoiceTranscriptTurn] {
    let roles = ["user_message": "user", "agent_message": "assistant"]
    var turns: [VoiceTranscriptTurn] = []
    for line in content.split(separator: "\n").reversed() {
      guard turns.count < turnLimit else { break }
      guard let object = decodeObject(String(line)),
            object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            let payloadType = payload["type"] as? String,
            let role = roles[payloadType],
            let message = payload["message"] as? String else {
        continue
      }
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !isCodexContextNoise(trimmed) else { continue }
      turns.insert(VoiceTranscriptTurn(role: role, text: truncateTurn(trimmed)), at: 0)
    }
    return turns
  }

  /// Text content of a Claude JSONL line's message: plain-string content or
  /// the joined `text` blocks. Tool results and thinking blocks are excluded.
  private static func claudeMessageText(from object: [String: Any]) -> String? {
    guard let message = object["message"] as? [String: Any] else { return nil }
    let text: String
    if let string = message["content"] as? String {
      text = string
    } else if let blocks = message["content"] as? [[String: Any]] {
      text = blocks.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }.joined(separator: "\n")
    } else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Slash-command echoes and local command output are terminal plumbing,
  /// not something the user said.
  private static func isClaudeCommandNoise(_ text: String) -> Bool {
    text.hasPrefix("<command-") || text.hasPrefix("<local-command")
  }

  /// Codex rollouts replay instruction/environment blocks as user messages.
  private static func isCodexContextNoise(_ text: String) -> Bool {
    text.hasPrefix("<user_instructions>") || text.hasPrefix("<environment_context>")
  }

  private static func trimToHistoryBudget(
    _ turns: [VoiceTranscriptTurn]
  ) -> [VoiceTranscriptTurn] {
    var trimmed = turns
    var total = trimmed.reduce(0) { $0 + $1.text.count }
    while trimmed.count > 1, total > maximumHistoryCharacters {
      total -= trimmed.removeFirst().text.count
    }
    return trimmed
  }

  private static func truncateTurn(_ text: String) -> String {
    guard text.count > maximumTurnCharacters else { return text }
    return String(text.prefix(maximumTurnCharacters)) + "…"
  }

  private static func decodeObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
      return nil
    }
    return object as? [String: Any]
  }

  private static func truncate(_ text: String) -> String {
    guard text.count > maximumCharacters else { return text }
    return String(text.prefix(maximumCharacters)) + "…"
  }
}
