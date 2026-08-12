import Foundation
import Testing
@testable import AgentHubCore

struct VoiceSessionContextBuilderTests {
  @Test
  func emptySummaryProducesNoContext() {
    let context = VoiceSessionContextBuilder.make(
      summary: VoiceSessionsSummary(sessions: [], targetSessionId: nil)
    )
    #expect(context == nil)
  }

  @Test
  func listsSessionsMostRecentFirstWithTargetAndApprovalMarkers() throws {
    let summary = VoiceSessionsSummary(
      sessions: [
        session(
          id: "old",
          name: "Refactor",
          worktree: "/repos/agenthub-refactor",
          status: "Idle",
          secondsSinceActivity: 900
        ),
        session(
          id: "busy",
          name: "Fix login",
          worktree: "/repos/agenthub",
          status: "Thinking",
          pendingApprovalTool: "Bash",
          secondsSinceActivity: 5
        ),
      ],
      targetSessionId: "busy"
    )

    let context = try #require(VoiceSessionContextBuilder.make(summary: summary))
    let lines = context.split(separator: "\n").map(String.init)

    #expect(lines[0] == "2 sessions:")
    #expect(
      lines[1]
        == "- Fix login (Claude, agenthub, Thinking), needs approval — current target"
    )
    #expect(lines[2] == "- Refactor (Claude, agenthub-refactor, Idle)")
    #expect(!context.contains("busy"))
  }

  @Test
  func capsSessionCountAndReportsOmissions() throws {
    let sessions = (1...14).map { index in
      session(
        id: "s\(index)",
        name: "Session \(index)",
        worktree: "/repos/repo\(index)",
        status: "Idle",
        secondsSinceActivity: index
      )
    }
    let summary = VoiceSessionsSummary(sessions: sessions, targetSessionId: nil)

    let context = try #require(VoiceSessionContextBuilder.make(summary: summary))

    #expect(context.hasPrefix("14 sessions:"))
    #expect(context.contains("Session 10"))
    #expect(!context.contains("Session 11"))
    #expect(context.hasSuffix("…and 4 more."))
  }

  @Test
  func staysWithinCharacterBudget() throws {
    let sessions = (1...10).map { index in
      session(
        id: "s\(index)",
        name: String(repeating: "n", count: 200) + "\(index)",
        worktree: "/repos/repo",
        status: "Idle",
        secondsSinceActivity: index
      )
    }
    let summary = VoiceSessionsSummary(sessions: sessions, targetSessionId: nil)

    let context = try #require(VoiceSessionContextBuilder.make(summary: summary))

    #expect(context.count
      <= VoiceSessionContextBuilder.maximumCharacters + "…and 9 more.".count + 1)
    #expect(context.contains("…and"))
  }

  private func session(
    id: String,
    name: String,
    worktree: String,
    status: String,
    pendingApprovalTool: String? = nil,
    secondsSinceActivity: Int
  ) -> VoiceSessionSummary {
    VoiceSessionSummary(
      id: id,
      name: name,
      provider: .claude,
      worktree: worktree,
      status: status,
      pendingApprovalTool: pendingApprovalTool,
      secondsSinceActivity: secondsSinceActivity,
      localhostURL: nil
    )
  }
}
