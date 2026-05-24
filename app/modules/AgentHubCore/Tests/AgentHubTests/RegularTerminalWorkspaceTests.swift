import AppKit
import Testing

@testable import AgentHubCore

@Suite("Regular terminal workspace")
struct RegularTerminalWorkspaceTests {
  @Test("Regular terminal tabs are hidden for launch")
  func regularTerminalTabsAreHiddenForLaunch() {
    #expect(RegularTerminalLaunchFeatures.tabsEnabled == false)
  }

  @Test("Shortcut mapping includes tab and split commands")
  func shortcutMappingIncludesTabAndSplitCommands() {
    #expect(RegularTerminalShortcut.action(
      keyCode: 3,
      charactersIgnoringModifiers: "f",
      modifierFlags: [.command]
    ) == .startSearch)

    #expect(RegularTerminalShortcut.action(
      keyCode: 17,
      charactersIgnoringModifiers: "t",
      modifierFlags: [.command]
    ) == .openTab)

    #expect(RegularTerminalShortcut.action(
      keyCode: 2,
      charactersIgnoringModifiers: "d",
      modifierFlags: [.command]
    ) == .openPane(axis: .horizontal))

    #expect(RegularTerminalShortcut.action(
      keyCode: 2,
      charactersIgnoringModifiers: "D",
      modifierFlags: [.command, .shift]
    ) == .openPane(axis: .vertical))

    #expect(RegularTerminalShortcut.action(
      keyCode: 13,
      charactersIgnoringModifiers: "w",
      modifierFlags: [.command]
    ) == nil)
  }

  @Test("Shortcut mapping includes pane and tab navigation")
  func shortcutMappingIncludesPaneAndTabNavigation() {
    #expect(RegularTerminalShortcut.action(
      keyCode: 123,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .numericPad]
    ) == .focusPanel(.left))

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .shift, .numericPad]
    ) == .selectTab(.next))

    #expect(RegularTerminalShortcut.action(
      keyCode: 13,
      charactersIgnoringModifiers: "w",
      modifierFlags: [.command, .shift]
    ) == .closePanel)
  }

  @Test("Terminal editing shortcuts pass through when terminal input is focused")
  func terminalEditingShortcutsPassThroughWhenTerminalInputIsFocused() {
    #expect(RegularTerminalShortcut.action(
      keyCode: 123,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .numericPad],
      terminalTextInputActive: true
    ) == nil)

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .shift, .numericPad],
      terminalTextInputActive: true
    ) == nil)

    #expect(RegularTerminalShortcut.action(
      keyCode: 51,
      charactersIgnoringModifiers: "\u{7f}",
      modifierFlags: [.command],
      terminalTextInputActive: true
    ) == nil)

    #expect(RegularTerminalShortcut.action(
      keyCode: 3,
      charactersIgnoringModifiers: "f",
      modifierFlags: [.command],
      terminalTextInputActive: true
    ) == .startSearch)

    #expect(RegularTerminalShortcut.action(
      keyCode: 17,
      charactersIgnoringModifiers: "t",
      modifierFlags: [.command],
      terminalTextInputActive: true
    ) == .openTab)
  }

  @Test("Split layout builder adds and removes panels")
  func splitLayoutBuilderAddsAndRemovesPanels() {
    let primary = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let root = RegularTerminalSplitNode.panel(primary)

    let split = RegularTerminalSplitLayoutBuilder.addingPanel(
      shell,
      to: root,
      beside: primary,
      axis: .horizontal
    )

    #expect(split == .split(axis: .horizontal, children: [.panel(primary), .panel(shell)]))
    #expect(RegularTerminalSplitLayoutBuilder.removingPanel(shell, from: split) == .panel(primary))
  }

  @Test("Drag layout proposal switches a flat stack when current orientation is too small")
  func dragLayoutProposalSwitchesFlatStackWhenCurrentOrientationIsTooSmall() {
    let primary = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let root = RegularTerminalSplitNode.split(
      axis: .vertical,
      children: [.panel(primary), .panel(shell1), .panel(shell2)]
    )

    let proposal = TerminalPanelDragLayoutEngine.proposal(
      root: root.terminalPanelLayoutNode,
      dragging: shell2,
      over: shell1,
      placement: .below,
      containerSize: CGSize(width: 900, height: 420),
      minimumPanelSize: CGSize(width: 260, height: 180)
    )

    #expect(proposal?.switchedAxis == true)
    #expect(
      proposal?.root == TerminalPanelLayoutNode.split(
        axis: .horizontal,
        children: [.panel(primary), .panel(shell1), .panel(shell2)]
      )
    )
  }

  @Test("Drag layout proposal rejects drops that cannot fit after reflow")
  func dragLayoutProposalRejectsDropsThatCannotFitAfterReflow() {
    let primary = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let root = RegularTerminalSplitNode.split(
      axis: .vertical,
      children: [.panel(primary), .panel(shell1), .panel(shell2)]
    )

    let proposal = TerminalPanelDragLayoutEngine.proposal(
      root: root.terminalPanelLayoutNode,
      dragging: shell2,
      over: shell1,
      placement: .below,
      containerSize: CGSize(width: 600, height: 420),
      minimumPanelSize: CGSize(width: 260, height: 180)
    )

    #expect(proposal == nil)
  }

  @Test("Drag layout proposal does not reflow nested target stacks")
  func dragLayoutProposalDoesNotReflowNestedTargetStacks() {
    let primary = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let shell3 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    let root = RegularTerminalSplitNode.split(
      axis: .horizontal,
      children: [
        .panel(primary),
        .split(axis: .vertical, children: [.panel(shell1), .panel(shell2)]),
        .panel(shell3)
      ]
    )

    let proposal = TerminalPanelDragLayoutEngine.proposal(
      root: root.terminalPanelLayoutNode,
      dragging: shell3,
      over: shell1,
      placement: .below,
      containerSize: CGSize(width: 1_000, height: 420),
      minimumPanelSize: CGSize(width: 240, height: 180)
    )

    #expect(proposal == nil)
  }

  @MainActor
  @Test("Panel kit commits a validated panel rearrangement")
  func panelKitCommitsValidatedPanelRearrangement() {
    let agent = TerminalPanelKit.Tab(role: .agent, payload: "agent")
    let session = TerminalPanelKit.Session(primaryTab: agent)
    let shell1 = TerminalPanelKit.Tab(role: .shell, payload: "shell1")
    let shell2 = TerminalPanelKit.Tab(role: .shell, payload: "shell2")
    let firstPanel = session.openPanel(with: shell1, beside: session.primaryPanelID, axis: .horizontal)
    let secondPanel = session.openPanel(with: shell2, beside: firstPanel!.id, axis: .horizontal)

    let rearrangedRoot = RegularTerminalSplitNode.split(
      axis: .vertical,
      children: [
        .panel(session.primaryPanelID),
        .panel(secondPanel!.id),
        .panel(firstPanel!.id)
      ]
    )

    #expect(session.rearrangePanels(to: rearrangedRoot))
    #expect(session.splitRoot == rearrangedRoot)
    #expect(session.rearrangePanels(to: .panel(RegularTerminalPanelID())) == false)
  }

  @Test("Removing a nested split panel collapses the empty branch")
  func removingNestedPanelCollapsesSplitBranch() {
    let primary = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = RegularTerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let root = RegularTerminalSplitNode.split(
      axis: .horizontal,
      children: [
        .panel(primary),
        .split(axis: .vertical, children: [.panel(shell1), .panel(shell2)])
      ]
    )

    let result = RegularTerminalSplitLayoutBuilder.removingPanel(shell1, from: root)

    #expect(result == .split(axis: .horizontal, children: [.panel(primary), .panel(shell2)]))
  }

  @MainActor
  @Test("Panel kit opens tabs and panels without replacing existing payloads")
  func panelKitOpensTabsAndPanels() {
    let agent = TerminalPanelKit.Tab(role: .agent, payload: "agent")
    let session = TerminalPanelKit.Session(primaryTab: agent, primaryName: "Claude")

    let shellTab = TerminalPanelKit.Tab(role: .shell, payload: "shell-tab")
    #expect(session.appendTab(shellTab, in: session.primaryPanelID))

    let shellPanelTab = TerminalPanelKit.Tab(role: .shell, payload: "shell-panel")
    let shellPanel = session.openPanel(
      with: shellPanelTab,
      beside: session.primaryPanelID,
      axis: .horizontal
    )

    #expect(session.panels.count == 2)
    #expect(session.primaryPanel?.tabs.map(\.payload) == ["agent", "shell-tab"])
    #expect(shellPanel?.activeTab?.payload == "shell-panel")
    #expect(session.activePanelID == shellPanel?.id)
  }

  @MainActor
  @Test("Panel kit closes tabs and returns payloads for deferred termination")
  func panelKitClosesTabsWithPayloads() {
    let agent = TerminalPanelKit.Tab(role: .agent, payload: "agent")
    let session = TerminalPanelKit.Session(primaryTab: agent)
    let shell = TerminalPanelKit.Tab(role: .shell, payload: "shell")
    #expect(session.appendTab(shell, in: session.primaryPanelID))

    let result = session.closeTab(shell.id, in: session.primaryPanelID)

    #expect(result.payloads == ["shell"])
    #expect(session.primaryPanel?.tabs.map(\.payload) == ["agent"])
    #expect(session.primaryPanel?.activeTab?.payload == "agent")
  }

  @MainActor
  @Test("Panel kit reset keeps primary tab and closes auxiliary payloads")
  func panelKitResetKeepsPrimaryTab() {
    let agent = TerminalPanelKit.Tab(role: .agent, payload: "agent")
    let session = TerminalPanelKit.Session(primaryTab: agent)
    let extraPrimary = TerminalPanelKit.Tab(role: .shell, payload: "primary-shell")
    #expect(session.appendTab(extraPrimary, in: session.primaryPanelID))
    _ = session.openPanel(
      with: TerminalPanelKit.Tab(role: .shell, payload: "panel-shell"),
      beside: session.primaryPanelID,
      axis: .horizontal
    )

    let result = session.resetToPrimary(keeping: agent.id)

    #expect(session.panels.count == 1)
    #expect(session.primaryPanel?.tabs.map(\.payload) == ["agent"])
    #expect(Set(result.payloads) == Set(["primary-shell", "panel-shell"]))
  }
}
