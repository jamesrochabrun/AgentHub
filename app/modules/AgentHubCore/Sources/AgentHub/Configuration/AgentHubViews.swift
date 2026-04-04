//
//  AgentHubViews.swift
//  AgentHub
//
//  Pre-configured view components for AgentHub
//

import SwiftUI

// MARK: - HubToolbarContent

/// Toolbar content with layout mode and terminal buttons
struct HubToolbarContent: View {
  let isPopoverMode: Bool
  let statsButton: AnyView?

  @AppStorage(AgentHubDefaults.hubLayoutMode)
  private var layoutModeRawValue: Int = HubLayoutMode.single.rawValue

  @AppStorage(AgentHubDefaults.hubPreviousLayoutMode)
  private var previousLayoutModeRawValue: Int = -1

  @AppStorage(AgentHubDefaults.auxiliaryShellVisible)
  private var isAuxiliaryShellVisible: Bool = false

  private var layoutMode: HubLayoutMode {
    HubLayoutMode(rawValue: layoutModeRawValue) ?? .single
  }

  var body: some View {
    HStack(spacing: 12) {
      Spacer()

      // Terminal toggle
      HStack(spacing: 6) {
        Button {
          isAuxiliaryShellVisible.toggle()
        } label: {
          Image(systemName: "apple.terminal")
            .font(.caption)
            .foregroundColor(isAuxiliaryShellVisible ? .primary : .secondary)
            .frame(width: 26, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle terminal")
      }
      .padding(4)
      .background(Color.secondary.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      // Layout mode toggle
      HStack(spacing: 6) {
        ForEach(HubLayoutMode.allCases, id: \.self) { mode in
          Button {
            previousLayoutModeRawValue = -1
            layoutModeRawValue = mode.rawValue
          } label: {
            Image(systemName: mode.icon)
              .font(.caption)
              .foregroundColor(layoutMode == mode ? .primary : .secondary)
              .frame(width: 26, height: 20)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(4)
      .background(Color.secondary.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      if let statsButton {
        statsButton
      }
    }
    .padding(.trailing, 8)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - RemoveTitleToolbarModifier

/// A view modifier that removes the toolbar title on macOS 15+
private struct RemoveTitleToolbarModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}

// MARK: - AgentHubSessionsView

/// Pre-configured sessions view that reads from the environment
///
/// This view automatically gets its dependencies from the AgentHub provider
/// in the environment. Make sure to apply `.agentHub()` modifier to a parent view.
///
/// ## Example
/// ```swift
/// WindowGroup {
///   AgentHubSessionsView()
///     .agentHub(provider)
/// }
/// ```
public struct AgentHubSessionsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      sessionsListView(provider: provider)
    } else {
      missingProviderView
    }
  }

  @ViewBuilder
  private func sessionsListView(provider: AgentHubProvider) -> some View {
    MultiProviderSessionsListView(
      claudeViewModel: provider.claudeSessionsViewModel,
      codexViewModel: provider.codexSessionsViewModel,
      columnVisibility: $columnVisibility,
      intelligenceViewModel: provider.intelligenceViewModel,
      worktreeBranchNamingService: provider.worktreeBranchNamingService,
      worktreeSuccessSoundService: provider.worktreeSuccessSoundService
    )
      .frame(minWidth: 1200, minHeight: 750)
      .modifier(RemoveTitleToolbarModifier())
      .toolbar {
        ToolbarItem(placement: .principal) {
          HubToolbarContent(
            isPopoverMode: provider.displaySettings.isPopoverMode,
            statsButton: provider.displaySettings.isPopoverMode
              ? AnyView(GlobalStatsPopoverButton(
                  claudeService: provider.statsService,
                  codexService: provider.codexStatsService
                ))
              : nil
          )
        }
      }
  }

  private var missingProviderView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("AgentHub provider not found")
        .font(.headline)
      Text("Add .agentHub() modifier to a parent view")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - AgentHubMenuBarContent

/// Pre-configured menu bar content for MenuBarExtra
///
/// Use this as the content of a MenuBarExtra to show global stats.
///
/// ## Example
/// ```swift
/// MenuBarExtra("Stats", systemImage: "sparkle") {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// }
/// ```
public struct AgentHubMenuBarContent: View {
  @Environment(\.agentHub) private var agentHub

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      GlobalStatsMenuView(
        claudeService: provider.statsService,
        codexService: provider.codexStatsService,
        sessionsViewModel: provider.sessionsViewModel
      )
    } else {
      Text("AgentHub provider not found")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - AgentHubMenuBarLabel

/// Pre-configured label for MenuBarExtra
///
/// Shows an icon with token count in the menu bar.
///
/// ## Example
/// ```swift
/// @State private var provider = AgentHubProvider()
///
/// MenuBarExtra {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// } label: {
///   AgentHubMenuBarLabel(provider: provider)
/// }
/// ```
public struct AgentHubMenuBarLabel: View {
  let provider: AgentHubProvider

  public init(provider: AgentHubProvider) {
    self.provider = provider
  }

  public var body: some View {
    Image(systemName: "apple.terminal.on.rectangle")
  }
}
