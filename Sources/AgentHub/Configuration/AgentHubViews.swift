//
//  AgentHubViews.swift
//  AgentHub
//
//  Pre-configured view components for AgentHub
//

import SwiftUI

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
  @State private var isShowingIntelligenceOverlay = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      ZStack(alignment: .top) {
        // Main content
        sessionsListView(provider: provider)

        // Intelligence overlay
        if isShowingIntelligenceOverlay {
          IntelligenceOverlayView(
            viewModel: Binding(
              get: { provider.intelligenceViewModel },
              set: { _ in }
            ),
            isPresented: $isShowingIntelligenceOverlay
          )
        }
      }
    } else {
      missingProviderView
    }
  }

  @ViewBuilder
  private func sessionsListView(provider: AgentHubProvider) -> some View {
    CLISessionsListView(viewModel: provider.sessionsViewModel, columnVisibility: $columnVisibility)
      .frame(minWidth: 400, minHeight: 600)
      .modifier(RemoveTitleToolbarModifier())
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack {
            Spacer()
            // Intelligence button
            IntelligencePopoverButton(isShowingOverlay: $isShowingIntelligenceOverlay)
            // Stats button (popover mode only)
            if provider.displaySettings.isPopoverMode {
              GlobalStatsPopoverButton(service: provider.statsService)
            }
          }
          .frame(maxWidth: .infinity)
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
      GlobalStatsMenuView(service: provider.statsService)
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
    HStack(spacing: 4) {
      Image(systemName: "sparkle")
      Text(provider.statsService.formattedTotalTokens)
    }
  }
}
