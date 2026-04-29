//
//  TerminalSubmitInterception.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import AppKit

public enum TerminalReturnKeyAction: Equatable {
  case passthrough
  case newline
  case submit
  case systemSubmit
}

public enum TerminalSubmitDispatch: Equatable {
  case passthrough
  case newline
  case submit
  case appendContextAndSubmit(String)
}

public enum TerminalSubmitInterception {
  public static func keyAction(
    shortcut: NewlineShortcut,
    isReturn: Bool,
    flags: NSEvent.ModifierFlags
  ) -> TerminalReturnKeyAction {
    guard isReturn else { return .passthrough }

    switch shortcut {
    case .system:
      return flags.isEmpty ? .systemSubmit : .passthrough
    case .cmdReturn:
      if flags == .command { return .newline }
      if flags == .option { return .submit }
      return flags.isEmpty ? .systemSubmit : .passthrough
    case .shiftReturn:
      if flags == .shift { return .newline }
      if flags == .option || flags == .command { return .submit }
      return flags.isEmpty ? .systemSubmit : .passthrough
    }
  }

  public static func dispatch(
    for action: TerminalReturnKeyAction,
    queuedContextPrompt: String?
  ) -> TerminalSubmitDispatch {
    switch action {
    case .passthrough:
      return .passthrough
    case .newline:
      return .newline
    case .submit:
      if let queuedContextPrompt, !queuedContextPrompt.isEmpty {
        return .appendContextAndSubmit(queuedContextPrompt)
      }
      return .submit
    case .systemSubmit:
      if let queuedContextPrompt, !queuedContextPrompt.isEmpty {
        return .appendContextAndSubmit(queuedContextPrompt)
      }
      return .passthrough
    }
  }
}
