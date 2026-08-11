import Foundation

public enum VoiceEngineState: Equatable, Sendable {
  case disconnected
  case connecting
  case idle
  case userSpeaking
  case thinking
  case speaking
  case executingTool(String)
  case failed(String)
}

public enum VoiceTranscriptRole: String, Codable, Sendable {
  case user
  case assistant
  case system
  case tool
}

public struct VoiceTranscriptEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let role: VoiceTranscriptRole
  public var text: String
  public var isPartial: Bool
  public let timestamp: Date

  public init(
    id: UUID = UUID(),
    role: VoiceTranscriptRole,
    text: String,
    isPartial: Bool = false,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isPartial = isPartial
    self.timestamp = timestamp
  }
}

public struct VoiceEngineSettings: Equatable, Sendable {
  public var model: String
  public var voiceName: String
  public var vadEagerness: String
  public var dictationModel: String
  /// ISO-639-1 code pinning the conversation language (nil = automatic).
  /// Pinning prevents language flapping when echo or noise reaches the mic.
  public var language: String?
  /// When false the engine mutes the microphone while the assistant's audio
  /// is playing (half-duplex), so speaker echo can never interrupt a reply.
  /// Enable only when echo cancellation is reliable (e.g. with headphones).
  public var allowBargeIn: Bool

  public init(
    model: String = "gpt-realtime",
    voiceName: String = "marin",
    vadEagerness: String = "medium",
    dictationModel: String = "whisper-1",
    language: String? = nil,
    allowBargeIn: Bool = false
  ) {
    self.model = model
    self.voiceName = voiceName
    self.vadEagerness = vadEagerness
    self.dictationModel = dictationModel
    self.language = language
    self.allowBargeIn = allowBargeIn
  }
}
