//
//  MultiProviderSessionsListView.swift
//  AgentHub
//
//  Shows Claude and Codex sections side-by-side in the left panel.
//

import AppKit
import Foundation
import PierreDiffsSwift
import SwiftUI

// MARK: - WorktreeCreateContext

private struct WorktreeCreateContext: Identifiable {
  let id = UUID()
  let providerKind: SessionProviderKind
  let repository: SelectedRepository
}

// MARK: - TerminalConfirmation

private struct TerminalConfirmation: Identifiable {
  let id = UUID()
  let worktree: WorktreeBranch
  let currentBranch: String
}

// MARK: - SessionFileSheetItem

private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - MultiProviderSessionsListView

public struct MultiProviderSessionsListView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Binding var columnVisibility: NavigationSplitViewVisibility

  @State private var createWorktreeContext: WorktreeCreateContext?
  @State private var terminalConfirmation: TerminalConfirmation?
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var isSearchExpanded: Bool = false
  @State private var isMultiLaunchExpanded: Bool = false
  @State private var multiLaunchViewModel: MultiSessionLaunchViewModel?
  @State private var primarySessionId: String?
  @FocusState private var isSearchFieldFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  @AppStorage(AgentHubDefaults.selectedSidePanelProvider)
  private var selectedProviderRaw: String = "Claude"

  private var selectedProvider: SessionProviderKind {
    get { SessionProviderKind(rawValue: selectedProviderRaw) ?? .claude }
  }

  private func setSelectedProvider(_ provider: SessionProviderKind) {
    selectedProviderRaw = provider.rawValue
  }

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    columnVisibility: Binding<NavigationSplitViewVisibility>
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._columnVisibility = columnVisibility
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidePanelView
        .agentHubPanel()
        .navigationSplitViewColumnWidth(min: 300, ideal: 420)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    } detail: {
      MultiProviderMonitoringPanelView(
        claudeViewModel: claudeViewModel,
        codexViewModel: codexViewModel,
        primarySessionId: $primarySessionId
      )
      .padding(12)
      .agentHubPanel()
      .frame(minWidth: 300)
      .padding(.vertical, 8)
      .padding(.horizontal, 8)
    }
    .navigationSplitViewStyle(.balanced)
    .background(appBackground.ignoresSafeArea())
    .onAppear {
      if hasRepositories {
        claudeViewModel.refresh()
        codexViewModel.refresh()
      }
      if multiLaunchViewModel == nil {
        let vm = MultiSessionLaunchViewModel(
          claudeViewModel: claudeViewModel,
          codexViewModel: codexViewModel
        )
        vm.onLaunchCompleted = {
          withAnimation(.easeInOut(duration: 0.25)) {
            isMultiLaunchExpanded = false
          }
        }
        multiLaunchViewModel = vm
      }
    }
    .sheet(item: $createWorktreeContext) { context in
      CreateWorktreeSheet(
        repositoryPath: context.repository.path,
        repositoryName: context.repository.name,
        onDismiss: { createWorktreeContext = nil },
        onCreate: { branchName, directory, baseBranch, onProgress in
          let viewModel = viewModel(for: context.providerKind)
          try await viewModel.createWorktree(
            for: context.repository,
            branchName: branchName,
            directoryName: directory,
            baseBranch: baseBranch,
            onProgress: onProgress
          )
          // Refresh both providers after worktree operations
          claudeViewModel.refresh()
          codexViewModel.refresh()
        }
      )
    }
    .sheet(item: $sessionFileSheetItem) { item in
      SessionFileSheetView(
        session: item.session,
        fileName: item.fileName,
        content: item.content,
        onDismiss: { sessionFileSheetItem = nil }
      )
    }
    .alert(
      "Switch Branch?",
      isPresented: Binding(
        get: { terminalConfirmation != nil },
        set: { if !$0 { terminalConfirmation = nil } }
      ),
      presenting: terminalConfirmation
    ) { confirmation in
      Button("Cancel", role: .cancel) {
        terminalConfirmation = nil
      }
      Button("Switch & Open") {
        Task {
          _ = await claudeViewModel.openTerminalAndAutoObserve(
            confirmation.worktree,
            skipCheckout: false
          )
        }
        terminalConfirmation = nil
      }
    } message: { confirmation in
      Text("You have uncommitted changes on '\(confirmation.currentBranch)'. Switching to '\(confirmation.worktree.name)' may fail or carry changes over.")
    }
    .alert(
      "Failed to Delete Worktree",
      isPresented: Binding(
        get: { claudeViewModel.worktreeDeletionError != nil || codexViewModel.worktreeDeletionError != nil },
        set: { if !$0 { claudeViewModel.clearWorktreeDeletionError(); codexViewModel.clearWorktreeDeletionError() } }
      )
    ) {
      let error = claudeViewModel.worktreeDeletionError ?? codexViewModel.worktreeDeletionError
      if let error, error.isOrphaned, let parentRepoPath = error.parentRepoPath {
        Button("Prune & Delete") {
          Task {
            let worktree = error.worktree
            await claudeViewModel.deleteOrphanedWorktree(worktree, parentRepoPath: parentRepoPath)
            await codexViewModel.deleteOrphanedWorktree(worktree, parentRepoPath: parentRepoPath)
          }
        }
        Button("Cancel", role: .cancel) {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.clearWorktreeDeletionError()
        }
      } else {
        Button("OK", role: .cancel) {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.clearWorktreeDeletionError()
        }
      }
    } message: {
      let error = claudeViewModel.worktreeDeletionError ?? codexViewModel.worktreeDeletionError
      if let error {
        if error.isOrphaned, let parentRepoPath = error.parentRepoPath {
          Text("The worktree at:\n\(error.worktree.path)\n\nhas no parent repo. You can prune and delete it from:\n\(parentRepoPath)")
        } else {
          Text(error.message)
        }
      }
    }
  }

  // MARK: - UI Helpers

  private var appBackground: some View {
    LinearGradient(
      colors: [
        Color.surfaceCanvas,
        Color.surfaceCanvas.opacity(colorScheme == .dark ? 0.98 : 0.94),
        Color.brandTertiary.opacity(colorScheme == .dark ? 0.06 : 0.1)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var sessionListContent: some View {
    VStack(spacing: 0) {
      ProviderSegmentedControl(
        selectedProvider: Binding(
          get: { selectedProvider },
          set: { setSelectedProvider($0) }
        ),
        claudeSessionCount: claudeViewModel.totalSessionCount,
        codexSessionCount: codexViewModel.totalSessionCount
      )
      .padding(.bottom, 12)

      // Multi-Session Launch
      if let multiLaunchViewModel {
        MultiSessionLaunchView(
          viewModel: multiLaunchViewModel,
          isExpanded: $isMultiLaunchExpanded,
          allRepositories: allRepositories
        )
        .padding(.bottom, 6)
      }

      CLIRepositoryPickerView(onAddRepository: showAddRepositoryPicker)
        .padding(.bottom, 6)

      // Collapsible search bar
      if isSearchExpanded {
        expandedSearchBar
          .padding(.bottom, 6)
      } else {
        collapsedSearchButton
          .padding(.bottom, 6)
      }

      // Status header (modules/sessions count + First/Last toggle)
      if hasCurrentProviderRepositories {
        statusHeader
          .padding(.bottom, 6)
      }

      if !hasCurrentProviderRepositories {
        CLIEmptyStateView(onAddRepository: showAddRepositoryPicker)
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 16) {
            selectedProviderContent
          }
          .padding(.vertical, 4)
        }
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isSearchExpanded)
    .onChange(of: currentViewModel.hasPerformedSearch) { oldValue, newValue in
      // Auto-collapse search when cleared after selecting a result
      if oldValue && !newValue && isSearchExpanded {
        withAnimation(.easeInOut(duration: 0.25)) {
          isSearchExpanded = false
        }
      }
    }
  }

  @AppStorage(AgentHubDefaults.selectedSessionsPanelSizeMode)
  private var panelSizeModeRawValue: Int = PanelSizeMode.small.rawValue

  private var panelSizeMode: PanelSizeMode {
    PanelSizeMode(rawValue: panelSizeModeRawValue) ?? .small
  }

  private var sidePanelView: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if panelSizeMode != .full {
          sessionListContent
            .padding(12)
        }

        CollapsibleSelectedSessionsPanel(
          claudeViewModel: claudeViewModel,
          codexViewModel: codexViewModel,
          primarySessionId: $primarySessionId
        )
        .frame(height: panelHeight(for: geometry.size.height))
      }
    }
  }

  private func panelHeight(for availableHeight: CGFloat) -> CGFloat {
    let headerHeight: CGFloat = 40
    let monitoredCount = claudeViewModel.monitoredSessions.count +
      codexViewModel.monitoredSessions.count +
      claudeViewModel.pendingHubSessions.count +
      codexViewModel.pendingHubSessions.count

    guard monitoredCount > 0 else { return 0 }

    switch panelSizeMode {
    case .collapsed:
      return headerHeight
    case .small:
      return 250 + headerHeight
    case .medium:
      return availableHeight / 2  // Center Y point
    case .full:
      return availableHeight
    }
  }

  // MARK: - Collapsible Search Button

  private var collapsedSearchButton: some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.25)) {
        isSearchExpanded = true
      }
      // Focus the text field after a brief delay to let the view appear
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        isSearchFieldFocused = true
      }
    }) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(.secondary)
        Text("Search all sessions...")
          .font(.system(size: 13))
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(Color.surfaceOverlay)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Expanded Search Bar

  private var expandedSearchBar: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        searchBarContent

        // Close button to collapse back to button
        Button(action: { dismissSearch() }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }

      // Search results dropdown
      if currentViewModel.hasPerformedSearch && !currentViewModel.isSearching {
        searchResultsDropdown
      }
    }
    .animation(.easeInOut(duration: 0.2), value: currentViewModel.hasPerformedSearch)
  }

  private var searchBarContent: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)

      Button(action: { currentViewModel.showSearchFilterPicker() }) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(currentViewModel.hasSearchFilter ? .brandPrimary(for: currentViewModel.providerKind) : .secondary)
      }
      .buttonStyle(.plain)
      .help("Filter by repository")

      if let filterName = currentViewModel.searchFilterName {
        HStack(spacing: 4) {
          Text(filterName)
            .font(.system(.caption, weight: .medium))
            .foregroundColor(.brandPrimary(for: currentViewModel.providerKind))
          Button(action: { currentViewModel.clearSearchFilter() }) {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundColor(.brandPrimary(for: currentViewModel.providerKind).opacity(0.8))
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Capsule()
            .fill(Color.brandPrimary(for: currentViewModel.providerKind).opacity(0.15))
        )
      }

      TextField(
        currentViewModel.hasSearchFilter ? "Search in \(currentViewModel.searchFilterName ?? "")..." : "Search all sessions...",
        text: Binding(
          get: { currentViewModel.searchQuery },
          set: { currentViewModel.searchQuery = $0 }
        )
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .focused($isSearchFieldFocused)
      .onSubmit { currentViewModel.performSearch() }

      if !currentViewModel.searchQuery.isEmpty {
        Button(action: { currentViewModel.clearSearch() }) {
          Image(systemName: "delete.left.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)

        if currentViewModel.isSearching {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 20, height: 20)
        } else {
          Button(action: { currentViewModel.performSearch() }) {
            Image(systemName: "arrow.right.circle.fill")
              .foregroundColor(.brandPrimary(for: currentViewModel.providerKind))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(currentViewModel.isSearchActive || currentViewModel.hasSearchFilter ? Color.brandPrimary(for: currentViewModel.providerKind).opacity(0.5) : Color.borderSubtle, lineWidth: 1)
    )
  }

  private var searchResultsDropdown: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
        .padding(.bottom, 4)

      if currentViewModel.searchResults.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 28))
            .foregroundColor(.secondary.opacity(0.6))
          Text("No sessions found")
            .font(.system(.headline, weight: .medium))
            .foregroundColor(.secondary)
          Text("Try a different search term")
            .font(.caption)
            .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
      } else {
        ForEach(currentViewModel.searchResults) { result in
          SearchResultRow(
            result: result,
            onSelect: { handleSearchSelection(result, for: currentViewModel) }
          )
        }
      }
    }
    .padding(.vertical, 8)
  }

  private func dismissSearch() {
    withAnimation(.easeInOut(duration: 0.25)) {
      isSearchExpanded = false
    }
    currentViewModel.clearSearch()
  }

  @ViewBuilder
  private var selectedProviderContent: some View {
    let isClaudeSelected = selectedProvider == .claude
    let viewModel = isClaudeSelected ? claudeViewModel : codexViewModel
    let providerKind: SessionProviderKind = isClaudeSelected ? .claude : .codex
    let isInstalled = isClaudeSelected ? claudeInstalled : codexInstalled
    let hasRepositories = isClaudeSelected ? !claudeViewModel.selectedRepositories.isEmpty : !codexViewModel.selectedRepositories.isEmpty

    if !isInstalled {
      CLINotInstalledView(provider: selectedProvider)
    } else if hasRepositories {
      ProviderSectionView(
        viewModel: viewModel,
        onRemoveRepository: removeRepository,
        onCreateWorktree: { repository in
          createWorktreeContext = WorktreeCreateContext(providerKind: providerKind, repository: repository)
        },
        onOpenTerminalForWorktree: { worktree in
          handleOpenTerminal(worktree: worktree, viewModel: viewModel)
        },
        onOpenSessionFile: { session in
          openSessionFile(for: session, viewModel: viewModel)
        }
      )
    } else {
      noSessionsView
    }
  }

  private var noSessionsView: some View {
    VStack(spacing: 10) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.system(size: 28))
        .foregroundColor(.secondary.opacity(0.6))
      Text("No sessions found")
        .font(.headline)
        .foregroundColor(.secondary)
      Text("Start a session in Claude or Codex to see it here.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private var statusHeader: some View {
    VStack(spacing: 8) {
      if isLoading {
        HStack(spacing: 8) {
          ProgressView().scaleEffect(0.7)
          Text("Refreshing sessions...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(Color.blue.opacity(0.1))
        )
      }

      HStack {
        Text("\(currentViewModel.selectedRepositories.count) \(currentViewModel.selectedRepositories.count == 1 ? "module" : "modules") · \(currentViewModel.allSessions.count) \(currentViewModel.allSessions.count == 1 ? "session" : "sessions") · \(currentViewModel.monitoredSessionIds.count) in Hub")
          .font(.caption)
          .foregroundColor(.secondary)

        Spacer()

        // Toggle first/last message (per provider)
        Button(action: { toggleShowLastMessage() }) {
          HStack(spacing: 6) {
            Image(systemName: currentViewModel.showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text(currentViewModel.showLastMessage ? "Last" : "First")
              .font(.system(.caption, weight: .medium))
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs + 2)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .fill(Color.surfaceOverlay)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .stroke(Color.borderSubtle, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .help(currentViewModel.showLastMessage ? "Showing last message" : "Showing first message")

        // Refresh button
        Button(action: { currentViewModel.refresh() }) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: DesignTokens.IconSize.md))
            .frame(width: 28, height: 28)
            .background(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(Color.surfaceOverlay)
            )
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help("Refresh sessions")
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - Actions

  private func showAddRepositoryPicker() {
    let panel = NSOpenPanel()
    panel.title = "Select Repository"
    panel.message = "Choose a git repository to monitor CLI sessions"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      addRepository(at: url.path)
    }
  }

  private func addRepository(at path: String) {
    currentViewModel.addRepository(at: path)
  }

  private func removeRepository(_ repository: SelectedRepository) {
    currentViewModel.removeRepository(repository)
  }

  private func handleOpenTerminal(worktree: WorktreeBranch, viewModel: CLISessionsViewModel) {
    Task {
      let check = await viewModel.checkBeforeOpeningTerminal(worktree)

      if !check.needsCheckout {
        _ = await viewModel.openTerminalAndAutoObserve(worktree, skipCheckout: true)
      } else if check.hasUncommittedChanges {
        terminalConfirmation = TerminalConfirmation(worktree: worktree, currentBranch: check.currentBranch)
      } else {
        _ = await viewModel.openTerminalAndAutoObserve(worktree, skipCheckout: false)
      }
    }
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

  private func handleSearchSelection(_ result: SessionSearchResult, for viewModel: CLISessionsViewModel) {
    viewModel.selectSearchResult(result)
    let otherViewModel = viewModel.providerKind == .claude ? codexViewModel : claudeViewModel
    if !otherViewModel.selectedRepositories.contains(where: { $0.path == result.projectPath }) {
      otherViewModel.addRepository(at: result.projectPath)
    }
  }

  private func viewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    switch provider {
    case .claude: return claudeViewModel
    case .codex: return codexViewModel
    }
  }

  private var currentViewModel: CLISessionsViewModel {
    viewModel(for: selectedProvider)
  }

  private func toggleShowLastMessage() {
    currentViewModel.showLastMessage.toggle()
  }

  // MARK: - Computed

  private var claudeInstalled: Bool {
    CLIDetectionService.isClaudeInstalled()
  }

  private var codexInstalled: Bool {
    CLIDetectionService.isCodexInstalled()
  }

  private var claudeHasSessions: Bool {
    claudeViewModel.totalSessionCount + claudeViewModel.pendingHubSessions.count > 0
  }

  private var codexHasSessions: Bool {
    codexViewModel.totalSessionCount + codexViewModel.pendingHubSessions.count > 0
  }

  private var hasRepositories: Bool {
    !allRepositories.isEmpty
  }

  private var hasCurrentProviderRepositories: Bool {
    !currentViewModel.selectedRepositories.isEmpty
  }

  private var allRepositories: [SelectedRepository] {
    var map: [String: SelectedRepository] = [:]
    for repo in claudeViewModel.selectedRepositories {
      map[repo.path] = repo
    }
    for repo in codexViewModel.selectedRepositories where map[repo.path] == nil {
      map[repo.path] = repo
    }
    return map.values.sorted { $0.path < $1.path }
  }

  private var totalSessionCount: Int {
    claudeViewModel.totalSessionCount + codexViewModel.totalSessionCount
  }

  private var isLoading: Bool {
    claudeViewModel.isLoading || codexViewModel.isLoading
  }
}

// MARK: - ProviderSectionView

private struct ProviderSectionView: View {
  @Bindable var viewModel: CLISessionsViewModel
  let onRemoveRepository: (SelectedRepository) -> Void
  let onCreateWorktree: (SelectedRepository) -> Void
  let onOpenTerminalForWorktree: (WorktreeBranch) -> Void
  let onOpenSessionFile: (CLISession) -> Void

  var body: some View {
    VStack(spacing: 12) {
      ForEach(viewModel.selectedRepositories) { repository in
        CLIRepositoryTreeView(
          repository: repository,
          providerKind: viewModel.providerKind,
          onRemove: { onRemoveRepository(repository) },
          onToggleExpanded: { viewModel.toggleRepositoryExpanded(repository) },
          onToggleWorktreeExpanded: { worktree in
            viewModel.toggleWorktreeExpanded(in: repository, worktree: worktree)
          },
          onConnectSession: { session in
            _ = viewModel.connectToSession(session)
          },
          onCopySessionId: { session in
            viewModel.copySessionId(session)
          },
          onOpenSessionFile: { session in
            onOpenSessionFile(session)
          },
          isSessionMonitored: { sessionId in
            viewModel.isMonitoring(sessionId: sessionId)
          },
          onToggleMonitoring: { session in
            viewModel.toggleMonitoring(for: session)
          },
          onCreateWorktree: {
            onCreateWorktree(repository)
          },
          onOpenTerminalForWorktree: { worktree in
            onOpenTerminalForWorktree(worktree)
          },
          onOpenTerminalDangerousForWorktree: { worktree in
            _ = viewModel.openTerminalInWorktree(worktree, skipCheckout: true, dangerouslySkipPermissions: true)
          },
          onStartInHubForWorktree: { worktree in
            viewModel.startNewSessionInHub(worktree)
          },
          onStartInHubDangerousForWorktree: { worktree in
            viewModel.startNewSessionInHub(worktree, dangerouslySkipPermissions: true)
          },
          onDeleteWorktree: { worktree in
            Task { await viewModel.deleteWorktree(worktree) }
          },
          getCustomName: { sessionId in
            viewModel.sessionCustomNames[sessionId]
          },
          showLastMessage: viewModel.showLastMessage,
          isDebugMode: true,
          deletingWorktreePath: viewModel.deletingWorktreePath
        )
      }
    }
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

// MARK: - SessionFileSheetView

private struct SessionFileSheetView: View {
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
