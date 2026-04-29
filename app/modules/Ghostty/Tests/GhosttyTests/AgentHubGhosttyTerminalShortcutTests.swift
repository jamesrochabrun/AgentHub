import AppKit
import GhosttySwift
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty terminal shortcuts")
struct AgentHubGhosttyTerminalShortcutTests {

  @Test("Command shortcuts match Ghostty terminal actions")
  func commandShortcuts() {
    expectAction(.openTab, key: "t", flags: .command)
    expectAction(.openPane, key: "d", flags: .command)
    expectAction(.startSearch, key: "f", flags: .command)
    expectAction(.searchNext, key: "g", flags: .command)
    expectNoAction(key: "w", flags: .command)
  }

  @Test("Shift-command shortcuts match Ghostty terminal actions")
  func shiftedCommandShortcuts() {
    expectAction(.searchPrevious, key: "g", flags: [.command, .shift])
    expectAction(.closePanel, key: "w", flags: [.command, .shift])
  }

  @Test("Command arrow shortcuts focus panes")
  func paneFocusShortcuts() {
    expectFocusPanel(.left, keyCode: 123, flags: [.command, .numericPad])
    expectFocusPanel(.right, keyCode: 124, flags: [.command, .numericPad])
    expectFocusPanel(.down, keyCode: 125, flags: [.command, .numericPad])
    expectFocusPanel(.up, keyCode: 126, flags: [.command, .numericPad])
  }

  @Test("Shift-command arrow shortcuts select tabs")
  func tabSelectionShortcuts() {
    expectSelectTab(.previous, keyCode: 123, flags: [.command, .shift, .numericPad])
    expectSelectTab(.next, keyCode: 124, flags: [.command, .shift, .numericPad])
  }
}

private func expectAction(
  _ expected: AgentHubGhosttyTerminalShortcut,
  key: String,
  flags: NSEvent.ModifierFlags,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let action = AgentHubGhosttyTerminalShortcut.action(
    keyCode: 0,
    charactersIgnoringModifiers: key,
    modifierFlags: flags
  )
  #expect(action == expected, sourceLocation: sourceLocation)
}

private func expectNoAction(
  key: String,
  flags: NSEvent.ModifierFlags,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let action = AgentHubGhosttyTerminalShortcut.action(
    keyCode: 0,
    charactersIgnoringModifiers: key,
    modifierFlags: flags
  )
  #expect(action == nil, sourceLocation: sourceLocation)
}

private func expectFocusPanel(
  _ expected: TerminalPanelNavigationDirection,
  keyCode: UInt16,
  flags: NSEvent.ModifierFlags,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let action = AgentHubGhosttyTerminalShortcut.action(
    keyCode: keyCode,
    charactersIgnoringModifiers: nil,
    modifierFlags: flags
  )

  switch action {
  case .focusPanel(let actual):
    #expect(actual == expected, sourceLocation: sourceLocation)
  default:
    Issue.record("Expected focus panel \(expected), got \(String(describing: action))", sourceLocation: sourceLocation)
  }
}

private func expectSelectTab(
  _ expected: TerminalTabNavigationDirection,
  keyCode: UInt16,
  flags: NSEvent.ModifierFlags,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let action = AgentHubGhosttyTerminalShortcut.action(
    keyCode: keyCode,
    charactersIgnoringModifiers: nil,
    modifierFlags: flags
  )

  switch action {
  case .selectTab(let actual):
    #expect(actual == expected, sourceLocation: sourceLocation)
  default:
    Issue.record("Expected select tab \(expected), got \(String(describing: action))", sourceLocation: sourceLocation)
  }
}
