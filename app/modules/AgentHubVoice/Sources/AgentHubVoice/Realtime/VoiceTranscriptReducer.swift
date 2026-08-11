import Foundation

public enum VoiceTranscriptEvent: Equatable, Sendable {
  case userDelta(String)
  case userCompleted(String)
  case assistantDelta(String)
  case assistantCompleted(String)
  case system(String)
  case tool(String)
}

public struct VoiceTranscriptReducer: Sendable {
  public private(set) var entries: [VoiceTranscriptEntry]

  public init(entries: [VoiceTranscriptEntry] = []) {
    self.entries = entries
  }

  public mutating func reduce(_ event: VoiceTranscriptEvent, at date: Date = Date()) {
    switch event {
    case .userDelta(let text):
      appendPartial(text, role: .user, at: date)
    case .assistantDelta(let text):
      appendPartial(text, role: .assistant, at: date)
    case .userCompleted(let text):
      complete(text, role: .user, at: date)
    case .assistantCompleted(let text):
      complete(text, role: .assistant, at: date)
    case .system(let text):
      appendCompleted(text, role: .system, at: date)
    case .tool(let text):
      appendCompleted(text, role: .tool, at: date)
    }
  }

  private mutating func appendPartial(
    _ delta: String,
    role: VoiceTranscriptRole,
    at date: Date
  ) {
    guard !delta.isEmpty else { return }
    if let index = entries.indices.last,
       entries[index].role == role,
       entries[index].isPartial {
      entries[index].text += delta
    } else {
      entries.append(
        VoiceTranscriptEntry(role: role, text: delta, isPartial: true, timestamp: date)
      )
    }
  }

  private mutating func complete(
    _ text: String,
    role: VoiceTranscriptRole,
    at date: Date
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let index = entries.indices.last,
       entries[index].role == role,
       entries[index].isPartial {
      entries[index].text = trimmed
      entries[index].isPartial = false
    } else {
      appendCompleted(trimmed, role: role, at: date)
    }
  }

  private mutating func appendCompleted(
    _ text: String,
    role: VoiceTranscriptRole,
    at date: Date
  ) {
    guard !text.isEmpty else { return }
    entries.append(
      VoiceTranscriptEntry(role: role, text: text, timestamp: date)
    )
  }
}
