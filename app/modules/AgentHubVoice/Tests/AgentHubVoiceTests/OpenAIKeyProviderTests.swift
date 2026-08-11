import Testing
@testable import AgentHubVoice

struct OpenAIKeyProviderTests {
  @Test
  func keychainWinsOverEnvironment() async throws {
    let store = InMemorySecretsStore(
      values: [OpenAIKeyProvider.account: "stored-key"]
    )
    let provider = OpenAIKeyProvider(store: store) { _ in "environment-key" }

    let resolution = try await provider.resolve()

    #expect(resolution == .init(key: "stored-key", source: .keychain))
  }

  @Test
  func fallsBackToEnvironment() async throws {
    let provider = OpenAIKeyProvider(store: InMemorySecretsStore()) { name in
      name == "OPENAI_API_KEY" ? "environment-key" : nil
    }

    let resolution = try await provider.resolve()

    #expect(resolution == .init(key: "environment-key", source: .environment))
  }

  @Test
  func savingBlankDeletesStoredKey() async throws {
    let store = InMemorySecretsStore(
      values: [OpenAIKeyProvider.account: "stored-key"]
    )
    let provider = OpenAIKeyProvider(store: store) { _ in nil }

    try await provider.save(" ")

    #expect(try await provider.resolve() == nil)
  }
}
