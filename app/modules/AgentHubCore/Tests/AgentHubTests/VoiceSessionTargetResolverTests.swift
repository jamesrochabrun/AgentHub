import Foundation
import Testing
@testable import AgentHubCore

@MainActor
private final class MockVoiceTargetSource: VoiceSessionTargetSource {
  let providerKind: SessionProviderKind
  var voiceTargetCandidates: [VoiceSessionTarget]
  var lastFocusedSessionId: String?
  var lastFocusedSessionAt: Date?

  init(
    provider: SessionProviderKind,
    targets: [VoiceSessionTarget]
  ) {
    providerKind = provider
    voiceTargetCandidates = targets
  }
}

@MainActor
struct VoiceSessionTargetResolverTests {
  @Test
  func priorityIsManualThenNewestFocusThenRouterThenActivity() {
    let base = Date(timeIntervalSince1970: 1_000)
    let claudeTarget = target(
      id: "claude",
      provider: .claude,
      date: base.addingTimeInterval(10)
    )
    let codexTarget = target(
      id: "codex",
      provider: .codex,
      date: base.addingTimeInterval(20)
    )
    let claude = MockVoiceTargetSource(
      provider: .claude,
      targets: [claudeTarget]
    )
    let codex = MockVoiceTargetSource(
      provider: .codex,
      targets: [codexTarget]
    )
    let router = GlobalSessionSelectionRouter()
    router.select(
      providerKind: .claude,
      sessionId: "claude",
      projectPath: "/repo/claude"
    )
    let resolver = VoiceSessionTargetResolver(
      claudeViewModel: claude,
      codexViewModel: codex,
      selectionRouter: router
    )

    #expect(resolver.resolve(manualSessionId: "codex") == codexTarget)

    claude.lastFocusedSessionId = "claude"
    claude.lastFocusedSessionAt = base.addingTimeInterval(30)
    codex.lastFocusedSessionId = "codex"
    codex.lastFocusedSessionAt = base.addingTimeInterval(40)
    #expect(resolver.resolve(manualSessionId: nil) == codexTarget)

    claude.lastFocusedSessionId = nil
    codex.lastFocusedSessionId = nil
    #expect(resolver.resolve(manualSessionId: nil) == claudeTarget)

    if let request = router.selectionRequest {
      router.markConsumed(request)
    }
    #expect(resolver.resolve(manualSessionId: nil) == codexTarget)
  }

  private func target(
    id: String,
    provider: SessionProviderKind,
    date: Date
  ) -> VoiceSessionTarget {
    .init(
      sessionId: id,
      provider: provider,
      name: id,
      projectPath: "/repo/\(id)",
      lastActivityAt: date
    )
  }
}
