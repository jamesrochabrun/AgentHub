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
  case focusSearch
  case switchToSession(id: String, name: String, provider: SessionProviderKind)
  case selectRepository(path: String, name: String)
  case openSettings
  case toggleSidebar

  public var id: String {
    switch self {
    case .newSession: return "new-session"
    case .focusSearch: return "focus-search"
    case .switchToSession(let id, _, _): return "session-\(id)"
    case .selectRepository(let path, _): return "repo-\(path)"
    case .openSettings: return "settings"
    case .toggleSidebar: return "toggle-sidebar"
    }
  }

  var title: String {
    switch self {
    case .newSession: return "New Session"
    case .focusSearch: return "Focus Search"
    case .switchToSession(_, let name, _): return name
    case .selectRepository(_, let name): return name
    case .openSettings: return "Open Settings"
    case .toggleSidebar: return "Toggle Sidebar"
    }
  }

  var subtitle: String? {
    switch self {
    case .newSession: return "Start a new Claude or Codex session"
    case .focusSearch: return "Search all sessions"
    case .switchToSession(_, _, let provider): return "Switch to \(provider.rawValue) session"
    case .selectRepository(let path, _): return path
    case .openSettings: return "Open application settings"
    case .toggleSidebar: return "Show or hide the sidebar"
    }
  }

  var icon: String {
    switch self {
    case .newSession: return "plus.circle.fill"
    case .focusSearch: return "magnifyingglass"
    case .switchToSession: return "arrow.right.circle"
    case .selectRepository: return "folder"
    case .openSettings: return "gear"
    case .toggleSidebar: return "sidebar.left"
    }
  }

  var shortcut: String? {
    switch self {
    case .newSession: return "⌘N"
    case .focusSearch: return "⌘F"
    case .openSettings: return "⌘,"
    default: return nil
    }
  }
}

// MARK: - CommandPaletteView

public struct CommandPaletteView: View {
  @Binding var isPresented: Bool
  let sessions: [CommandPaletteSession]
  let repositories: [CommandPaletteRepository]
  let onAction: (CommandPaletteAction) -> Void

  @State private var searchQuery = ""
  @State private var selectedIndex = 0
  @FocusState private var isSearchFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  private var filteredActions: [CommandPaletteAction] {
    var actions: [CommandPaletteAction] = []

    // Quick actions
    actions.append(.newSession)
    actions.append(.focusSearch)
    actions.append(.openSettings)
    actions.append(.toggleSidebar)

    // Filter sessions
    let filteredSessions = sessions.filter { session in
      searchQuery.isEmpty || session.name.localizedCaseInsensitiveContains(searchQuery)
    }
    actions.append(contentsOf: filteredSessions.map { session in
      .switchToSession(id: session.id, name: session.name, provider: session.provider)
    })

    // Filter repositories
    let filteredRepos = repositories.filter { repo in
      searchQuery.isEmpty || repo.name.localizedCaseInsensitiveContains(searchQuery)
    }
    actions.append(contentsOf: filteredRepos.map { repo in
      .selectRepository(path: repo.path, name: repo.name)
    })

    return actions
  }

  public var body: some View {
    ZStack {
      // Overlay background
      Color.black.opacity(0.4)
        .ignoresSafeArea()
        .onTapGesture {
          isPresented = false
        }

      // Command palette
      VStack(spacing: 0) {
        // Search field
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 16))
            .foregroundColor(.secondary)

          TextField("Search sessions, repositories, or actions...", text: $searchQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isSearchFocused)

          if !searchQuery.isEmpty {
            Button(action: { searchQuery = "" }) {
              Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
          }

          // Esc hint
          Text("esc")
            .font(.system(size: 11, design: .monospaced))
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

        // Results list
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              if filteredActions.isEmpty {
                emptyState
              } else {
                ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                  CommandPaletteRow(
                    action: action,
                    isSelected: index == selectedIndex
                  )
                  .id(index)
                  .onTapGesture {
                    executeAction(action)
                  }
                }
              }
            }
            .padding(.vertical, 8)
          }
          .frame(maxHeight: 400)
          .onChange(of: selectedIndex) { _, newIndex in
            withAnimation(.easeInOut(duration: 0.15)) {
              proxy.scrollTo(newIndex, anchor: .center)
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
      isSearchFocused = true
    }
    .onKeyPress(.upArrow) {
      if selectedIndex > 0 {
        selectedIndex -= 1
      }
      return .handled
    }
    .onKeyPress(.downArrow) {
      if selectedIndex < filteredActions.count - 1 {
        selectedIndex += 1
      }
      return .handled
    }
    .onKeyPress(.return) {
      if !filteredActions.isEmpty {
        executeAction(filteredActions[selectedIndex])
      }
      return .handled
    }
    .onKeyPress(.escape) {
      isPresented = false
      return .handled
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 32))
        .foregroundColor(.secondary.opacity(0.5))

      Text("No results found")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Try a different search term")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.8))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  private func executeAction(_ action: CommandPaletteAction) {
    isPresented = false

    // Small delay to let the palette dismiss smoothly
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      onAction(action)
    }
  }
}

// MARK: - CommandPaletteRow

private struct CommandPaletteRow: View {
  let action: CommandPaletteAction
  let isSelected: Bool
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 12) {
      // Icon
      Image(systemName: action.icon)
        .font(.system(size: 16))
        .foregroundColor(isSelected ? Color.brandPrimary(from: runtimeTheme) : .secondary)
        .frame(width: 20)

      // Title and subtitle
      VStack(alignment: .leading, spacing: 2) {
        Text(action.title)
          .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundColor(.primary)

        if let subtitle = action.subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      // Keyboard shortcut hint
      if let shortcut = action.shortcut {
        Text(shortcut)
          .font(.system(size: 11, design: .monospaced))
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
        .fill(isSelected ? Color.brandPrimary(from: runtimeTheme).opacity(0.12) : Color.clear)
    )
    .contentShape(Rectangle())
  }
}

// MARK: - Supporting Types

public struct CommandPaletteSession {
  public let id: String
  public let name: String
  public let provider: SessionProviderKind

  public init(id: String, name: String, provider: SessionProviderKind) {
    self.id = id
    self.name = name
    self.provider = provider
  }
}

public struct CommandPaletteRepository {
  public let path: String
  public let name: String

  public init(path: String, name: String) {
    self.path = path
    self.name = name
  }
}

// MARK: - Preview

#Preview {
  CommandPaletteView(
    isPresented: .constant(true),
    sessions: [
      CommandPaletteSession(id: "1", name: "Refactor Auth Module", provider: .claude),
      CommandPaletteSession(id: "2", name: "Write Unit Tests", provider: .codex),
      CommandPaletteSession(id: "3", name: "Update Documentation", provider: .claude)
    ],
    repositories: [
      CommandPaletteRepository(path: "/Users/dev/AgentHub", name: "AgentHub"),
      CommandPaletteRepository(path: "/Users/dev/MyProject", name: "MyProject")
    ],
    onAction: { _ in }
  )
}
