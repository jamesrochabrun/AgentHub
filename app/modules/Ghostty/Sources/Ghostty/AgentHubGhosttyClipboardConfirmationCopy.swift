//
//  AgentHubGhosttyClipboardConfirmationCopy.swift
//  AgentHub
//

import GhosttySwift

struct AgentHubGhosttyClipboardConfirmationCopy: Equatable {
  let title: String
  let message: String
  let allowButtonTitle: String

  static func copy(for request: GhosttyClipboardRequest) -> AgentHubGhosttyClipboardConfirmationCopy {
    switch request {
    case .paste:
      AgentHubGhosttyClipboardConfirmationCopy(
        title: "Paste potentially unsafe text?",
        message: "The pasted text may contain commands or terminal control sequences. Review it before allowing the paste.",
        allowButtonTitle: "Paste"
      )
    case .osc52Read:
      AgentHubGhosttyClipboardConfirmationCopy(
        title: "Allow terminal to read the clipboard?",
        message: "A program running in this terminal wants to read your clipboard contents.",
        allowButtonTitle: "Allow Read"
      )
    case .osc52Write:
      AgentHubGhosttyClipboardConfirmationCopy(
        title: "Allow terminal to write the clipboard?",
        message: "A program running in this terminal wants to replace your clipboard contents.",
        allowButtonTitle: "Allow Write"
      )
    }
  }
}
