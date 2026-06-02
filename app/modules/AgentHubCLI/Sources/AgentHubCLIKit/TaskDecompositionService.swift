import Foundation

/// Splits a bundled, multi-part prompt into discrete subtasks that can run in parallel.
public protocol TaskDecomposing: Sendable {
  func decompose(prompt: String) -> [Subtask]
}

/// Conservative fallback decomposer. Semantic task inference is performed by the
/// calling agent and passed as structured subtasks; raw natural-language text is
/// never split by punctuation or conjunctions here. Explicit numbered/bulleted
/// task lists are split because they represent intentional user structure.
public struct SemanticTaskDecomposer: TaskDecomposing {
  public init() {}

  public func decompose(prompt: String) -> [Subtask] {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else { return [] }

    let segments = explicitListSegments(in: trimmedPrompt) ?? [trimmedPrompt]
    return segments.enumerated().map { index, segment in
      Subtask(
        id: "task-\(index + 1)",
        title: title(from: segment),
        detail: segment,
        tags: Self.tags(for: segment)
      )
    }
  }

  private func explicitListSegments(in prompt: String) -> [String]? {
    var segments: [String] = []
    var currentLines: [String] = []

    func flushCurrent() {
      guard !currentLines.isEmpty else { return }
      let segment = currentLines
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !segment.isEmpty {
        segments.append(segment)
      }
      currentLines.removeAll()
    }

    for line in prompt.components(separatedBy: .newlines) {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      guard !trimmedLine.isEmpty else { continue }

      if let item = strippedListMarker(from: trimmedLine) {
        flushCurrent()
        currentLines = [item]
      } else if !currentLines.isEmpty {
        currentLines.append(trimmedLine)
      }
    }

    flushCurrent()
    return segments.count >= 2 ? segments : nil
  }

  private func strippedListMarker(from line: String) -> String? {
    if let match = line.firstMatch(of: #/^\d+[\.\)]\s+(.+)$/#) {
      return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if line.hasPrefix("- ") || line.hasPrefix("* ") {
      return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let first = line.unicodeScalars.first, first.value == 0x2022 {
      let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
      return rest.isEmpty ? nil : rest
    }

    return nil
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
