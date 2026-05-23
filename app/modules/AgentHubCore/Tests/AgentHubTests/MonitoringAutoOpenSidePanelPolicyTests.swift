import Foundation
import Testing

@testable import AgentHubCore

@Suite("MonitoringAutoOpenSidePanelPolicy")
struct MonitoringAutoOpenSidePanelPolicyTests {
  @Test("Returns no candidate while module landing is active")
  func returnsNoCandidateWhileModuleLandingIsActive() {
    let item = Self.item(state: Self.pendingEditState(toolUseId: "edit-1"))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
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
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: []
    ))

    #expect(candidate.target == .plan(PlanState(filePath: path)))
    #expect(candidate.key == .plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path,
      detectedAt: Date(timeIntervalSince1970: 1)
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
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    ))

    #expect(candidate.key.value == "edit-2")
  }

  @Test("Suppresses restored edits detected before initial appearance")
  func suppressesRestoredEditsBeforeInitialAppearance() {
    let item = Self.item(state: Self.pendingEditState(
      toolUseId: "edit-1",
      timestamp: Date(timeIntervalSince1970: 10)
    ))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [],
      detectedAfter: Date(timeIntervalSince1970: 20)
    )

    #expect(candidate == nil)
  }

  @Test("Allows edits detected after initial appearance")
  func allowsEditsAfterInitialAppearance() throws {
    let item = Self.item(state: Self.pendingEditState(
      toolUseId: "edit-1",
      timestamp: Date(timeIntervalSince1970: 30)
    ))

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [],
      detectedAfter: Date(timeIntervalSince1970: 20)
    ))

    #expect(candidate.target == .edits)
  }

  @Test("Suppresses an already-opened plan event")
  func suppressesSamePlanEventAfterOpen() {
    let path = "/Users/test/.claude/plans/feature-plan.md"
    let item = Self.item(state: Self.planFileState(filePath: path))
    let openedKey = MonitoringAutoOpenSidePanelKey.plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path,
      detectedAt: Date(timeIntervalSince1970: 1)
    )

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    )

    #expect(candidate == nil)
  }

  @Test("Allows same plan file when the plan event timestamp changes")
  func allowsSamePlanFileWhenPlanEventTimestampChanges() throws {
    let path = "/Users/test/.claude/plans/feature-plan.md"
    let item = Self.item(state: Self.planFileState(
      filePath: path,
      timestamp: Date(timeIntervalSince1970: 2)
    ))
    let openedKey = MonitoringAutoOpenSidePanelKey.plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path,
      detectedAt: Date(timeIntervalSince1970: 1)
    )

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    ))

    #expect(candidate.key == .plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path,
      detectedAt: Date(timeIntervalSince1970: 2)
    ))
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
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [openedKey]
    ))

    #expect(candidate.key == .plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: newPath,
      detectedAt: Date(timeIntervalSince1970: 1)
    ))
  }

  @Test("Suppresses restored plans detected before initial appearance")
  func suppressesRestoredPlansBeforeInitialAppearance() {
    let item = Self.item(state: Self.planFileState(
      filePath: "/Users/test/.claude/plans/feature-plan.md",
      timestamp: Date(timeIntervalSince1970: 10)
    ))

    let candidate = MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [],
      detectedAfter: Date(timeIntervalSince1970: 20)
    )

    #expect(candidate == nil)
  }

  @Test("Allows plans detected after initial appearance")
  func allowsPlansAfterInitialAppearance() throws {
    let item = Self.item(state: Self.planFileState(
      filePath: "/Users/test/.claude/plans/feature-plan.md",
      timestamp: Date(timeIntervalSince1970: 30)
    ))

    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: [],
      detectedAfter: Date(timeIntervalSince1970: 20)
    ))

    #expect(candidate.target == .plan(PlanState(filePath: "/Users/test/.claude/plans/feature-plan.md")))
  }

  @Test("Initial keys suppress already-present edits and plans but allow later edit changes")
  func initialKeysSuppressAlreadyPresentTriggersButAllowLaterChanges() throws {
    let path = "/Users/test/.claude/plans/feature-plan.md"
    let initialItem = Self.item(state: SessionMonitorState(
      pendingToolUse: PendingToolUse(
        toolName: "Edit",
        toolUseId: "edit-1",
        timestamp: Date(timeIntervalSince1970: 1)
      ),
      recentActivities: Self.planActivities(filePath: path)
    ))

    let initialKeys = MonitoringAutoOpenSidePanelPolicy.keys(for: initialItem)

    #expect(initialKeys.contains(.edits(
      providerKind: .claude,
      sessionID: "session-1",
      toolUseId: "edit-1"
    )))
    #expect(initialKeys.contains(.plan(
      providerKind: .claude,
      sessionID: "session-1",
      filePath: path,
      detectedAt: Date(timeIntervalSince1970: 1)
    )))
    #expect(MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: initialItem,
      openedKeys: initialKeys
    ) == nil)

    let changedItem = Self.item(state: SessionMonitorState(
      pendingToolUse: PendingToolUse(
        toolName: "Edit",
        toolUseId: "edit-2",
        timestamp: Date(timeIntervalSince1970: 2)
      ),
      recentActivities: Self.planActivities(filePath: path)
    ))
    let candidate = try #require(MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: changedItem,
      openedKeys: initialKeys
    ))

    #expect(candidate.key == .edits(
      providerKind: .claude,
      sessionID: "session-1",
      toolUseId: "edit-2"
    ))
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

  private static func pendingEditState(
    toolUseId: String,
    timestamp: Date = Date(timeIntervalSince1970: 1)
  ) -> SessionMonitorState {
    SessionMonitorState(
      pendingToolUse: PendingToolUse(
        toolName: "Edit",
        toolUseId: toolUseId,
        timestamp: timestamp
      )
    )
  }

  private static func planFileState(
    filePath: String,
    timestamp: Date = Date(timeIntervalSince1970: 1)
  ) -> SessionMonitorState {
    SessionMonitorState(recentActivities: planActivities(filePath: filePath, timestamp: timestamp))
  }

  private static func planActivities(
    filePath: String,
    timestamp: Date = Date(timeIntervalSince1970: 1)
  ) -> [ActivityEntry] {
    [
      ActivityEntry(
        timestamp: timestamp,
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
