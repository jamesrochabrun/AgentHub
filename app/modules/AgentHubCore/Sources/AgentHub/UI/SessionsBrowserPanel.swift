//
//  SessionsBrowserPanel.swift
//  AgentHub
//
//  Sidebar view showing monitored sessions grouped by module.
//  Used when sidebar mode is "Hub Sessions".
//

import Foundation
import SwiftUI

// MARK: - SessionsBrowserPanel

/// Sidebar panel for browsing monitored sessions grouped by module.
/// This view appears when sidebar mode is set to "Hub Sessions".
public struct SessionsBrowserPanel: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AgentHubDefaults.worktreeDisplayMode)
  private var worktreeDisplayModeRawValue: String = WorktreeDisplayMode.parent.rawValue

  public init(claudeViewModel: CLISessionsViewModel, codexViewModel: CLISessionsViewModel) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Hub Sessions")
          .font(.subheadline.weight(.semibold))
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.bottom, 8)

      // Monitored sessions grouped by module
      if allMonitoredItems.isEmpty {
        emptyState
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
            ForEach(groupedByRepository) { section in
              ForEach(section.groups) { group in
                moduleSectionHeader(name: group.displayName, count: group.items.count)

                ForEach(group.items) { item in
                  sessionRow(for: item)
                }
              }

              if worktreeDisplayMode == .separateModules {
                repositorySectionDivider()
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Sessions in Hub")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Select sessions from \"All Sessions\" to monitor them here.")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Section Header

  private func repositorySectionDivider() -> some View {
    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
      .fill(Color.borderSubtle.opacity(0.9))
      .frame(height: 3)
      .padding(.vertical, 8)
  }

  private func moduleSectionHeader(name: String, count: Int) -> some View {
    HStack {
      Text(name)
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
      Spacer()
      Text("\(count)")
        .font(.caption2)
        .foregroundColor(.secondary.opacity(0.7))
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 4)
    .background(Color.surfaceCanvas.opacity(0.95))
  }

  // MARK: - Session Row

  @ViewBuilder
  private func sessionRow(for item: ProviderMonitoringItem) -> some View {
    switch item {
    case .pending(_, let viewModel, let pending):
      pendingSessionRow(pending: pending, viewModel: viewModel, providerKind: item.providerKind)

    case .monitored(_, let viewModel, let session, let state):
      SessionBrowserRow(
        session: session,
        state: state,
        providerKind: item.providerKind,
        isFocused: isFocused(item),
        isHighlighted: isHighlighted(item),
        customName: viewModel.sessionCustomNames[session.id],
        onSelect: { selectSession(item) }
      )
    }
  }

  private func pendingSessionRow(pending: PendingHubSession, viewModel: CLISessionsViewModel, providerKind: SessionProviderKind) -> some View {
    HStack(spacing: 10) {
      // Provider icon with pulsing animation
      ZStack {
        Circle()
          .fill(Color.brandPrimary(for: providerKind).opacity(0.15))
          .frame(width: 28, height: 28)

        ProgressView()
          .scaleEffect(0.6)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text("Starting session...")
          .font(.system(.subheadline, weight: .medium))
          .foregroundColor(.primary)

        Text(URL(fileURLWithPath: pending.worktree.path).lastPathComponent)
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

      Button(action: { viewModel.cancelPendingSession(pending) }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Data

  private var allMonitoredItems: [ProviderMonitoringItem] {
    let claudePending = claudeViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .claude, viewModel: claudeViewModel, pending: $0)
    }
    let codexPending = codexViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .codex, viewModel: codexViewModel, pending: $0)
    }
    let claudeMonitored = claudeViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .claude, viewModel: claudeViewModel, session: $0.session, state: $0.state)
    }
    let codexMonitored = codexViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .codex, viewModel: codexViewModel, session: $0.session, state: $0.state)
    }
    return claudePending + codexPending + claudeMonitored + codexMonitored
  }

  private var groupedByRepository: [SidebarRepositoryModuleSection<ProviderMonitoringItem>] {
    SidebarSessionOrdering.repositoryModuleSections(
      from: allMonitoredItems,
      repositories: allSelectedRepositories,
      worktreeDisplayMode: worktreeDisplayMode,
      isPinned: { _ in false },
      projectPath: { $0.projectPath },
      timestamp: { $0.timestamp },
      id: { $0.id }
    )
    .compactMap { section in
      let groups = section.groups.filter { !$0.items.isEmpty }
      guard !groups.isEmpty else { return nil }
      return SidebarRepositoryModuleSection(
        id: section.id,
        displayName: section.displayName,
        groups: groups
      )
    }
  }

  private var allSelectedRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    ).sorted { $0.path < $1.path }
  }

  private var worktreeDisplayMode: WorktreeDisplayMode {
    WorktreeDisplayMode(rawValue: worktreeDisplayModeRawValue) ?? .parent
  }

  // MARK: - Focus/Selection Logic

  private func isFocused(_ item: ProviderMonitoringItem) -> Bool {
    false
  }

  private func isHighlighted(_ item: ProviderMonitoringItem) -> Bool {
    false
  }

  private func selectSession(_ item: ProviderMonitoringItem) {
    switch item {
    case .pending:
      break
    case .monitored(_, let viewModel, let session, _):
      if !viewModel.isMonitoring(sessionId: session.id) {
        viewModel.startMonitoring(session: session)
      }
    }
  }
}

// NOTE: Uses ProviderMonitoringItem defined in MultiProviderMonitoringPanelView.swift
