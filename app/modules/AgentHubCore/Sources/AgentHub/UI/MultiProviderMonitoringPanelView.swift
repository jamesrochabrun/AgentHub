//
//  MultiProviderMonitoringPanelView.swift
//  AgentHub
//
//  Combines Claude + Codex monitored sessions into a single panel.
//

import ClaudeCodeSDK
import Foundation
import PierreDiffsSwift
import SwiftUI

// MARK: - SidePanelContent

private enum SidePanelContent: Equatable {
  case diff(sessionId: String, session: CLISession, projectPath: String)
  case plan(sessionId: String, session: CLISession, planState: PlanState)
  case webPreview(sessionId: String, session: CLISession, projectPath: String)

  static func == (lhs: SidePanelContent, rhs: SidePanelContent) -> Bool {
    switch (lhs, rhs) {
    case (.diff(let id1, _, let p1), .diff(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    case (.plan(let id1, _, _), .plan(let id2, _, _)):
      return id1 == id2
    case (.webPreview(let id1, _, let p1), .webPreview(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    default: return false
    }
  }
}

// MARK: - SessionFileSheetItem

private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - LayoutMode

private enum LayoutMode: Int, CaseIterable {
  case single = 0
  case list = 1
  case twoColumn = 2
  case threeColumn = 3

  var columnCount: Int {
    switch self {
    case .single: return 1
    case .list: return 1
    case .twoColumn: return 2
    case .threeColumn: return 3
    }
  }

  var icon: String {
    switch self {
    case .single: return "rectangle"
    case .list: return "list.bullet"
    case .twoColumn: return "square.grid.2x2"
    case .threeColumn: return "square.grid.3x3"
    }
  }
}

// MARK: - HubFilterMode

private enum HubFilterMode: Int, CaseIterable {
  case all = 0
  case claude = 1
  case codex = 2

  var displayName: String {
    switch self {
    case .all: return "All"
    case .claude: return "Claude"
    case .codex: return "Codex"
    }
  }
}

// MARK: - ModuleSectionHeader

private struct ModuleSectionHeader: View {
  let name: String
  let sessionCount: Int

  var body: some View {
    HStack {
      Text(name)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.secondary)
      Spacer()
      Text("\(sessionCount)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 10)
  }
}

// MARK: - HubFilterControl

private struct HubFilterControl: View {
  @Binding var filterMode: HubFilterMode
  let claudeCount: Int
  let codexCount: Int
  let totalCount: Int

  var body: some View {
    HStack(spacing: 12) {
      filterTab(for: .all, count: totalCount)
      filterTab(for: .claude, count: claudeCount)
      filterTab(for: .codex, count: codexCount)
    }
  }

  private func filterTab(for mode: HubFilterMode, count: Int) -> some View {
    let isSelected = filterMode == mode

    return Button(action: { filterMode = mode }) {
      VStack(spacing: 2) {
        HStack(spacing: 3) {
          Text(mode.displayName)
            .fontWeight(isSelected ? .semibold : .regular)
          Text("\(count)")
            .foregroundColor(.secondary)
        }
        .font(.caption)
        .foregroundColor(isSelected ? .primary : .secondary)

        // Underline indicator
        Rectangle()
          .fill(Color.primary)
          .frame(height: 1.5)
          .opacity(isSelected ? 1 : 0)
      }
      .padding(.horizontal, 4)
      .fixedSize()
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.2), value: filterMode)
  }
}

// MARK: - ProviderMonitoringItem

enum ProviderMonitoringItem: Identifiable {
  case pending(provider: SessionProviderKind, viewModel: CLISessionsViewModel, pending: PendingHubSession)
  case monitored(provider: SessionProviderKind, viewModel: CLISessionsViewModel, session: CLISession, state: SessionMonitorState?)

  var id: String {
    switch self {
    case .pending(let provider, _, let pending):
      return "pending-\(provider.rawValue.lowercased())-\(pending.id.uuidString)"
    case .monitored(let provider, _, let session, _):
      return "\(provider.rawValue.lowercased())-\(session.id)"
    }
  }

  var sessionId: String {
    switch self {
    case .pending(_, _, let pending):
      return "pending-\(pending.id.uuidString)"
    case .monitored(_, _, let session, _):
      return session.id
    }
  }

  var projectPath: String {
    switch self {
    case .pending(_, _, let pending):
      return pending.worktree.path
    case .monitored(_, _, let session, _):
      return session.projectPath
    }
  }

  var timestamp: Date {
    switch self {
    case .pending(_, _, let pending):
      return pending.startedAt
    case .monitored(_, _, let session, let state):
      return state?.lastActivityAt ?? session.lastActivityAt
    }
  }

  var providerKind: SessionProviderKind {
    switch self {
    case .pending(let provider, _, _): return provider
    case .monitored(let provider, _, _, _): return provider
    }
  }

  var viewModel: CLISessionsViewModel {
    switch self {
    case .pending(_, let viewModel, _): return viewModel
    case .monitored(_, let viewModel, _, _): return viewModel
    }
  }
}

// MARK: - MultiProviderMonitoringPanelView

public struct MultiProviderMonitoringPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var maximizedSessionId: String?
  @State private var sidePanelContent: SidePanelContent?
  @State private var filterMode: HubFilterMode = .all
  @State private var availableDetailWidth: CGFloat = 0
  @Binding var primarySessionId: String?
  @AppStorage(AgentHubDefaults.hubLayoutMode)
  private var layoutModeRawValue: Int = LayoutMode.single.rawValue
  @Environment(\.colorScheme) private var colorScheme

  private var layoutMode: LayoutMode {
    get { LayoutMode(rawValue: layoutModeRawValue) ?? .single }
  }

  private var canShowSidePanel: Bool {
    availableDetailWidth >= 900
  }

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
      if let maximizedId = maximizedSessionId {
        maximizedCardContent(for: maximizedId)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(white: colorScheme == .dark ? 0.07 : 0.92))
      } else {
        header

        Divider()

        if allItems.isEmpty {
          emptyState
        } else if layoutMode != .single && visibleItems.isEmpty {
          filteredEmptyState
        } else if visibleItems.isEmpty {
          emptyState
        } else {
          monitoredSessionsList
        }
      }
    }
    .background(colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.96))
    .cornerRadius(8)
    .sheet(item: $sessionFileSheetItem) { item in
      MonitoringSessionFileSheetView(
        session: item.session,
        fileName: item.fileName,
        content: item.content,
        onDismiss: { sessionFileSheetItem = nil }
      )
    }
    .onKeyPress(.escape) {
      if maximizedSessionId != nil {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
          maximizedSessionId = nil
        }
        return .handled
      }
      return .ignored
    }
    .onAppear {
      ensurePrimarySelection()
    }
    .onChange(of: allItems.map(\.id)) { _, _ in
      ensurePrimarySelection()
    }
    .onChange(of: layoutModeRawValue) { _, _ in
      if layoutMode == .single {
        filterMode = .all
      }
    }
    .onChange(of: effectivePrimarySessionId) { _, _ in
      sidePanelContent = nil
    }
    .onChange(of: canShowSidePanel) { _, canShow in
      if !canShow {
        withAnimation(.easeInOut(duration: 0.25)) {
          sidePanelContent = nil
        }
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Text("Hub")
        .font(.system(size: 13, weight: .bold, design: .monospaced))

      // Provider filter toggle (hidden in single mode)
      if layoutMode != .single {
        HubFilterControl(
          filterMode: $filterMode,
          claudeCount: claudeItemCount,
          codexCount: codexItemCount,
          totalCount: allItems.count
        )
      }

      Spacer()

      // Layout mode toggle (single / list / grid)
      HStack(spacing: 6) {
        ForEach(LayoutMode.allCases, id: \.self) { mode in
          Button(action: { layoutModeRawValue = mode.rawValue }) {
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
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Session Selected")
        .font(.headline)
        .foregroundColor(.secondary)

      (Text("Select a session from the sidebar or ") + Text("start a new one").bold() + Text(" to get started."))
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Filtered Empty State

  private var filteredEmptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No \(filterMode.displayName) Sessions")
        .font(.headline)
        .foregroundColor(.secondary)

      Button("Show All") {
        filterMode = .all
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Monitored Sessions List

  @ViewBuilder
  private var monitoredSessionsList: some View {
    if layoutMode == .single {
      singleModeContent
        .background(
          GeometryReader { geometry in
            Color.clear
              .onAppear { availableDetailWidth = geometry.size.width }
              .onChange(of: geometry.size.width) { _, newWidth in
                availableDetailWidth = newWidth
              }
          }
        )
    } else {
      ScrollView {
        if layoutMode == .list {
          LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
            monitoredSessionsGroupedContent
          }
          .padding(12)
        } else {
          let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: layoutMode.columnCount)
          LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
            monitoredSessionsGroupedContent
          }
          .padding(12)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: layoutMode)
    }
  }

  // MARK: - Single Mode Content

  @ViewBuilder
  private var singleModeContent: some View {
    if let item = visibleItems.first {
      switch item {
      case .pending(_, let viewModel, let pending):
        let pendingId = "pending-\(pending.id.uuidString)"
        MonitoringCardView(
          session: pending.placeholderSession,
          state: nil,
          claudeClient: viewModel.claudeClient,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: item.providerKind,
          showTerminal: true,
          initialPrompt: pending.initialPrompt,
          terminalKey: pendingId,
          viewModel: viewModel,
          dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
          onToggleTerminal: { _ in },
          onStopMonitoring: { viewModel.cancelPendingSession(pending) },
          onConnect: { },
          onCopySessionId: { },
          onOpenSessionFile: { },
          onRefreshTerminal: { },
          isMaximized: false,
          onToggleMaximize: { },
          isPrimarySession: true,
          showPrimaryIndicator: false
        )
        .id(pendingId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)

      case .monitored(_, let viewModel, let session, let state):
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        HSplitView {
          MonitoringCardView(
            session: session,
            state: state,
            planState: planState,
            claudeClient: viewModel.claudeClient,
            cliConfiguration: viewModel.cliConfiguration,
            providerKind: item.providerKind,
            showTerminal: viewModel.sessionsWithTerminalView.contains(session.id),
            initialPrompt: initialPrompt,
            terminalKey: session.id,
            viewModel: viewModel,
            onToggleTerminal: { show in
              viewModel.setTerminalView(for: session.id, show: show)
            },
            onStopMonitoring: {
              viewModel.stopMonitoring(session: session)
            },
            onConnect: {
              _ = viewModel.connectToSession(session)
            },
            onCopySessionId: {
              viewModel.copySessionId(session)
            },
            onOpenSessionFile: {
              openSessionFile(for: session, viewModel: viewModel)
            },
            onRefreshTerminal: {
              viewModel.refreshTerminal(
                forKey: session.id,
                sessionId: session.id,
                projectPath: session.projectPath
              )
            },
            onInlineRequestSubmit: { prompt, sess in
              viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
            },
            onShowDiff: canShowSidePanel ? { session, projectPath in
              sidePanelContent = .diff(sessionId: session.id, session: session, projectPath: projectPath)
            } : nil,
            onShowPlan: canShowSidePanel ? { session, planState in
              sidePanelContent = .plan(sessionId: session.id, session: session, planState: planState)
            } : nil,
            onShowWebPreview: canShowSidePanel ? { session, projectPath in
              sidePanelContent = .webPreview(sessionId: session.id, session: session, projectPath: projectPath)
            } : nil,
            onPromptConsumed: {
              viewModel.clearPendingPrompt(for: session.id)
            },
            isMaximized: false,
            onToggleMaximize: { },
            isPrimarySession: true,
            showPrimaryIndicator: false,
            isSidePanelOpen: sidePanelContent != nil
          )
          .id(session.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          if let panelContent = sidePanelContent {
            sidePanelView(for: panelContent, viewModel: viewModel)
              .frame(minWidth: 700)
          }
        }
        .padding(12)
      }
    }
  }

  @ViewBuilder
  private func sidePanelView(for content: SidePanelContent, viewModel: CLISessionsViewModel) -> some View {
    switch content {
    case .diff(_, let session, let projectPath):
      GitDiffView(
        session: session,
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        claudeClient: viewModel.claudeClient,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: visibleItems.first?.providerKind ?? .claude,
        onInlineRequestSubmit: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) },
        isEmbedded: true
      )
    case .plan(_, let session, let planState):
      PlanView(
        session: session,
        planState: planState,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true
      )
    case .webPreview(_, let session, let projectPath):
      WebPreviewView(
        session: session,
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true
      )
    }
  }

  @ViewBuilder
  private var monitoredSessionsGroupedContent: some View {
    ForEach(groupedMonitoredSessions, id: \.modulePath) { group in
      Section(header: ModuleSectionHeader(
        name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
        sessionCount: group.items.count
      )) {
        ForEach(group.items) { item in
          let isPrimary = item.id == effectivePrimarySessionId
          switch item {
          case .pending(_, let viewModel, let pending):
            MonitoringCardView(
              session: pending.placeholderSession,
              state: nil,
              claudeClient: viewModel.claudeClient,
              cliConfiguration: viewModel.cliConfiguration,
              providerKind: item.providerKind,
              showTerminal: true,
              initialPrompt: pending.initialPrompt,
              terminalKey: "pending-\(pending.id.uuidString)",
              viewModel: viewModel,
              dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
              onToggleTerminal: { _ in },
              onStopMonitoring: { viewModel.cancelPendingSession(pending) },
              onConnect: { },
              onCopySessionId: { },
              onOpenSessionFile: { },
              onRefreshTerminal: { },
              isMaximized: maximizedSessionId == item.id,
              onToggleMaximize: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                  maximizedSessionId = maximizedSessionId == item.id ? nil : item.id
                }
              },
              isPrimarySession: isPrimary,
              showPrimaryIndicator: layoutMode != .single
            )

          case .monitored(_, let viewModel, let session, let state):
            let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
            let initialPrompt = viewModel.pendingPrompt(for: session.id)

            MonitoringCardView(
              session: session,
              state: state,
              planState: planState,
              claudeClient: viewModel.claudeClient,
              cliConfiguration: viewModel.cliConfiguration,
              providerKind: item.providerKind,
              showTerminal: viewModel.sessionsWithTerminalView.contains(session.id),
              initialPrompt: initialPrompt,
              terminalKey: session.id,
              viewModel: viewModel,
              onToggleTerminal: { show in
                viewModel.setTerminalView(for: session.id, show: show)
              },
              onStopMonitoring: {
                viewModel.stopMonitoring(session: session)
              },
              onConnect: {
                _ = viewModel.connectToSession(session)
              },
              onCopySessionId: {
                viewModel.copySessionId(session)
              },
              onOpenSessionFile: {
                openSessionFile(for: session, viewModel: viewModel)
              },
              onRefreshTerminal: {
                viewModel.refreshTerminal(
                  forKey: session.id,
                  sessionId: session.id,
                  projectPath: session.projectPath
                )
              },
              onInlineRequestSubmit: { prompt, sess in
                viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
              },
              onPromptConsumed: {
                viewModel.clearPendingPrompt(for: session.id)
              },
              isMaximized: maximizedSessionId == item.id,
              onToggleMaximize: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                  maximizedSessionId = maximizedSessionId == item.id ? nil : item.id
                }
              },
              isPrimarySession: isPrimary,
              showPrimaryIndicator: layoutMode != .single
            )
          }
        }
      }
    }
  }

  // MARK: - Filter Helpers

  private func shouldShowItem(_ item: ProviderMonitoringItem) -> Bool {
    switch filterMode {
    case .all: return true
    case .claude: return item.providerKind == .claude
    case .codex: return item.providerKind == .codex
    }
  }

  private var effectivePrimarySessionId: String? {
    if let current = primarySessionId, allItems.contains(where: { $0.id == current }) {
      return current
    }
    return allItems.sorted { $0.timestamp > $1.timestamp }.first?.id
  }

  private var itemsForLayoutMode: [ProviderMonitoringItem] {
    if layoutMode == .single {
      guard let selectedId = effectivePrimarySessionId else { return [] }
      return allItems.filter { $0.id == selectedId }
    }
    return allItems
  }

  private var visibleItems: [ProviderMonitoringItem] {
    if layoutMode == .single {
      return itemsForLayoutMode
    }
    return itemsForLayoutMode.filter { shouldShowItem($0) }
  }

  private var claudeItemCount: Int {
    allItems.filter { $0.providerKind == .claude }.count
  }

  private var codexItemCount: Int {
    allItems.filter { $0.providerKind == .codex }.count
  }

  // MARK: - Helpers

  @ViewBuilder
  private func maximizedCardContent(for itemId: String) -> some View {
    if let item = allItems.first(where: { $0.id == itemId }) {
      let isPrimary = item.id == effectivePrimarySessionId
      switch item {
      case .pending(_, let viewModel, let pending):
        MonitoringCardView(
          session: pending.placeholderSession,
          state: nil,
          claudeClient: viewModel.claudeClient,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: item.providerKind,
          showTerminal: true,
          initialPrompt: pending.initialPrompt,
          terminalKey: "pending-\(pending.id.uuidString)",
          viewModel: viewModel,
          dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
          onToggleTerminal: { _ in },
          onStopMonitoring: {
            viewModel.cancelPendingSession(pending)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          onConnect: { },
          onCopySessionId: { },
          onOpenSessionFile: { },
          onRefreshTerminal: { },
          isMaximized: true,
          onToggleMaximize: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          isPrimarySession: isPrimary,
          showPrimaryIndicator: layoutMode != .single
        )
      case .monitored(_, let viewModel, let session, let state):
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        MonitoringCardView(
          session: session,
          state: state,
          planState: planState,
          claudeClient: viewModel.claudeClient,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: item.providerKind,
          showTerminal: viewModel.sessionsWithTerminalView.contains(session.id),
          initialPrompt: initialPrompt,
          terminalKey: session.id,
          viewModel: viewModel,
          onToggleTerminal: { show in
            viewModel.setTerminalView(for: session.id, show: show)
          },
          onStopMonitoring: {
            viewModel.stopMonitoring(session: session)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          onConnect: {
            _ = viewModel.connectToSession(session)
          },
          onCopySessionId: {
            viewModel.copySessionId(session)
          },
          onOpenSessionFile: {
            openSessionFile(for: session, viewModel: viewModel)
          },
          onRefreshTerminal: {
            viewModel.refreshTerminal(
              forKey: session.id,
              sessionId: session.id,
              projectPath: session.projectPath
            )
          },
          onInlineRequestSubmit: { prompt, sess in
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          },
          onPromptConsumed: {
            viewModel.clearPendingPrompt(for: session.id)
          },
          isMaximized: true,
          onToggleMaximize: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          isPrimarySession: isPrimary,
          showPrimaryIndicator: layoutMode != .single
        )
      }
    }
  }

  private var allItems: [ProviderMonitoringItem] {
    pendingItems + monitoredItems
  }

  private var pendingItems: [ProviderMonitoringItem] {
    let claudePending = claudeViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .claude, viewModel: claudeViewModel, pending: $0)
    }
    let codexPending = codexViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .codex, viewModel: codexViewModel, pending: $0)
    }
    return claudePending + codexPending
  }

  private var monitoredItems: [ProviderMonitoringItem] {
    let claudeItems = claudeViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .claude, viewModel: claudeViewModel, session: $0.session, state: $0.state)
    }
    let codexItems = codexViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .codex, viewModel: codexViewModel, session: $0.session, state: $0.state)
    }
    return claudeItems + codexItems
  }

  private var groupedMonitoredSessions: [(modulePath: String, items: [ProviderMonitoringItem])] {
    let grouped = Dictionary(grouping: visibleItems) { findModulePath(for: $0) }
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

  private func findModulePath(for item: ProviderMonitoringItem) -> String {
    let itemPath = item.projectPath

    for repo in allSelectedRepositories {
      for worktree in repo.worktrees {
        if worktree.path == itemPath {
          return repo.path
        }
      }
    }
    return itemPath
  }

  private func openSessionFile(for session: CLISession, viewModel: CLISessionsViewModel) {
    guard let fileURL = viewModel.sessionFileURL(for: session),
          let data = FileManager.default.contents(atPath: fileURL.path),
          let content = String(data: data, encoding: .utf8) else {
      return
    }

    if !content.isEmpty {
      sessionFileSheetItem = SessionFileSheetItem(
        session: session,
        fileName: fileURL.lastPathComponent,
        content: content
      )
    }
  }

  private func ensurePrimarySelection() {
    guard !allItems.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, allItems.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = effectivePrimarySessionId
  }
}

// MARK: - JSONL Filtering

/// Filters JSONL content for a clean transcript view
/// Shows: user questions, assistant text (truncated), tool names only
/// Removes: tool_result, thinking, file-history-snapshot, large content
private func filterJSONLContent(_ content: String) -> String {
  let lines = content.components(separatedBy: .newlines)
  var result: [String] = []
  let maxTextLength = 500

  for line in lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty { continue }

    guard let data = trimmed.data(using: .utf8) else { continue }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    guard let type = json["type"] as? String else { continue }

    // Codex format: event_msg with payload.type user_message/agent_message
    if type == "event_msg" {
      guard let payload = json["payload"] as? [String: Any],
            let eventType = payload["type"] as? String else { continue }

      if eventType == "user_message" || eventType == "agent_message" {
        let role = eventType == "user_message" ? "user" : "assistant"
        let message = (payload["message"] as? String) ?? ""
        let preview = String(message.prefix(maxTextLength))
        result.append("[\(role)] \(preview)")
      }
      continue
    }

    if type != "user" && type != "assistant" { continue }

    guard let message = json["message"] as? [String: Any] else { continue }
    guard let contentBlocks = message["content"] as? [[String: Any]] else { continue }

    var textParts: [String] = []
    var toolNames: [String] = []
    var hasOnlyToolResults = true

    for block in contentBlocks {
      guard let blockType = block["type"] as? String else { continue }

      switch blockType {
      case "text":
        hasOnlyToolResults = false
        if let text = block["text"] as? String {
          let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !cleaned.isEmpty {
            if cleaned.count > maxTextLength {
              textParts.append(String(cleaned.prefix(maxTextLength)) + "...")
            } else {
              textParts.append(cleaned)
            }
          }
        }

      case "tool_use":
        hasOnlyToolResults = false
        if let name = block["name"] as? String {
          var toolDesc = name
          if let input = block["input"] as? [String: Any] {
            if let filePath = input["file_path"] as? String {
              let fileName = (filePath as NSString).lastPathComponent
              toolDesc = "\(name)(\(fileName))"
            } else if let pattern = input["pattern"] as? String {
              let short = String(pattern.prefix(30))
              toolDesc = "\(name)(\(short))"
            } else if let command = input["command"] as? String {
              let short = String(command.prefix(40))
              toolDesc = "\(name)(\(short)...)"
            }
          }
          toolNames.append(toolDesc)
        }

      case "tool_result", "thinking":
        continue

      default:
        hasOnlyToolResults = false
      }
    }

    if hasOnlyToolResults { continue }

    var output = "[\(type.uppercased())]"

    if !textParts.isEmpty {
      output += " " + textParts.joined(separator: " ")
    }

    if !toolNames.isEmpty {
      output += " [Tools: " + toolNames.joined(separator: ", ") + "]"
    }

    if textParts.isEmpty && toolNames.isEmpty { continue }

    result.append(output)
  }

  if result.isEmpty {
    return "[No conversation content found - this session may only contain file history snapshots or tool results]"
  }

  return result.joined(separator: "\n\n")
}

// MARK: - MonitoringSessionFileSheetView

private struct MonitoringSessionFileSheetView: View {
  let session: CLISession
  let fileName: String
  let content: String
  let onDismiss: () -> Void

  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        HStack(spacing: 8) {
          Image(systemName: "doc.text.fill")
            .foregroundColor(.brandPrimary)
          Text(fileName)
            .font(.system(.headline, design: .monospaced))
        }

        Spacer()

        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()

        Button("Close") { onDismiss() }
      }
      .padding()
      .background(Color.surfaceElevated)

      Divider()

      PierreDiffView(
        oldContent: "",
        newContent: filterJSONLContent(content),
        fileName: fileName,
        diffStyle: $diffStyle,
        overflowMode: $overflowMode
      )
    }
    .frame(minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
           minHeight: 700, idealHeight: 900, maxHeight: .infinity)
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
  }
}
