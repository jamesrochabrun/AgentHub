import Foundation

public enum OpenAIKeySource: String, Sendable {
  case keychain
  case environment
}

public struct OpenAIKeyResolution: Equatable, Sendable {
  public let key: String
  public let source: OpenAIKeySource

  public init(key: String, source: OpenAIKeySource) {
    self.key = key
    self.source = source
  }
}

public protocol OpenAIKeyProviding: Sendable {
  func resolve() async throws -> OpenAIKeyResolution?
  func save(_ key: String) async throws
}

public actor OpenAIKeyProvider: OpenAIKeyProviding {
  public static let account = "openai-api-key"

  private let store: any SecretsStoring
  private let environmentValue: @Sendable (String) -> String?

  public init(
    store: any SecretsStoring,
    environmentValue: @escaping @Sendable (String) -> String? = {
      ProcessInfo.processInfo.environment[$0]
    }
  ) {
    self.store = store
    self.environmentValue = environmentValue
  }

  public func resolve() async throws -> OpenAIKeyResolution? {
    if let stored = try await store.value(for: Self.account),
       !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return OpenAIKeyResolution(key: stored, source: .keychain)
    }
    if let environment = environmentValue("OPENAI_API_KEY"),
       !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return OpenAIKeyResolution(key: environment, source: .environment)
    }
    return nil
  }

  public func save(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try await store.deleteValue(for: Self.account)
    } else {
      try await store.setValue(trimmed, for: Self.account)
    }
  }
}
