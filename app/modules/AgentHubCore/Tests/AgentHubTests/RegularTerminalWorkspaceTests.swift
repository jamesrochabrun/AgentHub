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
    ) == nil)

    #expect(RegularTerminalShortcut.action(
      keyCode: 123,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .numericPad]
    ) == .focusPanel(.left))

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .numericPad]
    ) == .focusPanel(.right))

    #expect(RegularTerminalShortcut.action(
      keyCode: 125,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .numericPad]
    ) == .focusPanel(.down))

    #expect(RegularTerminalShortcut.action(
      keyCode: 126,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .numericPad]
    ) == .focusPanel(.up))

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .shift, .numericPad]
    ) == nil)

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .shift, .numericPad]
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
      keyCode: 123,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .numericPad],
      terminalTextInputActive: true
    ) == .focusPanel(.left))

    #expect(RegularTerminalShortcut.action(
      keyCode: 124,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.command, .control, .shift, .numericPad],
      terminalTextInputActive: true
    ) == .selectTab(.next))

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

  @Test("Split layouts convert to persisted panel indexes")
  func splitLayoutsConvertToPersistedPanelIndexes() {
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

    let snapshotNode = RegularTerminalSplitLayoutBuilder.snapshotNode(
      from: root,
      panelIDs: [primary, shell1, shell2]
    )

    #expect(
      snapshotNode == .split(
        axis: .horizontal,
        children: [
          .panel(index: 0),
          .split(axis: .vertical, children: [.panel(index: 1), .panel(index: 2)])
        ]
      )
    )
    #expect(
      RegularTerminalSplitLayoutBuilder.splitNode(
        from: snapshotNode!,
        panelIDs: [primary, shell1, shell2]
      ) == root
    )
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
  @Test("Panel kit restores a persisted split root")
  func panelKitRestoresPersistedSplitRoot() {
    let agent = TerminalPanelKit.Tab(role: .agent, payload: "agent")
    let session = TerminalPanelKit.Session(primaryTab: agent)
    let shell1 = TerminalPanelKit.Tab(role: .shell, payload: "shell-1")
    let panel1 = session.openPanel(with: shell1, beside: session.primaryPanelID, axis: .horizontal)
    let shell2 = TerminalPanelKit.Tab(role: .shell, payload: "shell-2")
    let panel2 = session.openPanel(with: shell2, beside: session.primaryPanelID, axis: .horizontal)

    guard let panel1, let panel2 else {
      Issue.record("Expected panels to open")
      return
    }

    let root = RegularTerminalSplitNode.split(
      axis: .horizontal,
      children: [
        .panel(session.primaryPanelID),
        .split(axis: .vertical, children: [.panel(panel1.id), .panel(panel2.id)])
      ]
    )

    #expect(session.restoreSplitRoot(root))
    #expect(session.currentSplitRoot() == root)
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
