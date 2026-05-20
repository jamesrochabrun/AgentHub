import Foundation
import Testing

@testable import AgentHubCore

@Suite("MonitoringAutoOpenSidePanelPolicy")
struct MonitoringAutoOpenSidePanelPolicyTests {
  @Test("Returns no candidate outside single layout")
  func returnsNoCandidateOutsideSingleLayout() {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .list,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    )

    #expect(candidate == nil)
  }

  @Test("Returns no candidate while maximized")
  func returnsNoCandidateWhileMaximized() {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: "session-1",
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    )

    #expect(candidate == nil)
  }

  @Test("Returns no candidate while module landing is active")
  func returnsNoCandidateWhileModuleLandingIsActive() {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: "/tmp/project",
      visibleItem: item,
      openedKeys: []
    )

    #expect(candidate == nil)
  }

  @Test("Returns edits candidate for code change pending tool")
  func returnsEditsCandidateForCodeChangePendingTool() throws {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    ))

    #expect(candidate.itemID == "claude-session-1")
    #expect(candidate.target == .edits)
    #expect(candidate.key == .edits(
      providerKind: .claude,
      sessionID: "session-1",
      toolUseId: "edit-1"
    ))
  }

  @Test("Returns plan candidate for detected plan file")
  func returnsPlanCandidateForDetectedPlanFile() throws {
    let path = "/Users/test/.claude/plans/feature-plan.md"
    let item = Self.item(state: Self.planFileState(filePath: path))

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    ))

    #expect(candidate.target == .plan(PlanState(filePath: path)))
    #expect(candidate.key == .plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path
    ))
  }

  @Test("Prefers edits when edits and plan are both available")
  func prefersEditsWhenEditsAndPlanAreBothAvailable() throws {
    let item = Self.item(state: SessionMonitorState(
      pendingToolUse: PendingToolUse(
        toolName: "MultiEdit",
        toolUseId: "edit-1",
        timestamp: Date(timeIntervalSince1970: 1)
      ),
      recentActivities: Self.planActivities(
        filePath: "/Users/test/.claude/plans/feature-plan.md"
      )
    ))

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    ))

    #expect(candidate.target == .edits)
    #expect(candidate.key.kind == .edits)
  }

  @Test("Suppresses an edits candidate after the same tool use was opened")
  func suppressesSameEditsKeyAfterOpen() {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))
    let openedKey = MonitoringAutoOpenSidePanelKey.edits(
      providerKind: .claude,
      sessionID: "session-1",
      toolUseId: "edit-1"
    )

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    )

    #expect(candidate == nil)
  }

  @Test("Allows a new edits candidate when the tool use id changes")
  func allowsNewEditsKey() throws {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-2"))
    let openedKey = MonitoringAutoOpenSidePanelKey.edits(
      providerKind: .claude,
      sessionID: "session-1",
      toolUseId: "edit-1"
    )

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    ))

    #expect(candidate.key.value == "edit-2")
  }

  @Test("Suppresses an already-opened plan file path")
  func suppressesSamePlanKeyAfterOpen() {
    let path = "/Users/test/.claude/plans/feature-plan.md"
    let item = Self.item(state: Self.planFileState(filePath: path))
    let openedKey = MonitoringAutoOpenSidePanelKey.plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path
    )

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    )

    #expect(candidate == nil)
  }

  @Test("Allows a new plan candidate when the file path changes")
  func allowsNewPlanKey() throws {
    let oldPath = "/Users/test/.claude/plans/old-plan.md"
    let newPath = "/Users/test/.claude/plans/new-plan.md"
    let item = Self.item(state: Self.planFileState(filePath: newPath))
    let openedKey = MonitoringAutoOpenSidePanelKey.plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: oldPath
    )

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: .single,
      maximizedSessionId: nil,
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    ))

    #expect(candidate.key.value == newPath)
  }

  private static func item(
    state: SessionMonitorState?
  ) -> MonitoringAutoOpenSidePanelItem {
    MonitoringAutoOpenSidePanelItem(
      itemID: "claude-session-1",
      providerKind: .claude,
      session: CLISession(id: "session-1", projectPath: "/tmp/project"),
      state: state
    )
  }

  private static func pendingEditState(toolUseId: String) -> SessionMonitorState {
    SessionMonitorState(
      pendingToolUse: PendingToolUse(
        toolName: "Edit",
        toolUseId: toolUseId,
        timestamp: Date(timeIntervalSince1970: 1)
      )
    )
  }

  private static func planFileState(filePath: String) -> SessionMonitorState {
    SessionMonitorState(recentActivities: planActivities(filePath: filePath))
  }

  private static func planActivities(filePath: String) -> [ActivityEntry] {
    [
      ActivityEntry(
        timestamp: Date(timeIntervalSince1970: 1),
        type: .toolUse(name: "Write"),
        description: "plan.md",
        toolInput: CodeChangeInput(
          toolType: .write,
          filePath: filePath
        )
      )
    ]
  }
}
