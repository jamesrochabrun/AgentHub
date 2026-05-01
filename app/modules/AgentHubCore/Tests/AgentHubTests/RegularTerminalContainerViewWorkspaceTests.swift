import AppKit
import Testing

@testable import AgentHubCore
@testable import AgentHubTerminalUI

@Suite("Regular terminal workspace")
struct RegularTerminalContainerViewWorkspaceTests {

  @Test("Creating a shell tab adds a tab in the active pane")
  @MainActor
  func creatingShellTabAddsTab() {
    let terminal = makeShellTerminal()

    terminal._testingOpenShellTab()

    #expect(terminal._testingPaneCount == 1)
    #expect(terminal._testingTabCounts == [2])
    #expect(terminal.captureWorkspaceSnapshot()?.panels.first?.tabs.map(\.role) == [.shell, .shell])
  }

  @Test("Vertical and horizontal splits persist layout orientation")
  @MainActor
  func splitButtonsPersistLayoutOrientation() {
    let terminal = makeShellTerminal()

    terminal._testingOpenVerticalSplit()
    terminal._testingOpenHorizontalSplit()

    #expect(terminal._testingPaneCount == 3)
    #expect(terminal.captureWorkspaceSnapshot()?.layout == .split(
      axis: .vertical,
      children: [
        .panel(index: 0),
        .split(axis: .horizontal, children: [.panel(index: 1), .panel(index: 2)])
      ]
    ))
  }

  @Test("Protected agent tab cannot be closed")
  @MainActor
  func protectedAgentTabCannotClose() {
    let terminal = makeAgentTerminal()

    terminal._testingCloseTab(panelIndex: 0, tabIndex: 0)

    #expect(terminal._testingPaneCount == 1)
    #expect(terminal._testingTabCounts == [1])
    #expect(terminal._testingTerminatedTabCount == 0)
    #expect(terminal.captureWorkspaceSnapshot()?.panels.first?.tabs.first?.role == .agent)
  }

  @Test("Closing a shell tab terminates one terminal and leaves the pane alive")
  @MainActor
  func closingShellTabTerminatesOnlyThatTab() {
    let terminal = makeShellTerminal()
    terminal._testingOpenShellTab()

    terminal._testingCloseTab(panelIndex: 0, tabIndex: 1)

    #expect(terminal._testingPaneCount == 1)
    #expect(terminal._testingTabCounts == [1])
    #expect(terminal._testingTerminatedTabCount == 1)
  }

  @Test("Prompt target remains protected agent after selecting shell tab")
  @MainActor
  func promptTargetRemainsProtectedAgentAfterSelectingShell() {
    let terminal = makeAgentTerminal()
    terminal._testingOpenShellTab()

    terminal._testingSelectTab(panelIndex: 0, tabIndex: 1)

    #expect(terminal._testingActiveTabRole == .shell)
    #expect(terminal._testingPromptTargetRole == .agent)
  }

  @Test("Restores version 2 split layout for regular backend")
  @MainActor
  func restoresVersionTwoLayout() {
    let terminal = makeShellTerminal()
    let snapshot = TerminalWorkspaceSnapshot(
      schemaVersion: 2,
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp")]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp")]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp")]
        )
      ],
      activePanelIndex: 2,
      layout: .split(
        axis: .vertical,
        children: [
          .panel(index: 0),
          .split(axis: .horizontal, children: [.panel(index: 1), .panel(index: 2)])
        ]
      )
    )

    terminal.restoreWorkspaceSnapshot(snapshot)

    #expect(terminal._testingPaneCount == 3)
    #expect(terminal.captureWorkspaceSnapshot()?.activePanelIndex == 2)
    #expect(terminal.captureWorkspaceSnapshot()?.layout == snapshot.layout)
  }
}

@MainActor
private func makeShellTerminal() -> TerminalContainerView {
  let terminal = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
  terminal._testingDisableProcessLaunch()
  terminal.configureShell(
    launch: EmbeddedTerminalLaunch.shellLaunch(projectPath: "/tmp"),
    projectPath: "/tmp",
    isDark: true
  )
  return terminal
}

@MainActor
private func makeAgentTerminal() -> TerminalContainerView {
  let terminal = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
  terminal._testingDisableProcessLaunch()
  terminal.configure(
    launch: .success(EmbeddedTerminalLaunch.shellLaunch(projectPath: "/tmp")),
    projectPath: "/tmp",
    initialInputText: nil,
    isDark: true
  )
  return terminal
}
