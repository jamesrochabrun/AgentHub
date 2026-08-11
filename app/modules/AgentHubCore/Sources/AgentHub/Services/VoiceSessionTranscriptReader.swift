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
}

public struct VoiceSessionTranscriptReader: VoiceSessionTranscriptReading {
  /// Spoken summaries never need more than this; it also bounds tool payloads
  /// sent to the realtime API.
  public static let maximumCharacters = 4_000

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
