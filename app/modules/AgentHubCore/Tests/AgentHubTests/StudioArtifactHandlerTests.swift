import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("StudioArtifactHandler")
struct StudioArtifactHandlerTests {
  @Test("Routes to the filing provider using the explicit session id — Codex included")
  func routesUsingExplicitSessionId() async throws {
    let claude = StudioArtifactTargetMock()
    let codex = StudioArtifactTargetMock()
    let handler = StudioArtifactHandler(claudeTarget: claude, codexTarget: codex)

    try await handler.handle(makeStudioDocument(id: "doc-1", provider: .codex, sessionId: "codex-session"))

    #expect(claude.stored.isEmpty)
    #expect(codex.stored.map(\.sessionId) == ["codex-session"])
    #expect(codex.stored.first?.artifact.id == "doc-1")
  }

  @Test("Resolves the session by process id when the environment had none")
  func resolvesSessionByProcessId() async throws {
    let claude = StudioArtifactTargetMock(sessionIdsByProcessId: [42: "resolved-session"])
    let handler = StudioArtifactHandler(claudeTarget: claude, codexTarget: StudioArtifactTargetMock())

    try await handler.handle(makeStudioCanvas(provider: .claude, sessionId: nil, processId: 42))

    #expect(claude.stored.map(\.sessionId) == ["resolved-session"])
  }

  @Test("Falls back from a pending session id to process resolution")
  func fallsBackFromPendingSessionId() async throws {
    let claude = StudioArtifactTargetMock(sessionIdsByProcessId: [42: "resolved-session"])
    let handler = StudioArtifactHandler(claudeTarget: claude, codexTarget: StudioArtifactTargetMock())

    try await handler.handle(makeStudioCanvas(provider: .claude, sessionId: "pending-123", processId: 42))

    #expect(claude.stored.map(\.sessionId) == ["resolved-session"])
  }

  @Test("Throws sessionUnavailable when nothing resolves, so the monitor retries")
  func throwsWhenUnresolvable() async {
    let handler = StudioArtifactHandler(claudeTarget: StudioArtifactTargetMock(), codexTarget: StudioArtifactTargetMock())
    await #expect(throws: StudioArtifactHandlingError.self) {
      try await handler.handle(makeStudioCanvas(provider: .claude, sessionId: nil, processId: 1))
    }
    let monitor = StudioArtifactMonitor()
    #expect(await monitor.shouldRetry(StudioArtifactHandlingError.sessionUnavailable, artifact: makeStudioCanvas(createdAt: .now)))
    #expect(!(await monitor.shouldRetry(StudioArtifactHandlingError.sessionUnavailable, artifact: makeStudioCanvas(createdAt: Date(timeIntervalSince1970: 0)))))
  }
}

@MainActor
final class StudioArtifactTargetMock: StudioArtifactTarget {
  struct Stored: Equatable {
    let artifact: StudioArtifact
    let sessionId: String
  }

  var sessionIdsByProcessId: [Int32: String]
  private(set) var stored: [Stored] = []

  init(sessionIdsByProcessId: [Int32: String] = [:]) {
    self.sessionIdsByProcessId = sessionIdsByProcessId
  }

  func activeSessionId(forProcessId processId: Int32) -> String? {
    sessionIdsByProcessId[processId]
  }

  func storeStudioArtifact(_ artifact: StudioArtifact, forSessionId sessionId: String) {
    stored.append(Stored(artifact: artifact, sessionId: sessionId))
  }
}
