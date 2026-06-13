import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionInvestigationService")
struct SessionInvestigationServiceTests {

  @Test("Claude JSON output is parsed and overview comes from snapshot")
  func claudeJSONOutputIsParsed() async throws {
    let programmatic = StubInvestigationProgrammaticService(output: """
    {
      "narrative": "Two sessions are ready to review.",
      "findings": [
        {
          "title": "Scale",
          "detail": "Small session set.",
          "severity": "info",
          "provider": null,
          "sessionIds": [],
          "projectPath": null,
          "worktreePath": null
        }
      ],
      "actions": [
        {
          "title": "Verify feature/a",
          "detail": "Check tests before merge.",
          "category": "mergeCandidate",
          "confidence": "low",
          "provider": "Claude",
          "sessionIds": ["s1"],
          "projectPath": "/tmp/repo",
          "worktreePath": "/tmp/repo-feature"
        }
      ]
    }
    """)
    let service = ClaudeSessionInvestigationService(programmaticService: programmatic)

    let report = try await service.investigate(snapshot: makeSnapshot())

    #expect(report.source == .claude)
    #expect(report.overview.sessionCount == 2)
    #expect(report.overview.worktreeCount == 1)
    #expect(report.narrative == "Two sessions are ready to review.")
    #expect(report.actions.first?.category == .mergeCandidate)

    let request = try #require(await programmatic.lastRequest())
    #expect(request.disallowedTools?.contains("Bash") == true)
    #expect(request.userPrompt.contains("\"sessionFilePath\""))
  }

  @Test("Malformed Claude output falls back deterministically")
  func malformedClaudeOutputFallsBack() async throws {
    let programmatic = StubInvestigationProgrammaticService(output: "Here is the report in prose.")
    let service = ClaudeSessionInvestigationService(programmaticService: programmatic)

    let report = try await service.investigate(snapshot: makeSnapshot())

    #expect(report.source == .deterministicFallback)
    #expect(report.rawModelOutput == "Here is the report in prose.")
    #expect(report.findings.contains { $0.title == "Session scale" })
    #expect(report.actions.contains { $0.category == .deleteWorktreeCandidate })
  }

  @Test("Parser accepts fenced JSON")
  func parserAcceptsFencedJSON() {
    let parsed = SessionInvestigationReportParser.parse("""
    ```json
    {
      "narrative": "Done",
      "findings": [],
      "actions": []
    }
    ```
    """)

    #expect(parsed?.narrative == "Done")
    #expect(parsed?.findings.isEmpty == true)
  }

  @Test("MCP UI resource uses app MIME type and escapes report text")
  func mcpUIResourceEscapesHTML() {
    let report = SessionInvestigationReport(
      source: .deterministicFallback,
      overview: makeSnapshot().overview,
      narrative: "Review <script>alert(1)</script>",
      findings: [],
      actions: []
    )

    let resource = SessionInvestigationMCPUIResourceBuilder.makeResource(
      report: report,
      snapshot: makeSnapshot()
    )

    #expect(resource.uri.hasPrefix("ui://agenthub/session-investigation/"))
    #expect(resource.mimeType == "text/html;profile=mcp-app")
    #expect(resource.text.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(!resource.text.contains("<script>alert(1)</script>"))
  }

  private func makeSnapshot() -> SessionInvestigationSnapshot {
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return SessionInvestigationSnapshot(
      generatedAt: generatedAt,
      repositories: [
        SessionInvestigationRepositorySnapshot(
          name: "repo",
          path: "/tmp/repo",
          worktreeCount: 1,
          sessionCount: 2
        )
      ],
      worktrees: [
        SessionInvestigationWorktreeSnapshot(
          name: "feature-a",
          path: "/tmp/repo-feature",
          repositoryPath: "/tmp/repo",
          isWorktree: true,
          sessionCount: 1,
          activeSessionCount: 0,
          latestActivityAt: generatedAt.addingTimeInterval(-3600)
        )
      ],
      sessions: [
        SessionInvestigationSessionSnapshot(
          id: "s1",
          provider: .claude,
          displayName: "alpha",
          projectPath: "/tmp/repo-feature",
          repositoryPath: "/tmp/repo",
          worktreePath: "/tmp/repo-feature",
          branchName: "feature/a",
          isWorktree: true,
          isActive: false,
          isMonitored: true,
          status: "Ready",
          currentTool: nil,
          model: "haiku",
          inputTokens: 1200,
          outputTokens: 200,
          contextUsagePercent: 0.6,
          messageCount: 8,
          lastActivityAt: generatedAt,
          firstMessagePreview: "Build this",
          lastMessagePreview: "Done",
          sessionFilePath: "/tmp/session.jsonl",
          sessionFileExists: true,
          sessionFileByteCount: 2048,
          sessionFileModifiedAt: generatedAt,
          localhostURL: nil,
          isAwaitingApproval: false
        ),
        SessionInvestigationSessionSnapshot(
          id: "s2",
          provider: .codex,
          displayName: "beta",
          projectPath: "/tmp/repo",
          repositoryPath: "/tmp/repo",
          worktreePath: nil,
          branchName: "main",
          isWorktree: false,
          isActive: true,
          isMonitored: false,
          status: nil,
          currentTool: nil,
          model: nil,
          inputTokens: 0,
          outputTokens: 0,
          contextUsagePercent: nil,
          messageCount: 2,
          lastActivityAt: generatedAt,
          firstMessagePreview: nil,
          lastMessagePreview: nil,
          sessionFilePath: nil,
          sessionFileExists: false,
          sessionFileByteCount: nil,
          sessionFileModifiedAt: nil,
          localhostURL: nil,
          isAwaitingApproval: false
        )
      ]
    )
  }
}

private actor StubInvestigationProgrammaticService: ClaudeProgrammaticServiceProtocol {
  private let output: String
  private var capturedRequest: ClaudeProgrammaticRequest?
  private(set) var cancelCount = 0

  init(output: String) {
    self.output = output
  }

  func run(
    _ request: ClaudeProgrammaticRequest,
    onModelAttempt: (@Sendable (String) -> Void)?
  ) async throws -> String {
    capturedRequest = request
    onModelAttempt?(request.models.first ?? "unknown")
    return output
  }

  func cancelActiveRequest() async {
    cancelCount += 1
  }

  func lastRequest() -> ClaudeProgrammaticRequest? {
    capturedRequest
  }
}
