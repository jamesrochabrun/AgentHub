import Foundation
import Testing

@testable import AgentHubCore

@Suite("PlanState")
struct PlanStateTests {

  @Test("Detects plan file from compacted write activity")
  func detectsPlanFileFromCompactedWriteActivity() {
    let activities = [
      ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 1),
        type: .toolUse(name: "Write"),
        description: "plan.md",
        toolInput: CodeChangeInput(
          toolType: .write,
          filePath: "/Users/test/.claude/plans/feature-plan.md"
        )
      ),
      ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 2),
        type: .assistantMessage,
        description: "Done"
      )
    ]

    let planState = PlanState.from(activities: activities)

    #expect(planState?.filePath == "/Users/test/.claude/plans/feature-plan.md")
    #expect(planState?.fileName == "feature-plan.md")
  }

  @Test("Ignores non-plan tool activity")
  func ignoresNonPlanToolActivity() {
    let activities = [
      ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 1),
        type: .toolUse(name: "Edit"),
        description: "SessionFileWatcher.swift",
        toolInput: CodeChangeInput(
          toolType: .edit,
          filePath: "/Users/test/project/SessionFileWatcher.swift"
        )
      )
    ]

    #expect(PlanState.from(activities: activities) == nil)
  }
}
