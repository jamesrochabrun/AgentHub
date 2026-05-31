import Foundation

/// Splits a bundled, multi-part prompt into discrete subtasks that can run in parallel.
public protocol TaskDecomposing: Sendable {
  func decompose(prompt: String) -> [Subtask]
}

/// Heuristic decomposer: prefers explicit list structure (numbered / bulleted lines),
/// then falls back to conjunction- and sentence-level splitting. Each resulting segment
/// becomes a tagged subtask. Pure and deterministic so it is fully unit-testable.
public struct HeuristicTaskDecomposer: TaskDecomposing {
  public init() {}

  public func decompose(prompt: String) -> [Subtask] {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else { return [] }

    let segments = listSegments(in: trimmedPrompt) ?? conjunctionSegments(in: trimmedPrompt)
    let cleaned = segments
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let effective = cleaned.isEmpty ? [trimmedPrompt] : cleaned
    return effective.enumerated().map { index, segment in
      Subtask(
        id: "task-\(index + 1)",
        title: title(from: segment),
        detail: segment,
        tags: Self.tags(for: segment)
      )
    }
  }

  /// Splits on lines that begin with a list marker (`1.`, `2)`, `-`, `*`, `•`).
  /// Returns `nil` when fewer than two list items are present so the caller can fall back.
  private func listSegments(in prompt: String) -> [String]? {
    let lines = prompt.components(separatedBy: .newlines)
    var items: [String] = []
    var current: String?

    func flush() {
      if let value = current?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        items.append(value)
      }
      current = nil
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let stripped = strippedListMarker(trimmed) {
        flush()
        current = stripped
      } else if !trimmed.isEmpty, current != nil {
        // Continuation line of the current list item.
        current! += " " + trimmed
      }
    }
    flush()

    return items.count >= 2 ? items : nil
  }

  /// Removes a leading list marker, returning the item text, or `nil` if not a list line.
  private func strippedListMarker(_ line: String) -> String? {
    if let match = line.firstMatch(of: #/^(\d+)[\.\)]\s+(.+)$/#) {
      return String(match.2)
    }
    if let match = line.firstMatch(of: #/^[-*•]\s+(.+)$/#) {
      return String(match.1)
    }
    return nil
  }

  /// Fallback splitter for prose: breaks on `;`, newlines, and the conjunctions
  /// ", and ", " then ", " also " / " and also ".
  private func conjunctionSegments(in prompt: String) -> [String] {
    let separators = [";", "\n", ", and ", " and then ", " then ", ", also ", " and also "]
    var segments = [prompt]
    for separator in separators {
      segments = segments.flatMap { $0.components(separatedBy: separator) }
    }
    return segments
  }

  private func title(from segment: String) -> String {
    let words = segment
      .replacingOccurrences(of: "\n", with: " ")
      .split(separator: " ")
      .prefix(8)
    let joined = words.joined(separator: " ")
    let stripped = joined.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    return stripped.isEmpty ? segment : stripped
  }

  static func tags(for segment: String) -> [CapabilityTag] {
    let tags = CapabilityTag.tags(in: segment)
    // Default to coding for a developer-oriented tool when nothing else matches.
    return tags.isEmpty ? [.coding] : tags
  }
}
