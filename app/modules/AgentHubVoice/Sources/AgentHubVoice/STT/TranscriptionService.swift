import Foundation
import SwiftOpenAI

public struct TranscriptionResult: Equatable, Sendable {
  public let text: String
  public let language: String?

  public init(text: String, language: String? = nil) {
    self.text = text
    self.language = language
  }
}

public protocol TranscriptionService: Sendable {
  func transcribe(
    audioData: Data,
    fileName: String,
    model: String,
    responseFormat: String?
  ) async throws -> TranscriptionResult
}

public struct OpenAITranscriptionAdapter: TranscriptionService, @unchecked Sendable {
  private let service: any OpenAIService

  public init(service: any OpenAIService) {
    self.service = service
  }

  public func transcribe(
    audioData: Data,
    fileName: String,
    model: String,
    responseFormat: String?
  ) async throws -> TranscriptionResult {
    let parameters = AudioTranscriptionParameters(
      fileName: fileName,
      file: audioData,
      model: .custom(model: model),
      responseFormat: responseFormat
    )
    let response = try await service.createTranscription(parameters: parameters)
    return TranscriptionResult(text: response.text, language: response.language)
  }
}
