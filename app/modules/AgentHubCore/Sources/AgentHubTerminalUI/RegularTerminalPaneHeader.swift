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
  let activity: RegularTerminalPaneActivity?

  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Terminal" : trimmed
  }
}

struct RegularTerminalPaneHeaderState: Equatable {
  let tabs: [RegularTerminalPaneHeaderTabState]
  let canSplit: Bool
  let canClosePane: Bool
  let isActivePane: Bool
  let activity: RegularTerminalPaneActivity?
}

struct RegularTerminalPaneHeader: View {
  let state: RegularTerminalPaneHeaderState
  let onSelectTab: (UUID) -> Void
  let onCloseTab: (UUID) -> Void
  let onNewTab: () -> Void
  let onSplitVertical: () -> Void
  let onSplitHorizontal: () -> Void
  let onClosePane: () -> Void

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
        headerIconButton(
          title: "New Tab",
          systemImage: "plus",
          help: "New terminal tab",
          isDisabled: state.activity != nil,
          action: onNewTab
        )

        headerIconButton(
          title: "Split Right",
          systemImage: "rectangle.split.2x1",
          help: "Split terminal to the right",
          isDisabled: !state.canSplit || state.activity != nil,
          action: onSplitVertical
        )

        headerIconButton(
          title: "Split Below",
          systemImage: "rectangle.split.1x2",
          help: "Split terminal below",
          isDisabled: !state.canSplit || state.activity != nil,
          action: onSplitHorizontal
        )

        if state.activity == .closing {
          ProgressView()
            .controlSize(.small)
            .frame(width: 24, height: 24)
            .help("Closing terminal pane")
        } else if state.canClosePane {
          headerIconButton(
            title: "Close Pane",
            systemImage: "xmark",
            help: "Close terminal pane",
            action: onClosePane
          )
        }
      }
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

  private func tabButton(for tab: RegularTerminalPaneHeaderTabState) -> some View {
    HStack(spacing: 5) {
      if tab.activity != nil {
        ProgressView()
          .controlSize(.small)
          .frame(width: 10, height: 10)
      }

      Button(tab.displayTitle) {
        onSelectTab(tab.id)
      }
      .buttonStyle(.plain)
      .lineLimit(1)
      .disabled(tab.activity == .closing)

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
    .opacity(tab.activity == .closing ? 0.62 : 1)
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
