//
//  WebPreviewPendingEditsBar.swift
//  AgentHub
//
//  Floating pill showing batched design edits waiting to be sent to the
//  session's agent, with an Apply action (⌘↵).
//

import SwiftUI

struct WebPreviewPendingEditsBar: View {
  let count: Int
  let tierLabel: String
  let onApply: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "clock.badge.checkmark")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      Text("\(count) design \(count == 1 ? "change" : "changes") pending · \(tierLabel)")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)

      Button(action: onApply) {
        Text("Apply")
          .font(.system(size: 11, weight: .semibold))
      }
      .controlSize(.small)
      .help("Send these changes to the agent (⌘↵)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    .contentShape(Capsule())
  }
}
