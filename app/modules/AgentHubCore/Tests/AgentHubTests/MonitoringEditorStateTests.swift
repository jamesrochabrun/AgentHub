import Foundation
import Testing

@testable import AgentHubCore

@Suite("MonitoringEditorState")
struct MonitoringEditorStateTests {
  @Test("Missing editor state defaults to terminal mode and the item project path")
  func defaultStateUsesItemProjectPath() {
    let state = MonitoringEditorStateStore.state(
      for: "claude-session-1",
      defaultProjectPath: "/tmp/repo",
      in: [:]
    )

    #expect(state.contentMode == .terminal)
    #expect(state.projectPath == "/tmp/repo")
    #expect(state.selectedFilePath == nil)
    #expect(state.navigationRequest == nil)
  }

  @Test("Opening a file switches the session into editor mode")
  func openFileSetsEditorState() throws {
    let states = MonitoringEditorStateStore.openFile(
      "/tmp/repo/Sources/App.swift",
      lineNumber: 42,
      projectPath: "/tmp/repo",
      for: "claude-session-1",
      in: [:]
    )

    let state = try #require(states["claude-session-1"])
    #expect(state.contentMode == .editor)
    #expect(state.projectPath == "/tmp/repo")
    #expect(state.selectedFilePath == "/tmp/repo/Sources/App.swift")
    #expect(state.navigationRequest?.filePath == "/tmp/repo/Sources/App.swift")
    #expect(state.navigationRequest?.lineNumber == 42)
  }

  @Test("Routing a terminal file open can promote the emitting session to primary")
  func routeOpenFileCanMakeSessionPrimary() {
    let result = MonitoringEditorStateStore.routeOpenFile(
      "/tmp/repo/Sources/App.swift",
      projectPath: "/tmp/repo",
      for: "codex-session-2",
      in: [:],
      currentPrimaryItemID: "claude-session-1",
      makePrimary: true
    )

    #expect(result.primaryItemID == "codex-session-2")
    #expect(result.states["codex-session-2"]?.contentMode == .editor)
  }

  @Test("Selecting a file in the editor clears the one-shot navigation request")
  func selectingFileClearsNavigationRequest() throws {
    let openedStates = MonitoringEditorStateStore.openFile(
      "/tmp/repo/Sources/App.swift",
      projectPath: "/tmp/repo",
      for: "claude-session-1",
      in: [:]
    )

    let updatedStates = MonitoringEditorStateStore.setSelectedFilePath(
      "/tmp/repo/Sources/Feature.swift",
      for: "claude-session-1",
      defaultProjectPath: "/tmp/repo",
      in: openedStates
    )

    let state = try #require(updatedStates["claude-session-1"])
    #expect(state.selectedFilePath == "/tmp/repo/Sources/Feature.swift")
    #expect(state.navigationRequest == nil)
    #expect(state.contentMode == .editor)
  }

  @Test("Pruning removes editor state for sessions that no longer exist")
  func pruneRemovesStaleSessionState() {
    let states: [String: MonitoringEditorState] = [
      "claude-session-1": MonitoringEditorState(
        contentMode: .editor,
        projectPath: "/tmp/repo-a",
        selectedFilePath: "/tmp/repo-a/App.swift",
        navigationRequest: nil
      ),
      "codex-session-2": MonitoringEditorState(
        contentMode: .terminal,
        projectPath: "/tmp/repo-b",
        selectedFilePath: nil,
        navigationRequest: nil
      ),
    ]

    let prunedStates = MonitoringEditorStateStore.prune(
      states,
      validItemIDs: Set(["codex-session-2"])
    )

    #expect(prunedStates.count == 1)
    #expect(prunedStates["claude-session-1"] == nil)
    #expect(prunedStates["codex-session-2"]?.projectPath == "/tmp/repo-b")
  }
}
