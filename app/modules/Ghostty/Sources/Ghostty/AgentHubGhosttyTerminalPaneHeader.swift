//
//  AgentHubGhosttyTerminalPaneHeader.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalPaneHeader: View {
  let panel: TerminalPanel
  let canSplit: Bool
  let canClosePanel: Bool
  let canCloseTab: (TerminalTab) -> Bool
  let onSelectTab: (TerminalTab) -> Void
  let onCloseTab: (TerminalTab) -> Void
  let onOpenTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitBelow: () -> Void
  let onClosePanel: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
            tabButton(tab: tab, index: index)
          }
        }
      }

      Spacer(minLength: 4)

      HStack(spacing: 4) {
        headerIconButton(
          title: "New Tab",
          systemImage: "plus",
          help: "New terminal tab",
          action: onOpenTab
        )

        headerIconButton(
          title: "Split Right",
          systemImage: "rectangle.split.2x1",
          help: "Split terminal to the right",
          isDisabled: !canSplit,
          action: onSplitRight
        )

        headerIconButton(
          title: "Split Below",
          systemImage: "rectangle.split.1x2",
          help: "Split terminal below",
          isDisabled: !canSplit,
          action: onSplitBelow
        )

        if canClosePanel {
          headerIconButton(
            title: "Close Pane",
            systemImage: "xmark",
            help: "Close terminal pane",
            action: onClosePanel
          )
        }
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.trailing, 6)
    }
    .frame(height: 28)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.secondary.opacity(0.18))
        .frame(height: 1)
    }
  }

  private func headerIconButton(
    title: String,
    systemImage: String,
    help: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
      .disabled(isDisabled)
      .help(help)
  }

  private func tabButton(tab: TerminalTab, index: Int) -> some View {
    let isActive = tab.id == panel.activeTabID
    let title = tab.displayName(index: index)

    return HStack(spacing: 5) {
      Button(action: { onSelectTab(tab) }) {
        Text(title)
          .font(.caption2.weight(isActive ? .medium : .regular))
          .lineLimit(1)
          .frame(minWidth: 76, maxWidth: 150, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if canCloseTab(tab) {
        Button(action: { onCloseTab(tab) }) {
          Label("Close Tab", systemImage: "xmark")
            .labelStyle(.iconOnly)
            .font(.system(size: 9, weight: .medium))
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Tab")
      }
    }
    .frame(height: 28)
    .padding(.leading, 10)
    .padding(.trailing, canCloseTab(tab) ? 7 : 10)
    .foregroundStyle(isActive ? Color.primary : Color.secondary)
    .background {
      Rectangle()
        .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color.primary.opacity(0.14))
        .frame(width: 1)
    }
    .overlay(alignment: .bottom) {
      if isActive {
        Rectangle()
          .fill(Color.accentColor.opacity(0.75))
          .frame(height: 2)
      }
    }
    .contentShape(Rectangle())
    .help(title)
    .zIndex(isActive ? 1 : 0)
  }
}
