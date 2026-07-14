//
//  WorktreeCleanupSuggestionButton.swift
//  AgentHub
//

import SwiftUI

struct WorktreeCleanupSuggestionButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Cleanup", systemImage: "trash")
        .font(.secondaryCaption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.orange.opacity(0.14), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("This worktree's pull request is merged — delete the worktree")
    .accessibilityLabel("Delete merged worktree")
  }
}
