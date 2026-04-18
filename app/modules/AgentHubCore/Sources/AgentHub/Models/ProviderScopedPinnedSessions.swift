import Foundation

/// Snapshot of pinned session IDs keyed by provider.
///
/// Session IDs can overlap across providers, so multi-provider UI must resolve
/// pin state using both provider and session ID instead of a global union.
struct ProviderScopedPinnedSessions: Equatable, Sendable {
  let claudeSessionIds: Set<String>
  let codexSessionIds: Set<String>

  init(
    claudeSessionIds: Set<String> = [],
    codexSessionIds: Set<String> = []
  ) {
    self.claudeSessionIds = claudeSessionIds
    self.codexSessionIds = codexSessionIds
  }

  func contains(sessionId: String, providerKind: SessionProviderKind) -> Bool {
    switch providerKind {
    case .claude:
      return claudeSessionIds.contains(sessionId)
    case .codex:
      return codexSessionIds.contains(sessionId)
    }
  }
}
