//
//  SelectedSessionsPanelView.swift
//  AgentHub
//
//  Created by Assistant on 2/4/26.
//

import SwiftUI

// MARK: - SelectedSessionsPanelView (Single Provider)

public struct SelectedSessionsPanelView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @Binding var primarySessionId: String?

  public init(
    viewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>
  ) {
    self.viewModel = viewModel
    self._primarySessionId = primarySessionId
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.bottom, 8)

      if groupedItems.isEmpty {
        emptyState
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
            ForEach(groupedItems, id: \.modulePath) { group in
              Section(header: ModuleSectionHeader(
                name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
                sessionCount: group.items.count
              )) {
                VStack(spacing: 6) {
                  ForEach(group.items) { item in
                    SelectedSessionRow(
                      session: item.session,
                      providerKind: viewModel.providerKind,
                      timestamp: item.timestamp,
                      isPending: item.isPending,
                      isPrimary: item.id == primarySessionId,
                      customName: viewModel.sessionCustomNames[item.session.id]
                    ) {
                      primarySessionId = item.id
                    }
                  }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .onAppear {
      ensurePrimarySelection()
    }
    .onChange(of: items.map(\.id)) { _, _ in
      ensurePrimarySelection()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text("Selected Sessions")
        .font(.headline)

      Text("\(items.count)")
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer()

    }
    .padding(.horizontal, 4)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.title2)
        .foregroundColor(.secondary.opacity(0.6))
      Text("No Selected Sessions")
        .font(.headline)
        .foregroundColor(.secondary)
      Text("Monitor a session to see it here.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, 24)
  }

  // MARK: - Data

  private struct SelectedSessionItem: Identifiable {
    let id: String
    let session: CLISession
    let timestamp: Date
    let modulePath: String
    let isPending: Bool
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in viewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        timestamp: pending.startedAt,
        modulePath: findModulePath(for: pending.worktree.path),
        isPending: true
      ))
    }

    for item in viewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: item.session.id,
        session: item.session,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private var groupedItems: [(modulePath: String, items: [SelectedSessionItem])] {
    let grouped = Dictionary(grouping: items) { $0.modulePath }
    return grouped.sorted { $0.key < $1.key }
      .map { (modulePath: $0.key, items: $0.value.sorted { $0.timestamp > $1.timestamp }) }
  }

  private func findModulePath(for itemPath: String) -> String {
    for repo in viewModel.selectedRepositories {
      for worktree in repo.worktrees where worktree.path == itemPath {
        return repo.path
      }
    }
    return itemPath
  }

  private func ensurePrimarySelection() {
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = items.first?.id
  }
}

// MARK: - MultiProviderSelectedSessionsPanelView

public struct MultiProviderSelectedSessionsPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Binding var primarySessionId: String?

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._primarySessionId = primarySessionId
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.bottom, 8)

      if groupedItems.isEmpty {
        emptyState
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
            ForEach(groupedItems, id: \.modulePath) { group in
              Section(header: ModuleSectionHeader(
                name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
                sessionCount: group.items.count
              )) {
                VStack(spacing: 6) {
                  ForEach(group.items) { item in
                    SelectedSessionRow(
                      session: item.session,
                      providerKind: item.providerKind,
                      timestamp: item.timestamp,
                      isPending: item.isPending,
                      isPrimary: item.id == primarySessionId,
                      customName: customName(for: item)
                    ) {
                      primarySessionId = item.id
                    }
                  }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .onAppear {
      ensurePrimarySelection()
    }
    .onChange(of: items.map(\.id)) { _, _ in
      ensurePrimarySelection()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text("Selected Sessions")
        .font(.headline)

      Text("\(items.count)")
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer()

    }
    .padding(.horizontal, 4)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.title2)
        .foregroundColor(.secondary.opacity(0.6))
      Text("No Selected Sessions")
        .font(.headline)
        .foregroundColor(.secondary)
      Text("Monitor a session to see it here.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, 24)
  }

  // MARK: - Data

  private struct SelectedSessionItem: Identifiable {
    let id: String
    let session: CLISession
    let providerKind: SessionProviderKind
    let timestamp: Date
    let modulePath: String
    let isPending: Bool
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in claudeViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-claude-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .claude,
        timestamp: pending.startedAt,
        modulePath: findModulePath(for: pending.worktree.path),
        isPending: true
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        modulePath: findModulePath(for: pending.worktree.path),
        isPending: true
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private var groupedItems: [(modulePath: String, items: [SelectedSessionItem])] {
    let grouped = Dictionary(grouping: items) { $0.modulePath }
    return grouped.sorted { $0.key < $1.key }
      .map { (modulePath: $0.key, items: $0.value.sorted { $0.timestamp > $1.timestamp }) }
  }

  private var allSelectedRepositories: [SelectedRepository] {
    var map: [String: SelectedRepository] = [:]
    for repo in claudeViewModel.selectedRepositories {
      map[repo.path] = repo
    }
    for repo in codexViewModel.selectedRepositories where map[repo.path] == nil {
      map[repo.path] = repo
    }
    return map.values.sorted { $0.path < $1.path }
  }

  private func findModulePath(for itemPath: String) -> String {
    for repo in allSelectedRepositories {
      for worktree in repo.worktrees where worktree.path == itemPath {
        return repo.path
      }
    }
    return itemPath
  }

  private func customName(for item: SelectedSessionItem) -> String? {
    switch item.providerKind {
    case .claude:
      return claudeViewModel.sessionCustomNames[item.session.id]
    case .codex:
      return codexViewModel.sessionCustomNames[item.session.id]
    }
  }

  private func ensurePrimarySelection() {
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = items.first?.id
  }
}

// MARK: - SelectedSessionRow

private struct SelectedSessionRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let isPrimary: Bool
  let customName: String?
  let onSelect: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 0) {
      // Indentation spacer
      Color.clear
        .frame(width: 20)

      // Status indicator dot - more prominent
      Circle()
        .fill(statusColor)
        .frame(width: 10, height: 10)
        .overlay(
          Circle()
            .strokeBorder(statusColor.opacity(0.3), lineWidth: 2)
        )
        .padding(.trailing, 12)

      // Content
      VStack(alignment: .leading, spacing: 6) {
        // Top row: Session name and badges
        HStack(spacing: 6) {
          if let customName {
            Text(customName)
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .lineLimit(1)
          } else if let slug = session.slug {
            Text(slug)
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .lineLimit(1)

            Text("•")
              .font(.caption2)
              .foregroundColor(.secondary)

            Text(session.shortId)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.secondary)
          } else {
            Text(session.shortId)
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .lineLimit(1)
          }

          if isPending {
            Text("Starting")
              .font(.system(size: 9, weight: .semibold))
              .foregroundColor(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.15))
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }

          Spacer()

          // Provider badge (smaller)
          Text(providerKind.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.brandPrimary(for: providerKind))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.brandPrimary(for: providerKind).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }

        // Bottom row: Branch and metadata - monospace and smaller
        HStack(spacing: 6) {
          if let branch = session.branchName {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
              Text(branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Text("•")
              .font(.system(size: 10))
              .foregroundColor(.secondary.opacity(0.6))
          }

          Text("\(session.messageCount) msgs")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)

          Text("•")
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.6))

          Text(timestamp.timeAgoDisplay())
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .lineLimit(1)
      }
      .padding(.vertical, 10)

      Spacer(minLength: 8)
    }
    .padding(.trailing, 12)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(rowBackgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isPrimary ? Color.brandPrimary(for: providerKind).opacity(0.3) : Color.clear, lineWidth: 1.5)
    )
    .help(isPrimary ? "Primary session (active)" : "Click to select")
  }

  private var statusColor: Color {
    if isPrimary {
      return Color.green // Active session
    } else if isPending {
      return Color.orange // Starting
    } else {
      return Color.gray.opacity(0.4) // Idle
    }
  }

  private var rowBackgroundColor: Color {
    if isPrimary {
      return colorScheme == .dark
        ? Color.brandPrimary(for: providerKind).opacity(0.12)
        : Color.brandPrimary(for: providerKind).opacity(0.08)
    } else {
      return Color.clear
    }
  }
}

// MARK: - ModuleSectionHeader

private struct ModuleSectionHeader: View {
  let name: String
  let sessionCount: Int
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 8) {
      // Repository name - larger and bolder
      Text(name)
        .font(.system(size: 14, weight: .bold))
        .foregroundColor(.primary)

      // Session count badge
      Text("\(sessionCount)")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.brandPrimary(from: runtimeTheme).opacity(0.8))
        )

      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(Color.surfaceCanvas.opacity(0.5))
  }
}
