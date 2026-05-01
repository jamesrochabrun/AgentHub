//
//  RegularTerminalPaneHeader.swift
//  AgentHub
//

import Foundation
import SwiftUI

struct RegularTerminalPaneHeaderTabState: Identifiable, Equatable {
  let id: UUID
  let title: String
  let isActive: Bool
  let isCloseable: Bool

  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Terminal" : trimmed
  }
}

struct RegularTerminalPaneHeaderState: Equatable {
  let tabs: [RegularTerminalPaneHeaderTabState]
  let canSplit: Bool
  let isActivePane: Bool
}

struct RegularTerminalPaneHeader: View {
  let state: RegularTerminalPaneHeaderState
  let onSelectTab: (UUID) -> Void
  let onCloseTab: (UUID) -> Void
  let onNewTab: () -> Void
  let onSplitVertical: () -> Void
  let onSplitHorizontal: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(state.tabs) { tab in
            tabButton(for: tab)
          }
        }
        .padding(.leading, 6)
      }

      Spacer(minLength: 4)

      HStack(spacing: 4) {
        Button("New Tab", systemImage: "plus", action: onNewTab)
          .labelStyle(.iconOnly)
          .help("New terminal tab")

        Button("Split Right", systemImage: "rectangle.split.2x1", action: onSplitVertical)
          .labelStyle(.iconOnly)
          .disabled(!state.canSplit)
          .help("Split terminal to the right")

        Button("Split Below", systemImage: "rectangle.split.1x2", action: onSplitHorizontal)
          .labelStyle(.iconOnly)
          .disabled(!state.canSplit)
          .help("Split terminal below")
      }
      .buttonStyle(.plain)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.trailing, 6)
    }
    .frame(height: 28)
    .background(headerBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.secondary.opacity(state.isActivePane ? 0.28 : 0.18))
        .frame(height: 1)
    }
  }

  private func tabButton(for tab: RegularTerminalPaneHeaderTabState) -> some View {
    HStack(spacing: 5) {
      Button(tab.displayTitle) {
        onSelectTab(tab.id)
      }
      .buttonStyle(.plain)
      .lineLimit(1)

      if tab.isCloseable {
        Button("Close \(tab.displayTitle)", systemImage: "xmark") {
          onCloseTab(tab.id)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .font(.system(size: 10, weight: .semibold))
        .help("Close terminal tab")
      }
    }
    .font(.system(size: 12, weight: tab.isActive ? .semibold : .medium))
    .foregroundStyle(tab.isActive ? Color.primary : Color.secondary)
    .padding(.horizontal, 8)
    .frame(height: 23)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(tab.isActive ? Color.secondary.opacity(0.16) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(tab.isActive ? Color.secondary.opacity(0.18) : Color.clear, lineWidth: 1)
    )
  }

  private var headerBackground: Color {
    Color(nsColor: .windowBackgroundColor).opacity(0.72)
  }
}
