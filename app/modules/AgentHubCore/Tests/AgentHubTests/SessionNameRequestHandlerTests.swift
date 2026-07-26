import AgentHubCLIKit
import Testing

@testable import AgentHubCore

@MainActor
@Suite("SessionNameRequestHandler")
struct SessionNameRequestHandlerTests {
  @Test("Uses explicit session ID and selected provider")
  func usesExplicitSessionId() async throws {
    let claude = SessionNameRequestTargetMock()
    let codex = SessionNameRequestTargetMock()
    let handler = SessionNameRequestHandler(claudeTarget: claude, codexTarget: codex)

    try await handler.handle(SessionNameRequest(
      name: "  Naming Tools  ",
      sourceProvider: .codex,
      sourceSessionId: "codex-session",
      sourceProcessId: 42
    ))

    #expect(claude.updates.isEmpty)
    #expect(codex.updates == [.init(name: "naming-tools", sessionId: "codex-session")])
  }

  @Test("Resolves new sessions by embedded process ID")
  func resolvesSessionByProcessId() async throws {
    let claude = SessionNameRequestTargetMock(sessionIdsByProcessId: [84: "resolved-session"])
    let codex = SessionNameRequestTargetMock()
    let handler = SessionNameRequestHandler(claudeTarget: claude, codexTarget: codex)

    try await handler.handle(SessionNameRequest(
      name: "New Session Name",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 84
    ))

    #expect(claude.updates == [.init(name: "new-session-name", sessionId: "resolved-session")])
    #expect(codex.updates.isEmpty)
  }

  @Test("Falls back from a pending session ID to process resolution")
  func resolvesPendingSessionByProcessId() async throws {
    let claude = SessionNameRequestTargetMock(sessionIdsByProcessId: [84: "resolved-session"])
    let handler = SessionNameRequestHandler(
      claudeTarget: claude,
      codexTarget: SessionNameRequestTargetMock()
    )

    try await handler.handle(SessionNameRequest(
      name: "Fresh Claude Session",
      sourceProvider: .claude,
      sourceSessionId: "pending-launch",
      sourceProcessId: 84
    ))

    #expect(claude.updates == [.init(name: "fresh-claude-session", sessionId: "resolved-session")])
  }

  @Test("Matches a CLI child process to its terminal process group")
  func matchesProcessGroup() {
    let candidates = [
      SessionProcessGroupMatcher.Candidate(sessionId: "other", processId: 10),
      SessionProcessGroupMatcher.Candidate(sessionId: "claude-session", processId: 20),
    ]
    let processGroups: [Int32: Int32] = [
      10: 10,
      20: 20,
      21: 20,
    ]

    let sessionId = SessionProcessGroupMatcher.sessionId(
      for: 21,
      candidates: candidates,
      processGroupId: { processGroups[$0] }
    )

    #expect(sessionId == "claude-session")
  }

  @Test("Rejects unresolved and empty session names")
  func rejectsInvalidRequests() async {
    let target = SessionNameRequestTargetMock()
    let handler = SessionNameRequestHandler(claudeTarget: target, codexTarget: target)

    await #expect(throws: SessionNameRequestHandlingError.self) {
      try await handler.handle(SessionNameRequest(
        name: " ",
        sourceProvider: .claude,
        sourceSessionId: "session-1",
        sourceProcessId: 1
      ))
    }
    await #expect(throws: SessionNameRequestHandlingError.self) {
      try await handler.handle(SessionNameRequest(
        name: "Valid",
        sourceProvider: .claude,
        sourceSessionId: nil,
        sourceProcessId: 1
      ))
    }
  }
}

@MainActor
private final class SessionNameRequestTargetMock: SessionNameRequestTarget {
  struct Update: Equatable {
    let name: String?
    let sessionId: String
  }

  let sessionIdsByProcessId: [Int32: String]
  private(set) var updates: [Update] = []

  init(sessionIdsByProcessId: [Int32: String] = [:]) {
    self.sessionIdsByProcessId = sessionIdsByProcessId
  }

  func activeSessionId(forProcessId processId: Int32) -> String? {
    sessionIdsByProcessId[processId]
  }

  func setCustomName(_ name: String?, forSessionId sessionId: String) {
    updates.append(Update(name: name, sessionId: sessionId))
  }
}
