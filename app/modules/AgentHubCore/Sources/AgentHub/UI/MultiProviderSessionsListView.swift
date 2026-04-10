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

// MARK: - SessionFileSheetItem

private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - MultiProviderSessionsListView

private struct WorktreeCreateContext: Identifiable {
  let id = UUID()
  let providerKind: SessionProviderKind
  let repository: SelectedRepository
}

public struct MultiProviderSessionsListView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Binding var columnVisibility: NavigationSplitViewVisibility

  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var isSearchExpanded: Bool = false
  @State private var isBrowseExpanded: Bool = false
  @State private var multiLaunchViewModel: MultiSessionLaunchViewModel?
  @State private var primarySessionId: String?
  @State private var showDeleteWorktreeAlert = false
  @State private var sessionToDeleteWorktree: CLISession? = nil
  @State private var showCommandPalette = false
  @State private var collapsedProjectGroups: Set<String> = []
  @State private var scrollToSessionId: String?
  @State private var launchExpandRequestID = 0
  @State private var createWorktreeContext: WorktreeCreateContext?
  @AppStorage(AgentHubDefaults.auxiliaryShellVisible) private var isAuxiliaryShellVisible = false
  @State private var isEmbeddedTrailingPanelVisible = false
  @State private var sidebarVisibilityBeforeAutoHide: NavigationSplitViewVisibility?
  @FocusState private var isSearchFieldFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

  @AppStorage(AgentHubDefaults.hubLayoutMode)
  private var layoutModeRawValue: Int = 0

  @AppStorage(AgentHubDefaults.hubPreviousLayoutMode)
  private var previousLayoutModeRawValue: Int = -1

  @AppStorage(AgentHubDefaults.selectedSidePanelProvider)
  private var selectedProviderRaw: String = "Claude"

  private let intelligenceViewModel: IntelligenceViewModel?
  private let worktreeBranchNamingService: (any WorktreeBranchNamingServiceProtocol)?
  private let worktreeSuccessSoundService: (any WorktreeSuccessSoundServiceProtocol)?

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    columnVisibility: Binding<NavigationSplitViewVisibility>,
    intelligenceViewModel: IntelligenceViewModel? = nil,
    worktreeBranchNamingService: (any WorktreeBranchNamingServiceProtocol)? = nil,
    worktreeSuccessSoundService: (any WorktreeSuccessSoundServiceProtocol)? = nil
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._columnVisibility = columnVisibility
    self.intelligenceViewModel = intelligenceViewModel
    self.worktreeBranchNamingService = worktreeBranchNamingService
    self.worktreeSuccessSoundService = worktreeSuccessSoundService
  }

  public var body: some View {
    ZStack {
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
          primarySessionId: $primarySessionId,
          onEmbeddedSidePanelVisibilityChange: handleEmbeddedSidePanelVisibilityChange,
          onRequestStartSession: { preferredRepositoryPath in
            triggerNewSessionFlow(preferredRepositoryPath: preferredRepositoryPath)
          }
        )
        .padding(12)
        .agentHubPanel()
        .frame(minWidth: 300)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
      }
      .navigationSplitViewStyle(.balanced)
      .background(appBackground.ignoresSafeArea())

      // Invisible global keyboard shortcuts.
      keyboardShortcutButtons
    }
    .overlay {
      commandPaletteOverlay
    }
    .onAppear {
      if hasRepositories {
        claudeViewModel.refresh()
        codexViewModel.refresh()
      }
      if multiLaunchViewModel == nil {
        multiLaunchViewModel = MultiSessionLaunchViewModel(
          claudeViewModel: claudeViewModel,
          codexViewModel: codexViewModel,
          intelligenceViewModel: intelligenceViewModel,
          worktreeBranchNamingService: worktreeBranchNamingService,
          worktreeSuccessSoundService: worktreeSuccessSoundService
        )
      }
      ensurePrimarySelection()
    }
    .onChange(of: claudeViewModel.resolvedPendingSessions) { _, newResolutions in
      handleResolvedSessions(newResolutions, provider: .claude, viewModel: claudeViewModel)
    }
    .onChange(of: codexViewModel.resolvedPendingSessions) { _, newResolutions in
      handleResolvedSessions(newResolutions, provider: .codex, viewModel: codexViewModel)
    }
    .onChange(of: claudeViewModel.lastCreatedPendingId) { _, newId in
      guard let newId else { return }
      primarySessionId = "pending-claude-\(newId.uuidString)"
      claudeViewModel.lastCreatedPendingId = nil
    }
    .onChange(of: codexViewModel.lastCreatedPendingId) { _, newId in
      guard let newId else { return }
      primarySessionId = "pending-codex-\(newId.uuidString)"
      codexViewModel.lastCreatedPendingId = nil
    }
    .onChange(of: selectedSessionItems.map(\.id)) { _, _ in
      ensurePrimarySelection()
      if selectedSessionItems.isEmpty {
        setAuxiliaryShellVisible(false)
      }
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
      "Failed to Delete Worktree",
      isPresented: Binding(
        get: { claudeViewModel.worktreeDeletionError != nil || codexViewModel.worktreeDeletionError != nil },
        set: { if !$0 { claudeViewModel.clearWorktreeDeletionError(); codexViewModel.clearWorktreeDeletionError() } }
      )
    ) {
      let error = claudeViewModel.worktreeDeletionError ?? codexViewModel.worktreeDeletionError
      if let error, error.isOrphaned, let parentRepoPath = error.parentRepoPath {
        Button("Prune & Delete") {
          let isClaudeError = claudeViewModel.worktreeDeletionError != nil
          if isClaudeError {
            codexViewModel.clearWorktreeDeletionError()
            claudeViewModel.forceDeleteOrphanedWorktree(error.worktree, parentRepoPath: parentRepoPath)
          } else {
            claudeViewModel.clearWorktreeDeletionError()
            codexViewModel.forceDeleteOrphanedWorktree(error.worktree, parentRepoPath: parentRepoPath)
          }
        }
        Button("Cancel", role: .cancel) {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.clearWorktreeDeletionError()
        }
      } else if let error {
        Button("Force Delete", role: .destructive) {
          let isClaudeError = claudeViewModel.worktreeDeletionError != nil
          if isClaudeError {
            codexViewModel.clearWorktreeDeletionError()
            claudeViewModel.forceDeleteWorktree(error.worktree)
          } else {
            claudeViewModel.clearWorktreeDeletionError()
            codexViewModel.forceDeleteWorktree(error.worktree)
          }
        }
        Button("Cancel", role: .cancel) {
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
          Text("\(error.message)\n\n\"Force Delete\" will remove the worktree even if it contains untracked files.")
        }
      }
    }
    .alert("Delete Worktree?", isPresented: $showDeleteWorktreeAlert) {
      Button("Cancel", role: .cancel) {
        sessionToDeleteWorktree = nil
      }
      Button("Delete", role: .destructive) {
        if let session = sessionToDeleteWorktree {
          let providerKind = selectedSessionItems.first(where: { $0.session.id == session.id })?.providerKind
          Task {
            switch providerKind {
            case .claude:
              await claudeViewModel.deleteWorktreeForSession(session)
            case .codex:
              await codexViewModel.deleteWorktreeForSession(session)
            case .none:
              break
            }
          }
          sessionToDeleteWorktree = nil
        }
      }
    } message: {
      Text("You are about to delete this worktree. This cannot be recovered.")
    }
    .sheet(item: $createWorktreeContext) { context in
      CreateWorktreeSheet(
        repositoryPath: context.repository.path,
        repositoryName: context.repository.name,
        onDismiss: { createWorktreeContext = nil },
        onCreate: { branchName, directoryName, baseBranch, onProgress in
          let vm = viewModel(for: context.providerKind)
          try await vm.createWorktree(
            for: context.repository,
            branchName: branchName,
            directoryName: directoryName,
            baseBranch: baseBranch,
            onProgress: onProgress
          )
        }
      )
    }
  }

  // MARK: - UI Helpers

  private var keyboardShortcutButtons: some View {
    Group {
      Button("") { showCommandPalette = true }
        .keyboardShortcut("k", modifiers: .command)
        .hidden()

      Button("") { handleCommandPaletteAction(.newSession) }
        .keyboardShortcut("n", modifiers: .command)
        .hidden()

      Button("") { handleCommandPaletteAction(.toggleSidebar) }
        .keyboardShortcut("b", modifiers: .command)
        .hidden()

      Button("") { toggleAuxiliaryShellDock() }
        .keyboardShortcut("j", modifiers: .command)
        .hidden()

      Button("") { navigateSessionHistory(direction: .backward) }
        .keyboardShortcut("[", modifiers: .command)
        .hidden()

      Button("") { navigateSessionHistory(direction: .forward) }
        .keyboardShortcut("]", modifiers: .command)
        .hidden()

      Button("") { toggleFocusMode() }
        .keyboardShortcut("\\", modifiers: .command)
        .hidden()

      Button("") { terminalFontSize = min(terminalFontSize + 1, 24) }
        .keyboardShortcut("+", modifiers: .command)
        .hidden()

      Button("") { terminalFontSize = max(terminalFontSize - 1, 8) }
        .keyboardShortcut("-", modifiers: .command)
        .hidden()
    }
  }

  @ViewBuilder
  private var commandPaletteOverlay: some View {
    if showCommandPalette {
      CommandPaletteView(
        isPresented: $showCommandPalette,
        sessions: makeCommandPaletteSessions(),
        onAction: handleCommandPaletteAction
      )
    }
  }

  private var appBackground: some View {
    Group {
      if runtimeTheme?.hasCustomBackgrounds == true {
        Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
      } else {
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
    }
  }

  private var sessionListContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 1. Session Launcher (always visible)
      if let multiLaunchViewModel {
        MultiSessionLaunchView(
          viewModel: multiLaunchViewModel,
          intelligenceViewModel: intelligenceViewModel,
          expandRequestID: launchExpandRequestID
        )
        .padding(.bottom, 8)
      }

      // 2. Inline Selected Sessions (monitored + pending)
      inlineSelectedSessions

      // 3. Collapsible Browse Sessions section
      browseSectionView
    }
    .animation(.easeInOut(duration: 0.2), value: isSearchExpanded)
    .animation(.easeInOut(duration: 0.25), value: isBrowseExpanded)
    .animation(.easeInOut(duration: 0.22), value: selectedSessionItems.count)
    .onChange(of: currentViewModel.hasPerformedSearch) { oldValue, newValue in
      if oldValue && !newValue && isSearchExpanded {
        withAnimation(.easeInOut(duration: 0.25)) {
          isSearchExpanded = false
        }
      }
    }
  }

  private var sidePanelView: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        sessionListContent
          .padding(12)
      }
      .onChange(of: scrollToSessionId) { _, newId in
        guard let newId else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
          proxy.scrollTo(newId, anchor: .top)
        }
        scrollToSessionId = nil
      }
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
          .font(.secondaryDefault)
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
            .font(.secondaryCaption)
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
      .font(.secondaryDefault)
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
            .font(.secondaryLarge)
            .foregroundColor(.secondary)
          Text("Try a different search term")
            .font(.secondaryCaption)
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

  // MARK: - Inline Selected Sessions

  private struct SelectedSessionItem: Identifiable {
    let id: String
    let session: CLISession
    let providerKind: SessionProviderKind
    let timestamp: Date
    let isPending: Bool
    let sessionStatus: SessionStatus?
  }

  private var selectedSessionItems: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in claudeViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-claude-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .claude,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private func selectedSessionCustomName(for item: SelectedSessionItem) -> String? {
    switch item.providerKind {
    case .claude: return claudeViewModel.sessionCustomNames[item.session.id]
    case .codex: return codexViewModel.sessionCustomNames[item.session.id]
    }
  }

  // MARK: - Project Grouping

  private struct SessionGroup: Identifiable {
    let id: String            // repoPath
    let displayName: String
    let items: [SelectedSessionItem]
  }

  /// Deduplicated tracked repos from both providers, preserving insertion order,
  /// newest-first. Claude's repos are walked first, then Codex-only repos.
  private var orderedTrackedRepos: [SelectedRepository] {
    var seen: Set<String> = []
    var combined: [SelectedRepository] = []
    for repo in claudeViewModel.selectedRepositories {
      if seen.insert(repo.path).inserted { combined.append(repo) }
    }
    for repo in codexViewModel.selectedRepositories {
      if seen.insert(repo.path).inserted { combined.append(repo) }
    }
    // Newest-added first (reverse of insertion order).
    return combined.reversed()
  }

  /// Returns the parent repo path for an arbitrary session path — handles both
  /// "path is the repo root" and "path is a worktree under the repo". Falls back
  /// to the original path when no tracked repo matches (used for the orphan group).
  private func findParentRepoPath(for itemPath: String) -> String {
    for repo in orderedTrackedRepos {
      if repo.path == itemPath { return repo.path }
      if repo.worktrees.contains(where: { $0.path == itemPath }) {
        return repo.path
      }
    }
    return itemPath
  }

  /// Groups built from tracked repos first (even empty), then an orphan bucket
  /// for sessions whose path doesn't belong to any tracked repo.
  private var groupedSelectedSessions: [SessionGroup] {
    let allItems = selectedSessionItems
    var byRepo: [String: [SelectedSessionItem]] = [:]
    for item in allItems {
      let key = findParentRepoPath(for: item.session.projectPath)
      byRepo[key, default: []].append(item)
    }

    var groups: [SessionGroup] = []
    var handledKeys: Set<String> = []

    // Tracked repos — always emit a header, even if empty.
    for repo in orderedTrackedRepos {
      let items = (byRepo[repo.path] ?? []).sorted { $0.timestamp > $1.timestamp }
      groups.append(SessionGroup(
        id: repo.path,
        displayName: URL(fileURLWithPath: repo.path).lastPathComponent,
        items: items
      ))
      handledKeys.insert(repo.path)
    }

    // Orphan sessions (repo not tracked yet — e.g. a brand-new pending one).
    for (key, items) in byRepo where !handledKeys.contains(key) {
      groups.append(SessionGroup(
        id: key,
        displayName: URL(fileURLWithPath: key).lastPathComponent,
        items: items.sorted { $0.timestamp > $1.timestamp }
      ))
    }

    return groups
  }

  @ViewBuilder
  private var inlineSelectedSessions: some View {
    let groups = groupedSelectedSessions
    if !groups.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(groups) { group in
          let isExpanded = !collapsedProjectGroups.contains(group.id)

          ProjectGroupHeader(
            name: group.displayName,
            isExpanded: isExpanded
          ) {
            withAnimation(.easeInOut(duration: 0.25)) {
              if isExpanded {
                collapsedProjectGroups.insert(group.id)
              } else {
                collapsedProjectGroups.remove(group.id)
              }
            }
          }

          if isExpanded {
            ForEach(group.items) { item in
              CollapsibleSessionRow(
                session: item.session,
                providerKind: item.providerKind,
                timestamp: item.timestamp,
                isPending: item.isPending,
                isPrimary: item.id == primarySessionId,
                customName: selectedSessionCustomName(for: item),
                sessionStatus: item.sessionStatus,
                colorScheme: colorScheme,
                onArchive: item.isPending ? nil : {
                  withAnimation(.easeInOut(duration: 0.25)) {
                    switch item.providerKind {
                    case .claude: claudeViewModel.stopMonitoring(session: item.session)
                    case .codex: codexViewModel.stopMonitoring(session: item.session)
                    }
                  }
                },
                onDeleteWorktree: (!item.isPending && item.session.isWorktree) ? {
                  sessionToDeleteWorktree = item.session
                  showDeleteWorktreeAlert = true
                } : nil,
                isDeletingWorktree: item.session.isWorktree && {
                  switch item.providerKind {
                  case .claude: return claudeViewModel.deletingWorktreePath == item.session.projectPath
                  case .codex: return codexViewModel.deletingWorktreePath == item.session.projectPath
                  }
                }(),
                onSelect: {
                  primarySessionId = item.id
                }
              )
              .transition(.opacity)
              .id(item.id)
            }
          }
        }
      }
      .padding(.bottom, 8)
    }
  }

  // MARK: - Per-Provider Content

  @ViewBuilder
  private var selectedProviderContent: some View {
    let isClaudeSelected = selectedProvider == .claude
    let viewModel = isClaudeSelected ? claudeViewModel : codexViewModel
    let isInstalled = isClaudeSelected ? claudeInstalled : codexInstalled

    if !isInstalled {
      CLINotInstalledView(provider: selectedProvider)
    } else if !viewModel.selectedRepositories.isEmpty {
      ProviderSectionView(
        viewModel: viewModel,
        onRemoveRepository: { removeRepository($0, from: viewModel) },
        onOpenSessionFile: { session in
          openSessionFile(for: session, viewModel: viewModel)
        },
        onCreateWorktree: { repository in
          createWorktreeContext = WorktreeCreateContext(
            providerKind: viewModel.providerKind,
            repository: repository
          )
        }
      )
    }
  }

  // MARK: - Browse Section

  private var browseSectionView: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.25)) {
          isBrowseExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isBrowseExpanded ? 90 : 0))
            .font(.system(size: 10))
          Text("Browse all Sessions")
            .font(.heading)
          Spacer()
        }
        .padding(.vertical, 8)
      }
      .buttonStyle(.plain)

      if isBrowseExpanded {
        VStack(spacing: 6) {
          ProviderSegmentedControl(
            selectedProvider: Binding(
              get: { selectedProvider },
              set: { selectedProviderRaw = $0.rawValue }
            ),
            claudeSessionCount: claudeViewModel.totalSessionCount,
            codexSessionCount: codexViewModel.totalSessionCount
          )

          if hasCurrentProviderRepositories {
            statusHeader
          }

          CLIRepositoryPickerView(onAddRepository: showAddRepositoryPicker)

          if isSearchExpanded {
            expandedSearchBar
          } else {
            collapsedSearchButton
          }

          LazyVStack(spacing: 16) {
            selectedProviderContent
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  private var statusHeader: some View {
    VStack(spacing: 8) {
      if isLoading {
        HStack(spacing: 8) {
          ProgressView().scaleEffect(0.7)
          Text("Refreshing sessions...")
            .font(.secondaryCaption)
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
        Text("\(currentViewModel.selectedRepositories.count) \(currentViewModel.selectedRepositories.count == 1 ? "module" : "modules") · \(currentViewModel.allSessions.count) \(currentViewModel.allSessions.count == 1 ? "session" : "sessions")")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)

        Spacer()

        // Toggle first/last message
        Button(action: { toggleShowLastMessage() }) {
          HStack(spacing: 6) {
            Image(systemName: currentViewModel.showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text(currentViewModel.showLastMessage ? "Last" : "First")
              .font(.secondaryCaption)
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

  /// Uses asyncAfter to schedule NSOpenPanel creation on a future run loop iteration,
  /// avoiding HIRunLoopSemaphore deadlock that occurs during GCD dispatch queue drain.
  private func showAddRepositoryPicker() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      MainActor.assumeIsolated {
        let panel = NSOpenPanel()
        panel.title = "Select Repository"
        panel.message = "Choose a git repository to monitor CLI sessions"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
          self.addRepository(at: url.path)
        }
      }
    }
  }

  private func addRepository(at path: String) {
    claudeViewModel.addRepository(at: path)
    codexViewModel.addRepository(at: path)
  }

  private func removeRepository(_ repository: SelectedRepository, from viewModel: CLISessionsViewModel) {
    viewModel.removeRepository(repository)
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

  private var selectedProvider: SessionProviderKind {
    SessionProviderKind(rawValue: selectedProviderRaw) ?? .claude
  }

  private var currentViewModel: CLISessionsViewModel {
    selectedProvider == .claude ? claudeViewModel : codexViewModel
  }

  private var hasCurrentProviderRepositories: Bool {
    !currentViewModel.selectedRepositories.isEmpty
  }

  private func toggleShowLastMessage() {
    currentViewModel.showLastMessage.toggle()
  }

  private func handleResolvedSessions(
    _ resolutions: [UUID: String],
    provider: SessionProviderKind,
    viewModel: CLISessionsViewModel
  ) {
    guard let currentPrimary = primarySessionId else { return }
    let providerPrefix = "pending-\(provider.rawValue.lowercased())-"
    guard currentPrimary.hasPrefix(providerPrefix) else { return }
    let uuidString = String(currentPrimary.dropFirst(providerPrefix.count))
    guard let pendingUUID = UUID(uuidString: uuidString),
          let realSessionId = resolutions[pendingUUID] else { return }
    let newPrimaryId = "\(provider.rawValue.lowercased())-\(realSessionId)"
    AppLogger.session.info("[PrimarySelection] Resolved: \(currentPrimary.prefix(20), privacy: .public) -> \(newPrimaryId.prefix(20), privacy: .public)")
    primarySessionId = newPrimaryId
    viewModel.resolvedPendingSessions.removeValue(forKey: pendingUUID)
  }

  private func ensurePrimarySelection() {
    let items = selectedSessionItems
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }
    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }
    primarySessionId = items.first?.id
  }

  // MARK: - Computed

  private var claudeInstalled: Bool {
    CLIDetectionService.isClaudeInstalled()
  }

  private var codexInstalled: Bool {
    CLIDetectionService.isCodexInstalled()
  }

  private var hasRepositories: Bool {
    !allRepositories.isEmpty
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

  // MARK: - Keyboard Shortcuts

  private func makeCommandPaletteSessions() -> [CommandPaletteSession] {
    var result: [CommandPaletteSession] = []
    for item in selectedSessionItems {
      let name = selectedSessionCustomName(for: item) ?? item.session.slug ?? item.session.shortId
      result.append(
        CommandPaletteSession(
          id: item.id,
          name: name,
          provider: item.providerKind,
          firstMessage: item.session.firstMessage
        )
      )
    }
    return result
  }

  private func handleCommandPaletteAction(_ action: CommandPaletteAction) {
    switch action {
    case .newSession:
      triggerNewSessionFlow()

    case .switchToSession(let id, _, _, _):
      if let item = selectedSessionItems.first(where: { $0.id == id }) {
        primarySessionId = item.id
        scrollToSessionId = item.id
      }

    case .selectRepository:
      break

    case .openSettings:
      openSettings()

    case .toggleSidebar:
      sidebarVisibilityBeforeAutoHide = nil
      columnVisibility = columnVisibility == .all ? .detailOnly : .all

    case .toggleFocusMode:
      toggleFocusMode()
    }
  }

  private func handleEmbeddedSidePanelVisibilityChange(_ isVisible: Bool) {
    guard isEmbeddedTrailingPanelVisible != isVisible else { return }
    isEmbeddedTrailingPanelVisible = isVisible

    if isVisible {
      guard columnVisibility != .detailOnly else {
        sidebarVisibilityBeforeAutoHide = nil
        return
      }

      sidebarVisibilityBeforeAutoHide = columnVisibility
      withAnimation(.easeInOut(duration: 0.2)) {
        columnVisibility = .detailOnly
      }
      return
    }

    guard let previousVisibility = sidebarVisibilityBeforeAutoHide else { return }
    sidebarVisibilityBeforeAutoHide = nil

    guard columnVisibility == .detailOnly else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      columnVisibility = previousVisibility
    }
  }

  private func triggerNewSessionFlow(preferredRepositoryPath: String? = nil) {
    withAnimation(.easeInOut(duration: 0.2)) {
      isBrowseExpanded = true
    }
    launchExpandRequestID += 1

    guard let multiLaunchViewModel else { return }

    multiLaunchViewModel.reset()

    guard let preferredRepositoryPath else {
      multiLaunchViewModel.selectRepository()
      return
    }

    Task { @MainActor in
      let didPreselect = await multiLaunchViewModel.preselectRepository(path: preferredRepositoryPath)
      if !didPreselect {
        multiLaunchViewModel.selectRepository()
      }
    }
  }

  private func toggleFocusMode() {
    let singleRaw = 0
    if layoutModeRawValue != singleRaw {
      previousLayoutModeRawValue = layoutModeRawValue
      withAnimation(.easeInOut(duration: 0.2)) {
        layoutModeRawValue = singleRaw
      }
    } else if previousLayoutModeRawValue >= 0 {
      let restoreTo = previousLayoutModeRawValue
      previousLayoutModeRawValue = -1
      withAnimation(.easeInOut(duration: 0.2)) {
        layoutModeRawValue = restoreTo
      }
    }
  }

  private func toggleAuxiliaryShellDock() {
    ensurePrimarySelection()
    guard !selectedSessionItems.isEmpty else { return }
    withAnimation(auxiliaryShellToggleAnimation) {
      isAuxiliaryShellVisible.toggle()
    }
  }

  private func setAuxiliaryShellVisible(_ isVisible: Bool) {
    guard isAuxiliaryShellVisible != isVisible else { return }
    withAnimation(auxiliaryShellToggleAnimation) {
      isAuxiliaryShellVisible = isVisible
    }
  }

  private var auxiliaryShellToggleAnimation: Animation {
    accessibilityReduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9)
  }

  private enum NavigationDirection {
    case forward, backward
  }

  private func navigateSessionHistory(direction: NavigationDirection) {
    let items = selectedSessionItems
    guard !items.isEmpty else { return }

    if let currentId = primarySessionId,
       let currentIndex = items.firstIndex(where: { $0.id == currentId }) {
      let newIndex: Int
      switch direction {
      case .forward:
        newIndex = min(currentIndex + 1, items.count - 1)
      case .backward:
        newIndex = max(currentIndex - 1, 0)
      }
      primarySessionId = items[newIndex].id
      scrollToSessionId = items[newIndex].id
    } else {
      primarySessionId = items.first?.id
      scrollToSessionId = items.first?.id
    }
  }
}

// MARK: - ProjectGroupHeader

private struct ProjectGroupHeader: View {
  let name: String
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 8) {
        Image(systemName: isExpanded ? "folder.fill" : "folder")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
          .contentTransition(.symbolEffect(.replace))
        Text(name)
          .font(.secondaryDefault)
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - ProviderSectionView

private struct ProviderSectionView: View {
  @Bindable var viewModel: CLISessionsViewModel
  let onRemoveRepository: (SelectedRepository) -> Void
  let onOpenSessionFile: (CLISession) -> Void
  var onCreateWorktree: ((SelectedRepository) -> Void)? = nil

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
          onDeleteWorktree: { worktree in
            Task { await viewModel.deleteWorktree(worktree) }
          },
          getCustomName: { sessionId in
            viewModel.sessionCustomNames[sessionId]
          },
          onCreateWorktree: onCreateWorktree != nil ? { repository in
            onCreateWorktree?(repository)
          } : nil,
          onStartInHubForWorktree: { worktree in
            viewModel.startNewSessionInHub(worktree)
          },
          onStartInHubDangerousForWorktree: { worktree in
            viewModel.startNewSessionInHub(worktree, dangerouslySkipPermissions: true)
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
            .font(.primaryDefault)
        }

        Spacer()

        Text(session.shortId)
          .font(.primaryCaption)
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.primaryCaption)
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
