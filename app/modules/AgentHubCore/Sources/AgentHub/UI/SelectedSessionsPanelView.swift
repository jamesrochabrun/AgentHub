//
//  SelectedSessionsPanelView.swift
//  AgentHub
//
//  Created by Assistant on 2/4/26.
//

import SwiftUI

// MARK: - ApprovalSectionHeader

/// Section header for sessions awaiting tool approval
private struct ApprovalSectionHeader: View {
  let sessionCount: Int

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.yellow)
        .font(.caption)
      Text("Requires Approval")
        .font(.secondarySmall)
        .foregroundColor(.yellow)
      Spacer()
      Text("\(sessionCount)")
        .font(.secondarySmall)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 10)
  }
}

// MARK: - SelectedSessionsPanelView (Single Provider)

public struct SelectedSessionsPanelView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @Binding var primarySessionId: String?
  @AppStorage(AgentHubDefaults.approvalPrioritySorting)
  private var approvalPrioritySorting: Bool = true

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

      if groupedItems.isEmpty && approvalItems.isEmpty {
        emptyState
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
            if !approvalItems.isEmpty {
              Section(header: ApprovalSectionHeader(sessionCount: approvalItems.count)) {
                ForEach(approvalItems) { item in
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
            }

            ForEach(groupedItems, id: \.modulePath) { group in
              Section(header: ModuleSectionHeader(
                name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
                sessionCount: group.items.count
              )) {
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
        .font(.heading)

      Text("\(items.count)")
        .font(.secondaryCaption)
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
        .font(.heading)
        .foregroundColor(.secondary)
      Text("Monitor a session to see it here.")
        .font(.secondaryCaption)
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
    let isAwaitingApproval: Bool
    let approvalTimestamp: Date?
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in viewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        timestamp: pending.startedAt,
        modulePath: findModulePath(for: pending.worktree.path),
        isPending: true,
        isAwaitingApproval: false,
        approvalTimestamp: nil
      ))
    }

    for item in viewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: item.session.id,
        session: item.session,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false,
        isAwaitingApproval: item.state?.isAwaitingApproval ?? false,
        approvalTimestamp: item.state?.pendingToolUse?.timestamp
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private var approvalItems: [SelectedSessionItem] {
    guard approvalPrioritySorting else { return [] }
    return items
      .filter { $0.isAwaitingApproval }
      .sorted { ($0.approvalTimestamp ?? .distantFuture) < ($1.approvalTimestamp ?? .distantFuture) }
  }

  private var groupedItems: [(modulePath: String, items: [SelectedSessionItem])] {
    let itemsToGroup = approvalPrioritySorting
      ? items.filter { !$0.isAwaitingApproval }
      : items
    let grouped = Dictionary(grouping: itemsToGroup) { $0.modulePath }
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
  @AppStorage(AgentHubDefaults.approvalPrioritySorting)
  private var approvalPrioritySorting: Bool = true

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

      if groupedItems.isEmpty && approvalItems.isEmpty {
        emptyState
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
            if !approvalItems.isEmpty {
              Section(header: ApprovalSectionHeader(sessionCount: approvalItems.count)) {
                ForEach(approvalItems) { item in
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
            }

            ForEach(groupedItems, id: \.modulePath) { group in
              Section(header: ModuleSectionHeader(
                name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
                sessionCount: group.items.count
              )) {
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
        .font(.heading)

      Text("\(items.count)")
        .font(.secondaryCaption)
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
        .font(.heading)
        .foregroundColor(.secondary)
      Text("Monitor a session to see it here.")
        .font(.secondaryCaption)
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
    let isAwaitingApproval: Bool
    let approvalTimestamp: Date?
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
        isPending: true,
        isAwaitingApproval: false,
        approvalTimestamp: nil
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        modulePath: findModulePath(for: pending.worktree.path),
        isPending: true,
        isAwaitingApproval: false,
        approvalTimestamp: nil
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false,
        isAwaitingApproval: item.state?.isAwaitingApproval ?? false,
        approvalTimestamp: item.state?.pendingToolUse?.timestamp
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.session.lastActivityAt,
        modulePath: findModulePath(for: item.session.projectPath),
        isPending: false,
        isAwaitingApproval: item.state?.isAwaitingApproval ?? false,
        approvalTimestamp: item.state?.pendingToolUse?.timestamp
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private var approvalItems: [SelectedSessionItem] {
    guard approvalPrioritySorting else { return [] }
    return items
      .filter { $0.isAwaitingApproval }
      .sorted { ($0.approvalTimestamp ?? .distantFuture) < ($1.approvalTimestamp ?? .distantFuture) }
  }

  private var groupedItems: [(modulePath: String, items: [SelectedSessionItem])] {
    let itemsToGroup = approvalPrioritySorting
      ? items.filter { !$0.isAwaitingApproval }
      : items
    let grouped = Dictionary(grouping: itemsToGroup) { $0.modulePath }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Circle()
          .fill(isPrimary ? Color.brandPrimary(for: providerKind) : .gray.opacity(0.5))
          .frame(width: 8, height: 8)

        if let customName {
          Text(customName)
            .font(.primaryDefault)
            .fontWeight(.semibold)
            .lineLimit(1)
        } else if let slug = session.slug {
          Text(slug)
            .font(.primaryDefault)
            .fontWeight(.semibold)
            .lineLimit(1)

          Text("•")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)

          Text(session.shortId)
            .font(.primaryDefault)
            .fontWeight(.semibold)
        } else {
          Text("Session: \(session.shortId)")
            .font(.primaryDefault)
            .fontWeight(.semibold)
            .lineLimit(1)
        }

        Text(providerKind.rawValue)
          .font(.secondaryCaption)
          .foregroundColor(.brandPrimary(for: providerKind))

        if isPending {
          Text("Starting")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }

        Spacer()

        if isPrimary {
          Image(systemName: "star.fill")
            .font(.caption2)
            .foregroundColor(.brandPrimary(for: providerKind))
        }
      }

      HStack(spacing: 6) {
        if let branch = session.branchName {
          HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.branch")
              .font(.caption)
            Text(branch)
              .font(.primaryCaption)
              .lineLimit(1)
          }
          .foregroundColor(.secondary)

          Text("\u{2022}")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
        }

        Text("\(session.messageCount) msgs")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)

        Text("\u{2022}")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)

        Text(timestamp.timeAgoDisplay())
          .font(.secondaryCaption)
          .foregroundColor(.secondary)
      }
      .lineLimit(1)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .agentHubFlatRow(isHighlighted: isPrimary, providerKind: providerKind)
    .help(isPrimary ? "Primary session" : "Set as primary")
  }
}

// MARK: - ModuleSectionHeader

private struct ModuleSectionHeader: View {
  let name: String
  let sessionCount: Int

  var body: some View {
    HStack {
      Text(name)
        .font(.heading)
        .foregroundColor(.secondary)
      Spacer()
      Text("\(sessionCount)")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 10)
  }
}
