import Foundation

/// Splits a bundled, multi-part prompt into discrete subtasks that can run in parallel.
public protocol TaskDecomposing: Sendable {
  func decompose(prompt: String) -> [Subtask]
}

/// Conservative fallback decomposer. Semantic task inference is performed by the
/// calling agent and passed as structured subtasks; raw natural-language text is
/// never split by punctuation, list markers, or conjunctions here.
public struct SemanticTaskDecomposer: TaskDecomposing {
  public init() {}

  public func decompose(prompt: String) -> [Subtask] {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else { return [] }

    return [
      Subtask(
        id: "task-1",
        title: title(from: trimmedPrompt),
        detail: trimmedPrompt,
        tags: Self.tags(for: trimmedPrompt)
      )
    ]
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
