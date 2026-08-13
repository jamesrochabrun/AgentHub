import Foundation
import Testing

@testable import AgentHubCore

@Suite("Model context window resolver")
struct ModelContextWindowResolverTests {

  private let codexWindows = ["gpt-5.6-sol": 272_000, "gpt-5.6-luna": 272_000]

  @Test("No model resolves to the conservative default")
  func nilModelUsesDefault() {
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: nil, codexWindows: codexWindows)
        == ModelContextWindowResolver.conservativeDefaultTokens)
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "  ", codexWindows: codexWindows)
        == ModelContextWindowResolver.conservativeDefaultTokens)
  }

  @Test("Plain Claude ids run the standard 200K window")
  func plainClaudeIdsUseStandardWindow() {
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "claude-opus-4-8", codexWindows: [:])
        == 200_000)
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "claude-haiku-4-5-20251001", codexWindows: [:])
        == 200_000)
  }

  @Test("The [1m] beta suffix resolves to a 1M window")
  func oneMillionSuffix() {
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "claude-sonnet-4-5[1m]", codexWindows: [:])
        == 1_000_000)
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "Claude-Opus-4-8[1M]", codexWindows: [:])
        == 1_000_000)
  }

  @Test("Codex models resolve from the cached per-model window")
  func codexCacheLookup() {
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "gpt-5.6-sol", codexWindows: codexWindows)
        == 272_000)
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "GPT-5.6-Sol", codexWindows: codexWindows)
        == 272_000)
  }

  @Test("Unknown models fall back conservatively")
  func unknownModelFallsBack() {
    #expect(
      ModelContextWindowResolver.window(forModelIdentifier: "gpt-9-experimental", codexWindows: codexWindows)
        == ModelContextWindowResolver.conservativeDefaultTokens)
  }
}
