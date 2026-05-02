import AppKit
import Testing

@testable import AgentHubCore
@testable import AgentHubTerminalUI

@Suite("TerminalSubmitInterception")
struct TerminalSubmitInterceptionTests {

  @Test("System shortcut intercepts plain Return only")
  func systemShortcutMapping() {
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .system,
      isReturn: true,
      flags: []
    ) == .systemSubmit)
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .system,
      isReturn: true,
      flags: .option
    ) == .passthrough)
  }

  @Test("Command-return shortcut keeps custom newline and option submit behavior")
  func commandReturnShortcutMapping() {
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .cmdReturn,
      isReturn: true,
      flags: .command
    ) == .newline)
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .cmdReturn,
      isReturn: true,
      flags: .option
    ) == .submit)
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .cmdReturn,
      isReturn: true,
      flags: []
    ) == .systemSubmit)
  }

  @Test("Shift-return shortcut keeps custom newline and alternate submit behavior")
  func shiftReturnShortcutMapping() {
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .shiftReturn,
      isReturn: true,
      flags: .shift
    ) == .newline)
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .shiftReturn,
      isReturn: true,
      flags: .command
    ) == .submit)
    #expect(TerminalSubmitInterception.keyAction(
      shortcut: .shiftReturn,
      isReturn: true,
      flags: []
    ) == .systemSubmit)
  }

  @Test("Submit dispatch appends queued context when available")
  func dispatchAppendsQueuedContext() {
    #expect(TerminalSubmitInterception.dispatch(
      for: .submit,
      queuedContextPrompt: "Selected web element context:"
    ) == .appendContextAndSubmit("Selected web element context:"))
    #expect(TerminalSubmitInterception.dispatch(
      for: .systemSubmit,
      queuedContextPrompt: "Selected web element context:"
    ) == .appendContextAndSubmit("Selected web element context:"))
  }

  @Test("Submit dispatch preserves default submit behavior without queued context")
  func dispatchPreservesDefaultBehaviorWithoutContext() {
    #expect(TerminalSubmitInterception.dispatch(
      for: .submit,
      queuedContextPrompt: nil
    ) == .submit)
    #expect(TerminalSubmitInterception.dispatch(
      for: .systemSubmit,
      queuedContextPrompt: nil
    ) == .passthrough)
    #expect(TerminalSubmitInterception.dispatch(
      for: .newline,
      queuedContextPrompt: "ignored"
    ) == .newline)
  }
}
