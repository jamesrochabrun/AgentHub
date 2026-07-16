//
//  CommandPaletteView.swift
//  AgentHub
//
//  Command palette for quick navigation and actions (Cmd+K)
//

import SwiftUI

// MARK: - CommandPaletteAction

public enum CommandPaletteAction: Identifiable {
  case newSession
  case newWorkspace
  case switchToSession(id: String, name: String, provider: SessionProviderKind, firstMessage: String?)
  case selectRepository(path: String, name: String)
  case openSettings
  case toggleSidebar
  case toggleTerminalEditor

  public var id: String {
    switch self {
    case .newSession: return "new-session"
    case .newWorkspace: return "new-workspace"
    case .switchToSession(let id, _, _, _): return "session-\(id)"
    case .selectRepository(let path, _): return "repo-\(path)"
    case .openSettings: return "settings"
    case .toggleSidebar: return "toggle-sidebar"
    case .toggleTerminalEditor: return "toggle-terminal-editor"
    }
  }

  var title: String {
    switch self {
    case .newSession: return "New Session"
    case .newWorkspace: return "New Workspace"
    case .switchToSession(_, let name, _, _): return name
    case .selectRepository(_, let name): return name
    case .openSettings: return "Open Settings"
    case .toggleSidebar: return "Toggle Sidebar"
    case .toggleTerminalEditor: return "Next Session Tab"
    }
  }

  var subtitle: String? {
    switch self {
    case .newSession: return "Start from the focused session's worktree"
    case .newWorkspace: return "Open a multi-panel terminal in the focused project"
    case .switchToSession(_, _, let provider, let firstMessage):
      if let firstMessage {
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
      return "Switch to \(provider.rawValue) session"
    case .selectRepository(let path, _): return path
    case .openSettings: return "Open application settings"
    case .toggleSidebar: return "Show or hide the sidebar"
    case .toggleTerminalEditor: return "Cycle the focused session through visible tabs"
    }
  }

  var icon: String {
    switch self {
    case .newSession: return "plus.circle.fill"
    case .newWorkspace: return "rectangle.3.group"
    case .switchToSession: return "arrow.right.circle"
    case .selectRepository: return "folder"
    case .openSettings: return "gear"
    case .toggleSidebar: return "sidebar.left"
    case .toggleTerminalEditor: return "arrow.triangle.2.circlepath"
    }
  }

  var shortcut: String? {
    switch self {
    case .newSession: return "⌘N"
    case .newWorkspace: return "⌘⇧N"
    case .toggleSidebar: return "⌘B"
    case .openSettings: return "⌘,"
    case .toggleTerminalEditor: return "⌥`"
    default: return nil
    }
  }
}

private struct CommandPaletteItem: Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let icon: String
  let shortcut: String?
  let action: CommandPaletteAction?

  static func action(_ action: CommandPaletteAction) -> CommandPaletteItem {
    CommandPaletteItem(
      id: action.id,
      title: action.title,
      subtitle: action.subtitle,
      icon: action.icon,
      shortcut: action.shortcut,
      action: action
    )
  }

  static func shortcut(
    id: String,
    title: String,
    subtitle: String,
    icon: String,
    shortcut: String
  ) -> CommandPaletteItem {
    CommandPaletteItem(
      id: id,
      title: title,
      subtitle: subtitle,
      icon: icon,
      shortcut: shortcut,
      action: nil
    )
  }
}

// MARK: - CommandPaletteView

public struct CommandPaletteView: View {
  @Binding var isPresented: Bool
  let sessions: [CommandPaletteSession]
  let onAction: (CommandPaletteAction) -> Void

  @State private var searchQuery = ""
  @State private var selectedIndex = 0
  @State private var filteredSessionActions: [CommandPaletteAction] = []
  @State private var searchTask: Task<Void, Never>?
  @FocusState private var isSearchFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  private var normalizedQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var quickActions: [CommandPaletteAction] {
    [
      .newSession,
      .newWorkspace,
      .toggleTerminalEditor,
      .openSettings,
      .toggleSidebar,
    ]
  }

  private var shortcutInfoItems: [CommandPaletteItem] {
    [
      .shortcut(
        id: "shortcut-terminal-pane-maximize",
        title: "Terminal Pane: Maximize or Restore",
        subtitle: "Show the active pane by itself, then restore the split layout",
        icon: "arrow.up.left.and.arrow.down.right",
        shortcut: "⌘⇧M"
      ),
      .shortcut(
        id: "shortcut-terminal-pane-focus",
        title: "Terminal Pane: Focus Adjacent Pane",
        subtitle: "Move focus left, right, up, or down between terminal panes",
        icon: "keyboard",
        shortcut: "⌘⌃←/→/↑/↓"
      ),
      .shortcut(
        id: "shortcut-web-preview-width",
        title: "Web Preview: Toggle Width",
        subtitle: "Expand or collapse the embedded preview",
        icon: "arrow.up.left.and.arrow.down.right",
        shortcut: "⌘⇧O"
      ),
      .shortcut(
        id: "shortcut-web-preview-inspect",
        title: "Web Preview: Cycle Inspect Modes",
        subtitle: "Inspect, crop, edit, then off",
        icon: "cursorarrow.rays",
        shortcut: "⌘⇧I"
      ),
      .shortcut(
        id: "shortcut-web-preview-reload",
        title: "Web Preview: Reload",
        subtitle: "Reload the current preview",
        icon: "arrow.clockwise",
        shortcut: "⌘R"
      ),
      .shortcut(
        id: "shortcut-web-preview-submit",
        title: "Web Preview: Send or Update",
        subtitle: "Send queued canvas feedback or update preview",
        icon: "paperplane",
        shortcut: "⌘↩"
      ),
      .shortcut(
        id: "shortcut-web-preview-close",
        title: "Web Preview: Close",
        subtitle: "Close the preview",
        icon: "xmark",
        shortcut: "Esc"
      ),
    ]
  }

  private var nonSessionItemCount: Int {
    quickActions.count + shortcutInfoItems.count
  }

  private var displayedItems: [CommandPaletteItem] {
    quickActions.map(CommandPaletteItem.action)
      + shortcutInfoItems
      + filteredSessionActions.map(CommandPaletteItem.action)
  }

  private func performSearch() {
    searchTask?.cancel()

    let query = normalizedQuery
    let currentSessions = sessions

    // Empty query — show all sessions immediately (no scoring needed)
    guard !query.isEmpty else {
      filteredSessionActions = currentSessions.map { session in
        .switchToSession(
          id: session.id,
          name: session.name,
          provider: session.provider,
          firstMessage: session.firstMessage
        )
      }
      return
    }

    // Non-empty query — debounce and score off main thread
    searchTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }

      let results = await Task.detached(priority: .userInitiated) {
        let indexedSessions = Array(currentSessions.enumerated())

        let rankedMatches = indexedSessions.compactMap { index, session -> SessionMatch? in
          var bestScore = 0

          if let firstMessage = session.firstMessage, !firstMessage.isEmpty {
            if let match = SearchScoring.score(query: query, against: firstMessage) {
              bestScore = match.score + 5
            }
          } else {
            if let match = SearchScoring.score(query: query, against: session.name) {
              bestScore = match.score + 3
            }
          }

          guard bestScore > 0 else { return nil }

          return SessionMatch(
            index: index,
            relevanceScore: bestScore,
            session: session
          )
        }
        .sorted { lhs, rhs in
          if lhs.relevanceScore != rhs.relevanceScore {
            return lhs.relevanceScore > rhs.relevanceScore
          }
          return lhs.index < rhs.index
        }

        return rankedMatches.map { match in
          CommandPaletteAction.switchToSession(
            id: match.session.id,
            name: match.session.name,
            provider: match.session.provider,
            firstMessage: match.session.firstMessage
          )
        }
      }.value

      guard !Task.isCancelled else { return }
      filteredSessionActions = results
    }
  }

  private var displayedItemIDs: [String] {
    displayedItems.map(\.id)
  }

  public var body: some View {
    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()
        .onTapGesture { isPresented = false }

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 16))
            .foregroundColor(.secondary)

          TextField("Find focused sessions...", text: $searchQuery)
            .textFieldStyle(.plain)
            .font(.secondaryLarge)
            .focused($isSearchFocused)

          if !searchQuery.isEmpty {
            Button(action: { searchQuery = "" }) {
              Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
          }

          Spacer()

          Text("esc")
            .font(.primarySmall)
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
          UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 12
          )
          .fill(Color.surfaceElevated)
        )

        Divider()

        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              if displayedItems.isEmpty {
                emptyState
              } else {
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                  CommandPaletteRow(
                    item: item,
                    isSelected: index == selectedIndex
                  )
                  .id(item.id)
                  .onTapGesture { executeItem(item) }
                }
              }
            }
            .padding(.vertical, 8)
          }
          .frame(maxHeight: 400)
          .onChange(of: selectedIndex) { _, newIndex in
            let items = displayedItems
            guard newIndex >= 0, newIndex < items.count else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
              proxy.scrollTo(items[newIndex].id, anchor: .center)
            }
          }
        }
      }
      .frame(width: 600)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(colorScheme == .dark ? Color(white: 0.15) : Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
    }
    .onAppear {
      searchQuery = ""
      selectedIndex = 0
      performSearch()
      DispatchQueue.main.async {
        isSearchFocused = true
      }
    }
    .onDisappear {
      searchTask?.cancel()
    }
    .onChange(of: displayedItemIDs) { _, _ in
      if !normalizedQuery.isEmpty && !filteredSessionActions.isEmpty {
        selectedIndex = nonSessionItemCount
      } else {
        clampSelectedIndex()
      }
    }
    .onChange(of: searchQuery) { _, _ in
      performSearch()

      guard !normalizedQuery.isEmpty else {
        selectedIndex = 0
        return
      }

      if !filteredSessionActions.isEmpty {
        selectedIndex = nonSessionItemCount
      } else {
        selectedIndex = 0
      }
    }
    .onKeyPress(.upArrow) {
      guard !displayedItems.isEmpty else { return .handled }
      if selectedIndex > 0 {
        selectedIndex -= 1
      }
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !displayedItems.isEmpty else { return .handled }
      if selectedIndex < displayedItems.count - 1 {
        selectedIndex += 1
      }
      return .handled
    }
    .onKeyPress(.return) {
      let items = displayedItems
      guard !items.isEmpty else { return .handled }
      let safeIndex = max(0, min(selectedIndex, items.count - 1))
      selectedIndex = safeIndex
      executeItem(items[safeIndex])
      return .handled
    }
    .onKeyPress(.escape) {
      isPresented = false
      return .handled
    }
    .onExitCommand {
      isPresented = false
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 32))
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Focused Sessions")
        .font(.heading)
        .foregroundColor(.secondary)

      Text("Start or focus a session to show it here")
        .font(.secondaryCaption)
        .foregroundColor(.secondary.opacity(0.8))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  private func clampSelectedIndex() {
    let count = displayedItems.count
    if count == 0 {
      selectedIndex = 0
      return
    }
    selectedIndex = max(0, min(selectedIndex, count - 1))
  }

  private func executeItem(_ item: CommandPaletteItem) {
    guard let action = item.action else { return }

    isPresented = false

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      onAction(action)
    }
  }

}

private struct SessionMatch {
  let index: Int
  let relevanceScore: Int
  let session: CommandPaletteSession
}

// MARK: - CommandPaletteRow

private struct CommandPaletteRow: View {
  let item: CommandPaletteItem
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: item.icon)
        .font(.system(size: 16))
        .foregroundColor(isSelected ? .brandPrimary : .secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.geist(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundColor(.primary)

        if let subtitle = item.subtitle {
          Text(subtitle)
            .font(.secondarySmall)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if let shortcut = item.shortcut {
        Text(shortcut)
          .font(.primarySmall)
          .foregroundColor(.secondary.opacity(0.7))
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(Color.secondary.opacity(0.12))
          )
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.brandPrimary.opacity(0.12) : Color.clear)
    )
    .contentShape(Rectangle())
  }
}

// MARK: - Supporting Types

public struct CommandPaletteSession {
  public let id: String
  public let name: String
  public let provider: SessionProviderKind
  public let firstMessage: String?

  public init(id: String, name: String, provider: SessionProviderKind, firstMessage: String? = nil) {
    self.id = id
    self.name = name
    self.provider = provider
    self.firstMessage = firstMessage
  }
}
