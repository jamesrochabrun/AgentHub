//
//  TranscriptView.swift
//  AgentHub
//

import SwiftUI

struct TranscriptView: View {
  let entries: [TranscriptEntry]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        ForEach(entries) { entry in
          TranscriptEntryView(entry: entry)
        }
      }
      .padding(DesignTokens.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color.surfaceCanvas)
  }
}

private struct TranscriptEntryView: View {
  let entry: TranscriptEntry

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(entry.role == .user ? "You" : entry.provider.rawValue)
        .font(.primaryCaption)
        .foregroundStyle(.secondary)

      switch entry.role {
      case .user:
        Text(entry.content)
          .font(.primaryBody)
          .textSelection(.enabled)
          .padding(DesignTokens.Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.surfaceCard)
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
      case .assistant:
        MarkdownView(content: entry.content, includeScrollView: false)
          .background(Color.clear)
      }
    }
  }
}
