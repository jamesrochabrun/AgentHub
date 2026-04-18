import Testing

@testable import AgentHubCore

@Suite("Provider-scoped pinned sessions")
struct ProviderScopedPinnedSessionsTests {

  @Test("Pin state is resolved by provider and session ID")
  func resolvesByProviderAndSessionId() {
    let snapshot = ProviderScopedPinnedSessions(
      claudeSessionIds: ["shared-session", "claude-only"],
      codexSessionIds: ["codex-only"]
    )

    #expect(snapshot.contains(sessionId: "shared-session", providerKind: .claude))
    #expect(!snapshot.contains(sessionId: "shared-session", providerKind: .codex))
    #expect(snapshot.contains(sessionId: "codex-only", providerKind: .codex))
    #expect(!snapshot.contains(sessionId: "codex-only", providerKind: .claude))
  }
}
