//
//  MultiProviderSessionsListView.swift
//  AgentHub
//
//  Shows Claude and Codex sections side-by-side in the left panel.
//

import AppKit
import AgentHubGitHub
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

// MARK: - GitHubSheetItem

private struct GitHubSheetItem: Identifiable {
  let id = UUID()
  let projectPath: String
}

// MARK: - ArchiveConfirmation

private struct ArchiveConfirmation {
  let repoName: String
  let count: Int
  let action: () -> Void
}

// MARK: - RemoveConfirmation

private struct RemoveConfirmation {
  let title: String
  let message: String
  let action: () -> Void
}

// MARK: - WorktreeModuleDeleteConfirmation

private struct WorktreeModuleDeleteConfirmation {
  let worktree: WorktreeBranch
  let displayName: String
  let sessionCount: Int
  let providerKind: SessionProviderKind
}

// MARK: - ArchiveConfirmationAlert

private struct ArchiveConfirmationAlert: ViewModifier {
  @Binding var confirmation: ArchiveConfirmation?

  func body(content: Content) -> some View {
    content.alert(
      confirmation.map { "Archive \($0.count) sessions?" } ?? "",
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmation = nil }
      Button("Archive all", role: .destructive) {
        confirmation?.action()
        confirmation = nil
      }
    } message: {
      if let confirmation {
        Text("This will archive the threads in \(confirmation.repoName). You can find them later in your archived threads.")
      }
    }
  }
}

// MARK: - RemoveConfirmationAlert

private struct RemoveConfirmationAlert: ViewModifier {
  @Binding var confirmation: RemoveConfirmation?

  func body(content: Content) -> some View {
    content.alert(
      confirmation?.title ?? "",
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmation = nil }
      Button("Remove", role: .destructive) {
        confirmation?.action()
        confirmation = nil
      }
    } message: {
      if let confirmation {
        Text(confirmation.message)
      }
    }
  }
}

private extension StatusGroupCategory {
  var color: Color {
    switch self {
    case .needsAttention: return .yellow
    case .working: return .blue
    case .ready: return .green
    case .idle: return .gray
    }
  }
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
  @State private var sidebarGroupMode: SidebarGroupMode = .repo
  @State private var collapsedStatusGroups: Set<StatusGroupCategory> = []
  @State private var isPinnedSectionCollapsed: Bool = false
  @State private var scrollToSessionId: String?
  @State private var launchExpandRequestID = 0
  @State private var createWorktreeContext: WorktreeCreateContext?
  @State private var gitHubSheetItem: GitHubSheetItem?
  @State private var archiveConfirmation: ArchiveConfirmation?
  @State private var removeConfirmation: RemoveConfirmation?
  @State private var worktreeModuleDeleteConfirmation: WorktreeModuleDeleteConfirmation?
  @State private var selectedModuleLandingPath: String?
  @State private var pendingAddedModulePaths: [String] = []
  @State private var isStartSessionSheetPresented = false
  @State private var isRefreshingGitHubStates = false
  @State private var didScheduleInitialGitHubStateRefresh = false

  // TODO: Remove along with MultiSessionLaunchView once the new Threads-based
  // session-start flow is fully implemented. Flip to `true` to restore the
  // legacy launcher during iteration.
  private let showLegacyLauncher = false

  @AppStorage(AgentHubDefaults.auxiliaryShellVisible) private var isAuxiliaryShellVisible = false
  @AppStorage(AgentHubDefaults.worktreeDisplayMode)
  private var worktreeDisplayModeRawValue: String = WorktreeDisplayMode.parent.rawValue
  @State private var isEmbeddedTrailingPanelVisible = false
  @State private var sidebarVisibilityBeforeAutoHide: NavigationSplitViewVisibility?
  @FocusState private var isSearchFieldFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

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
    GeometryReader { proxy in
      let sidebarMax = max(280, proxy.size.width * 0.20)
    ZStack {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        sidePanelView
          .agentHubPanel()
          .navigationSplitViewColumnWidth(min: 280, ideal: 280, max: sidebarMax)
          .padding(.vertical, 8)
          .padding(.horizontal, 8)
      } detail: {
        VStack(spacing: 0) {
          // Progress bar lives above the detail pane only (not over the sidebar).
          WorktreeGenerationProgressBar()

          MultiProviderMonitoringPanelView(
            claudeViewModel: claudeViewModel,
            codexViewModel: codexViewModel,
            primarySessionId: $primarySessionId,
            selectedModuleLandingPath: $selectedModuleLandingPath,
            onEmbeddedSidePanelVisibilityChange: handleEmbeddedSidePanelVisibilityChange,
            onAddFolder: { showAddRepositoryPicker() },
            onRequestStartSession: { preferredRepositoryPath in
              triggerNewSessionFlow(preferredRepositoryPath: preferredRepositoryPath)
            },
            onRequestForkSession: { session, targetProvider in
              triggerForkSessionFlow(session: session, targetProvider: targetProvider)
            }
          )
          .padding(12)
          .agentHubPanel()
          .frame(minWidth: 300)
          .padding(.vertical, 8)
          .padding(.horizontal, 8)
          .background {
            NSSplitViewAutosaveDisabler()
              .frame(width: 0, height: 0)
              .allowsHitTesting(false)
          }
        }
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
      scheduleInitialGitHubStateRefreshIfNeeded()
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
      syncModuleLandingSelection()
      ensurePrimarySelection()
      if selectedSessionItems.isEmpty {
        setAuxiliaryShellVisible(false)
      }
      scheduleInitialGitHubStateRefreshIfNeeded()
    }
    .onChange(of: orderedTrackedRepos.map(\.path)) { _, _ in
      syncPendingModuleRows()
      syncModuleLandingSelection()
      ensurePrimarySelection()
    }
    .onChange(of: sidebarGroupMode) { _, newMode in
      guard newMode != .repo else { return }
      selectedModuleLandingPath = nil
      ensurePrimarySelection()
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
    .alert(
      "Delete Worktree?",
      isPresented: Binding(
        get: { worktreeModuleDeleteConfirmation != nil },
        set: { if !$0 { worktreeModuleDeleteConfirmation = nil } }
      ),
      presenting: worktreeModuleDeleteConfirmation
    ) { confirmation in
      Button("Cancel", role: .cancel) {
        worktreeModuleDeleteConfirmation = nil
      }
      Button("Delete", role: .destructive) {
        deleteWorktreeModule(confirmation)
      }
    } message: { confirmation in
      if confirmation.sessionCount > 0 {
        let threadLabel = confirmation.sessionCount == 1 ? "thread" : "threads"
        Text(
          "This will archive \(confirmation.sessionCount) \(threadLabel) "
            + "and delete \(confirmation.displayName) at:\n"
            + "\(confirmation.worktree.path)\n\n"
            + "This cannot be undone."
        )
      } else {
        Text(
          """
          Delete \(confirmation.displayName) at:
          \(confirmation.worktree.path)

          This cannot be undone.
          """
        )
      }
    }
    .sheet(item: $createWorktreeContext) { context in
      CreateWorktreeSheet(
        repositoryPath: context.repository.path,
        repositoryName: context.repository.name,
        onDismiss: { createWorktreeContext = nil },
        onCreate: { branchName, directoryName, baseBranch in
          beginSidePanelWorktree(
            context: context,
            branchName: branchName,
            directoryName: directoryName,
            baseBranch: baseBranch
          )
        }
      )
    }
    .sheet(item: $gitHubSheetItem) { item in
      let provider = claudeViewModel.agentHubProvider ?? codexViewModel.agentHubProvider
      GitHubPanelView(
        projectPath: item.projectPath,
        onDismiss: { gitHubSheetItem = nil },
        isEmbedded: false,
        viewModel: GitHubViewModel(
          service: provider?.gitHubService ?? GitHubCLIService(),
          observationService: provider?.gitHubPRObservationService
        ),
        onSendToSession: { prompt, session in
          claudeViewModel.showTerminalWithPrompt(for: session, prompt: prompt)
        },
        onStartNewSession: { inputText, provider in
          let projectPath = item.projectPath
          let vm = provider == .claude ? claudeViewModel : codexViewModel
          let repo = vm.selectedRepositories.first(where: { $0.path == projectPath })
            ?? claudeViewModel.selectedRepositories.first(where: { $0.path == projectPath })
            ?? codexViewModel.selectedRepositories.first(where: { $0.path == projectPath })
          if let worktree = repo?.worktrees.first {
            gitHubSheetItem = nil
            vm.startNewSessionInHub(worktree, initialInputText: inputText)
          }
        }
      )
    }
    .sheet(isPresented: $isStartSessionSheetPresented) {
      if let multiLaunchViewModel {
        StartSessionSheet(
          launchViewModel: multiLaunchViewModel,
          intelligenceViewModel: intelligenceViewModel,
          onDismiss: { isStartSessionSheetPresented = false }
        )
      }
    }
    .modifier(ArchiveConfirmationAlert(confirmation: $archiveConfirmation))
    .modifier(RemoveConfirmationAlert(confirmation: $removeConfirmation))
    }
  }

  // MARK: - UI Helpers

  private var keyboardShortcutButtons: some View {
    Group {
      Button("") { showCommandPalette = true }
        .keyboardShortcut("k", modifiers: .command)
        .hidden()

      Button("") { triggerFocusedNewSessionFlow() }
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
      // 1. Session Launcher (legacy — hidden behind flag during Threads redesign)
      if showLegacyLauncher, let multiLaunchViewModel {
        MultiSessionLaunchView(
          viewModel: multiLaunchViewModel,
          intelligenceViewModel: intelligenceViewModel,
          expandRequestID: launchExpandRequestID
        )
        .padding(.bottom, 8)
      }

      // 2. Threads (Inline Selected Sessions — monitored + pending)
      inlineSelectedSessions
    }
    .animation(.easeInOut(duration: 0.2), value: isSearchExpanded)
    .animation(.easeInOut(duration: 0.22), value: selectedSessionItems.count)
    .onChange(of: currentViewModel.hasPerformedSearch) { oldValue, newValue in
      if oldValue && !newValue && isSearchExpanded {
        withAnimation(.easeInOut(duration: 0.25)) {
          isSearchExpanded = false
        }
      }
    }
  }

  private var browseAnimation: Animation {
    accessibilityReduceMotion
      ? .easeInOut(duration: 0.15)
      : .spring(response: 0.35, dampingFraction: 0.88)
  }

  private var sidePanelView: some View {
    VStack(spacing: 0) {
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

      // Browse panel slides up from bottom with fixed max height
      if isBrowseExpanded {
        browsePanel
          .transition(
            accessibilityReduceMotion
              ? .opacity
              : .move(edge: .bottom).combined(with: .opacity)
          )
      } else {
        browseHeaderView
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .overlay(alignment: .top) {
            Divider()
          }
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(browseAnimation, value: isBrowseExpanded)
  }

  private var browsePanel: some View {
    VStack(spacing: 0) {
      browseHeaderView
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(height: 3)
        }

      ScrollView(showsIndicators: false) {
        browseExpandedContent
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
      }
    }
    .frame(maxHeight: 420)
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
    let linkedPullRequestNumber: Int?
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
        sessionStatus: nil,
        linkedPullRequestNumber: nil
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil,
        linkedPullRequestNumber: nil
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status,
        linkedPullRequestNumber: Self.latestPullRequestNumber(in: item.state?.detectedResourceLinks ?? [])
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status,
        linkedPullRequestNumber: Self.latestPullRequestNumber(in: item.state?.detectedResourceLinks ?? [])
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

  /// Deduplicated tracked repos from both providers, preserving insertion order,
  /// newest-first. Claude's repos are walked first, then Codex-only repos.
  private var orderedTrackedRepos: [SelectedRepository] {
    let combined = WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )
    // Newest-added first (reverse of insertion order).
    return combined.reversed()
  }

  private var worktreeDisplayMode: WorktreeDisplayMode {
    WorktreeDisplayMode(rawValue: worktreeDisplayModeRawValue) ?? .parent
  }

  private var pinnedSessionSnapshot: ProviderScopedPinnedSessions {
    ProviderScopedPinnedSessions(
      claudeSessionIds: claudeViewModel.pinnedSessionIds,
      codexSessionIds: codexViewModel.pinnedSessionIds
    )
  }

  private func isPinned(_ item: SelectedSessionItem) -> Bool {
    pinnedSessionSnapshot.contains(
      sessionId: item.session.id,
      providerKind: item.providerKind
    )
  }

  private var pinnedSessionItems: [SelectedSessionItem] {
    SidebarSessionOrdering.pinnedItems(
      from: selectedSessionItems,
      isPinned: isPinned,
      timestamp: { $0.timestamp },
      id: { $0.id }
    )
  }

  /// Groups built from tracked repos first (even empty), then an orphan bucket
  /// for sessions whose path doesn't belong to any tracked repo.
  private var groupedSelectedSessions: [SidebarSessionGroup<SelectedSessionItem>] {
    SidebarSessionOrdering.moduleGroups(
      from: selectedSessionItems,
      repositories: Array(orderedTrackedRepos),
      worktreeDisplayMode: worktreeDisplayMode,
      isPinned: isPinned,
      projectPath: { $0.session.projectPath },
      timestamp: { $0.timestamp },
      id: { $0.id }
    )
  }

  private func worktreeModule(for modulePath: String) -> WorktreeBranch? {
    WorktreeModuleResolver.worktreeModule(
      for: modulePath,
      repositories: Array(orderedTrackedRepos),
      mode: worktreeDisplayMode
    )
  }

  private func removeAction(
    for group: SidebarSessionGroup<SelectedSessionItem>,
    worktreeModule: WorktreeBranch?,
    worktreeSessionCount: Int
  ) -> (() -> Void)? {
    if let worktreeModule {
      return {
        removeConfirmation = RemoveConfirmation(
          title: "Remove \(group.displayName) from AgentHub?",
          message: worktreeRemovalMessage(
            name: group.displayName,
            sessionCount: worktreeSessionCount
          )
        ) {
          removeWorktreeModuleFocus(worktreeModule)
        }
      }
    }

    guard isTrackedRepositoryModule(group.id) else { return nil }
    return {
      removeConfirmation = RemoveConfirmation(
        title: "Remove \(group.displayName)?",
        message: repositoryRemovalMessage(name: group.displayName, sessionCount: group.items.count)
      ) {
        if selectedModuleLandingPath == group.id {
          selectedModuleLandingPath = nil
        }
        if let repo = selectedRepository(in: claudeViewModel.selectedRepositories, matching: group.id) {
          claudeViewModel.removeRepository(repo)
        }
        if let repo = selectedRepository(in: codexViewModel.selectedRepositories, matching: group.id) {
          codexViewModel.removeRepository(repo)
        }
      }
    }
  }

  private func repositoryRemovalMessage(name: String, sessionCount: Int) -> String {
    if sessionCount > 0 {
      let threadLabel = sessionCount == 1 ? "thread" : "threads"
      return "This will archive \(sessionCount) active \(threadLabel) "
        + "and remove \(name) from your list."
    }
    return "This will remove \(name) from your list."
  }

  private func worktreeRemovalMessage(name: String, sessionCount: Int) -> String {
    if sessionCount > 0 {
      let threadLabel = sessionCount == 1 ? "thread" : "threads"
      return "This will archive \(sessionCount) focused \(threadLabel) "
        + "and stop focusing \(name) in AgentHub. The worktree stays on disk."
    }
    return "This will stop focusing \(name) in AgentHub. The worktree stays on disk."
  }

  private func isTrackedRepositoryModule(_ modulePath: String) -> Bool {
    selectedRepository(in: orderedTrackedRepos, matching: modulePath) != nil
  }

  private func selectedRepository(
    in repositories: [SelectedRepository],
    matching path: String
  ) -> SelectedRepository? {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    return repositories.first {
      WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalizedPath
    }
  }

  private func providerKindForWorktreeModule(
    _ worktree: WorktreeBranch,
    items: [SelectedSessionItem]
  ) -> SessionProviderKind {
    if let item = items.first(where: { !$0.isPending }) ?? items.first {
      return item.providerKind
    }
    if repositories(claudeViewModel.selectedRepositories, containWorktreePath: worktree.path) {
      return .claude
    }
    if repositories(codexViewModel.selectedRepositories, containWorktreePath: worktree.path) {
      return .codex
    }
    return .claude
  }

  private func repositories(
    _ repositories: [SelectedRepository],
    containWorktreePath path: String
  ) -> Bool {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    return repositories.contains { repository in
      repository.worktrees.contains { worktree in
        worktree.isWorktree && WorktreeModuleResolver.normalizedDirectoryPath(worktree.path) == normalizedPath
      }
    }
  }

  private func focusedSessionCount(inWorktreePath worktreePath: String) -> Int {
    selectedSessionItems.filter { item in
      !item.isPending && isProjectPath(item.session.projectPath, containedIn: worktreePath)
    }.count
  }

  private func isProjectPath(_ path: String, containedIn root: String) -> Bool {
    let path = WorktreeModuleResolver.normalizedDirectoryPath(path)
    let root = WorktreeModuleResolver.normalizedDirectoryPath(root)
    return path == root || path.hasPrefix(root + "/")
  }

  private func removeWorktreeModuleFocus(_ worktree: WorktreeBranch) {
    let path = WorktreeModuleResolver.normalizedDirectoryPath(worktree.path)
    if selectedModuleLandingPath == path {
      selectedModuleLandingPath = nil
    }
    claudeViewModel.removeFocusedWorktree(at: path)
    codexViewModel.removeFocusedWorktree(at: path)
  }

  private func deleteWorktreeModule(_ confirmation: WorktreeModuleDeleteConfirmation) {
    worktreeModuleDeleteConfirmation = nil
    Task { @MainActor in
      let viewModel = confirmation.providerKind == .claude ? claudeViewModel : codexViewModel
      let succeeded = await viewModel.deleteWorktree(confirmation.worktree)
      if succeeded {
        removeWorktreeModuleFocus(confirmation.worktree)
      }
    }
  }

  /// Sessions grouped by status category (Working / Needs Attention / Idle).
  private var statusGroupedSessions: [StatusGroupCategory: [SelectedSessionItem]] {
    SidebarSessionOrdering.statusGroups(
      from: selectedSessionItems,
      isPinned: isPinned,
      status: { $0.sessionStatus },
      timestamp: { $0.timestamp },
      id: { $0.id }
    )
  }

  private var navigableSessionItems: [SelectedSessionItem] {
    SidebarSessionOrdering.flattenedItems(
      from: selectedSessionItems,
      repositories: Array(orderedTrackedRepos),
      groupMode: sidebarGroupMode,
      worktreeDisplayMode: worktreeDisplayMode,
      collapsedProjectGroups: collapsedProjectGroups,
      collapsedStatusGroups: collapsedStatusGroups,
      isPinnedSectionCollapsed: isPinnedSectionCollapsed,
      isPinned: isPinned,
      projectPath: { $0.session.projectPath },
      status: { $0.sessionStatus },
      timestamp: { $0.timestamp },
      id: { $0.id }
    )
  }

  @ViewBuilder
  private var inlineSelectedSessions: some View {
    VStack(alignment: .leading, spacing: 0) {
      SessionsSectionHeader(
        groupMode: $sidebarGroupMode,
        repos: orderedTrackedRepos,
        launchViewModel: multiLaunchViewModel,
        intelligenceViewModel: intelligenceViewModel,
        isRefreshingGitHubStates: isRefreshingGitHubStates,
        canRefreshGitHubStates: canRefreshGitHubStates,
        onRefreshGitHubStates: refreshGitHubStates,
        onAddFolder: { showAddRepositoryPicker() }
      )

      let pendingModules = pendingModulePaths
      if !pendingModules.isEmpty {
        ForEach(pendingModules, id: \.self) { path in
          PendingModuleRow(
            name: moduleDisplayName(for: path),
            isSelected: selectedModuleLandingPath == path
          )
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }

      // Pinned sessions section
      let pinned = pinnedSessionItems
      if !pinned.isEmpty {
        PinnedSectionHeader(
          count: pinned.count,
          isExpanded: !isPinnedSectionCollapsed,
          onToggle: {
            withAnimation(.easeInOut(duration: 0.25)) {
              isPinnedSectionCollapsed.toggle()
            }
          }
        )
        .transition(.opacity)

        if !isPinnedSectionCollapsed {
          sessionRows(for: pinned)
        }
      }

      switch sidebarGroupMode {
      case .repo:
        let groups = groupedSelectedSessions
        if !groups.isEmpty {
          ForEach(groups) { group in
            let isExpanded = !collapsedProjectGroups.contains(group.id)
            let worktreeModule = worktreeModule(for: group.id)
            let worktreeSessionCount = worktreeModule.map {
              focusedSessionCount(inWorktreePath: $0.path)
            } ?? 0

            ProjectGroupHeader(
              name: group.displayName,
              isExpanded: isExpanded,
              canToggle: !group.items.isEmpty,
              isSelected: selectedModuleLandingPath == group.id && group.items.isEmpty,
              onToggle: {
                withAnimation(.easeInOut(duration: 0.25)) {
                  if isExpanded {
                    collapsedProjectGroups.insert(group.id)
                  } else {
                    collapsedProjectGroups.remove(group.id)
                  }
                }
              },
              onSelectEmptyModule: {
                selectEmptyModule(group.id)
              },
              repoPath: group.id,
              onStartSession: {
                triggerNewSessionFlow(preferredRepositoryPath: group.id)
              },
              onOpenInFinder: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.id)
              },
              onOpenGitHub: {
                gitHubSheetItem = GitHubSheetItem(projectPath: group.id)
              },
              onArchiveSessions: group.items.isEmpty ? nil : {
                let items = group.items
                archiveConfirmation = ArchiveConfirmation(
                  repoName: group.displayName,
                  count: items.count
                ) {
                  withAnimation(.easeInOut(duration: 0.25)) {
                    for item in items where !item.isPending {
                      switch item.providerKind {
                      case .claude: claudeViewModel.stopMonitoring(session: item.session)
                      case .codex: codexViewModel.stopMonitoring(session: item.session)
                      }
                    }
                  }
                }
              },
              removeTitle: worktreeModule == nil ? "Remove" : "Remove from AgentHub",
              onRemove: removeAction(
                for: group,
                worktreeModule: worktreeModule,
                worktreeSessionCount: worktreeSessionCount
              ),
              onDeleteWorktree: worktreeModule.map { worktree in
                {
                  worktreeModuleDeleteConfirmation = WorktreeModuleDeleteConfirmation(
                    worktree: worktree,
                    displayName: group.displayName,
                    sessionCount: worktreeSessionCount,
                    providerKind: providerKindForWorktreeModule(worktree, items: group.items)
                  )
                }
              }
            )

            if isExpanded {
              sessionRows(for: group.items)
            }
          }
        }

      case .status:
        let grouped = statusGroupedSessions
        ForEach(StatusGroupCategory.allCases) { category in
          let items = grouped[category] ?? []
          if !items.isEmpty {
            let isExpanded = !collapsedStatusGroups.contains(category)

            StatusGroupSectionHeader(
              category: category,
              count: items.count,
              isExpanded: isExpanded,
              onToggle: {
                withAnimation(.easeInOut(duration: 0.25)) {
                  if isExpanded {
                    collapsedStatusGroups.insert(category)
                  } else {
                    collapsedStatusGroups.remove(category)
                  }
                }
              }
            )

            if isExpanded {
              sessionRows(for: items)
            }
          }
        }
      }
    }
    .padding(.bottom, 8)
  }

  // MARK: - Per-Provider Content

  @ViewBuilder
  private func sessionRows(for items: [SelectedSessionItem]) -> some View {
    VStack(spacing: 2) {
      ForEach(items) { item in
        CollapsibleSessionRow(
          session: item.session,
          providerKind: item.providerKind,
          timestamp: item.timestamp,
          isPending: item.isPending,
          isPrimary: item.id == primarySessionId,
          customName: selectedSessionCustomName(for: item),
          sessionStatus: item.sessionStatus,
          linkedPullRequestNumber: item.linkedPullRequestNumber,
          colorScheme: colorScheme,
          isPinned: isPinned(item),
          onPin: item.isPending ? nil : {
            withAnimation(.easeInOut(duration: 0.3)) {
              switch item.providerKind {
              case .claude: claudeViewModel.togglePin(for: item.session)
              case .codex: codexViewModel.togglePin(for: item.session)
              }
            }
          },
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
            selectedModuleLandingPath = nil
            primarySessionId = item.id
          }
        )
        .transition(.opacity)
        .id(item.id)
      }
    }
    .padding(.top, 2)
    .animation(.easeInOut(duration: 0.25), value: pinnedSessionSnapshot)
  }

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
        repositories: viewModel.selectedRepositories,
        onOpenSessionFile: { session in
          openSessionFile(for: session, viewModel: viewModel)
        }
      )
    }
  }

  // MARK: - Browse Section

  @State private var showBrowseInfo = false

  /// Browse header — pinned at bottom when collapsed, at top of browse panel when expanded.
  private var browseHeaderView: some View {
    HStack(spacing: 8) {
      Button {
        toggleBrowseExpanded()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isBrowseExpanded ? "chevron.down" : "chevron.up")
            .font(.system(size: DesignTokens.IconSize.sm, weight: .semibold))
            .frame(width: 12, height: 12)
            .contentTransition(.symbolEffect(.replace))
          Text("Browse all Sessions")
            .font(.heading)
        }
      }
      .buttonStyle(.plain)

      Spacer()

      Button {
        showBrowseInfo.toggle()
      } label: {
        Image(systemName: "info.circle")
          .font(.system(size: DesignTokens.IconSize.sm))
          .foregroundColor(.secondary)
          .frame(width: 12, height: 12)
      }
      .buttonStyle(.plain)
      .help("About Browse all Sessions")
      .popover(isPresented: $showBrowseInfo, arrowEdge: isBrowseExpanded ? .bottom : .top) {
        Text("Find all local Claude and Codex sessions started from the terminal and bring them into AgentHub.")
          .font(.callout)
          .foregroundColor(.secondary)
          .padding(12)
          .frame(width: 240)
      }
    }
  }

  private func toggleBrowseExpanded() {
    let willExpand = !isBrowseExpanded
    withAnimation(browseAnimation) {
      isBrowseExpanded = willExpand
    }

    if willExpand {
      claudeViewModel.ensureBrowseSessionsLoaded()
      codexViewModel.ensureBrowseSessionsLoaded()
    }
  }

  /// Expandable content shown inside the scroll view when browse is expanded.
  private var browseExpandedContent: some View {
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

      switch currentViewModel.browseSessionsLoadState {
      case .loading, .notLoaded:
        browseLoadingView

      case .failed(let message):
        browseErrorView(message: message)

      case .loaded:
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

  private var browseLoadingView: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.7)
      Text("Loading sessions...")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  private func browseErrorView(message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: DesignTokens.IconSize.sm))
        .foregroundColor(.orange)
      Text(message)
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
        .lineLimit(2)
      Spacer()
      Button("Retry") {
        currentViewModel.refreshBrowseSessions()
      }
      .buttonStyle(.borderless)
      .font(.secondaryCaption)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  private var statusHeader: some View {
    VStack(spacing: 8) {
      if currentViewModel.browseSessionsLoadState.isLoading {
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
        let moduleCount = displayModuleCount(for: currentViewModel)
        Text("\(moduleCount) \(moduleCount == 1 ? "module" : "modules") · \(currentViewModel.allSessions.count) \(currentViewModel.allSessions.count == 1 ? "session" : "sessions")")
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
        Button(action: { currentViewModel.refreshBrowseSessions() }) {
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
        .disabled(currentViewModel.browseSessionsLoadState.isLoading)
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
    sidebarGroupMode = .repo
    trackPendingModule(path)
    claudeViewModel.addRepository(at: path)
    codexViewModel.addRepository(at: path)
    selectEmptyModule(path)
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

  /// Hands a side-panel worktree creation to the app-wide progress coordinator
  /// (which owns the work and surfaces it in the top bar) so the sheet can
  /// dismiss immediately. Falls back to a direct, untracked creation if no
  /// coordinator is available (e.g. previews).
  private func beginSidePanelWorktree(
    context: WorktreeCreateContext,
    branchName: String,
    directoryName: String,
    baseBranch: String?
  ) {
    let vm = viewModel(for: context.providerKind)
    let repo = context.repository
    let providerKind = context.providerKind
    if let coordinator = vm.agentHubProvider?.worktreeGenerationProgressCoordinator {
      coordinator.beginSidePanelOperation(
        branchName: branchName,
        repoName: repo.name,
        providerKind: providerKind
      ) { onProgress in
        try await vm.createWorktree(
          for: repo,
          branchName: branchName,
          directoryName: directoryName,
          baseBranch: baseBranch,
          onProgress: onProgress
        )
      }
    } else {
      Task {
        try? await vm.createWorktree(
          for: repo,
          branchName: branchName,
          directoryName: directoryName,
          baseBranch: baseBranch,
          onProgress: { _ in }
        )
      }
    }
  }

  private var selectedProvider: SessionProviderKind {
    SessionProviderKind(rawValue: selectedProviderRaw) ?? .claude
  }

  private var currentViewModel: CLISessionsViewModel {
    selectedProvider == .claude ? claudeViewModel : codexViewModel
  }

  private var gitHubPRObservationService: (any GitHubPRObservationServiceProtocol)? {
    claudeViewModel.agentHubProvider?.gitHubPRObservationService
      ?? codexViewModel.agentHubProvider?.gitHubPRObservationService
  }

  private static func latestPullRequestNumber(in links: [ResourceLink]) -> Int? {
    GitHubPullRequestURLReference.latestNumber(in: links.map(\.url))
  }

  private var gitHubRefreshTargets: [GitHubPRObservationTarget] {
    var seen = Set<GitHubPRObservationTarget>()
    var targets: [GitHubPRObservationTarget] = []

    for item in selectedSessionItems where !item.isPending {
      let target = GitHubPRObservationTarget.currentBranch(
        projectPath: item.session.projectPath,
        branchName: item.session.branchName
      )
      guard seen.insert(target).inserted else { continue }
      targets.append(target)
    }

    return targets
  }

  private var canRefreshGitHubStates: Bool {
    gitHubPRObservationService != nil && !gitHubRefreshTargets.isEmpty
  }

  private var hasCurrentProviderRepositories: Bool {
    !currentViewModel.selectedRepositories.isEmpty
  }

  private func toggleShowLastMessage() {
    currentViewModel.showLastMessage.toggle()
  }

  private func refreshGitHubStates() {
    scheduleGitHubStateRefresh(limit: nil, showsIndicator: true)
  }

  private func scheduleInitialGitHubStateRefreshIfNeeded() {
    guard !didScheduleInitialGitHubStateRefresh,
          canRefreshGitHubStates else {
      return
    }

    didScheduleInitialGitHubStateRefresh = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      scheduleGitHubStateRefresh(limit: 12, showsIndicator: false)
    }
  }

  private func scheduleGitHubStateRefresh(limit: Int?, showsIndicator: Bool) {
    guard !isRefreshingGitHubStates,
          let observationService = gitHubPRObservationService else {
      return
    }

    let targets = Array(gitHubRefreshTargets.prefix(limit ?? Int.max))
    guard !targets.isEmpty else { return }

    isRefreshingGitHubStates = true
    Task { @MainActor in
      for target in targets {
        await observationService.refresh(target)
        try? await Task.sleep(for: .milliseconds(120))
      }
      if !showsIndicator {
        isRefreshingGitHubStates = false
        return
      }
      try? await Task.sleep(for: .milliseconds(350))
      isRefreshingGitHubStates = false
    }
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
    guard selectedModuleLandingPath == nil else {
      primarySessionId = nil
      return
    }

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

  private func selectEmptyModule(_ path: String) {
    selectedModuleLandingPath = path
    primarySessionId = nil
    setAuxiliaryShellVisible(false)
  }

  private func syncModuleLandingSelection() {
    if let selectedModuleLandingPath,
       pendingModulePaths.contains(selectedModuleLandingPath) {
      return
    }

    let activePath = ModuleLandingSelection.activeModulePath(
      selectedPath: selectedModuleLandingPath,
      repositories: orderedTrackedRepos,
      itemProjectPaths: selectedSessionItems.map { $0.session.projectPath },
      mode: worktreeDisplayMode
    )

    if activePath == nil {
      selectedModuleLandingPath = nil
    }
  }

  private func trackPendingModule(_ path: String) {
    guard !orderedTrackedRepos.contains(where: { $0.path == path }),
          !pendingAddedModulePaths.contains(path) else {
      return
    }
    pendingAddedModulePaths.insert(path, at: 0)
  }

  private func syncPendingModuleRows() {
    let trackedPaths = Set(orderedTrackedRepos.map(\.path))
    pendingAddedModulePaths.removeAll { trackedPaths.contains($0) }
  }

  private var pendingModulePaths: [String] {
    let trackedPaths = Set(orderedTrackedRepos.map(\.path))
    var seen: Set<String> = []
    return pendingAddedModulePaths.filter { path in
      !trackedPaths.contains(path) && seen.insert(path).inserted
    }
  }

  private func moduleDisplayName(for path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
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
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    ).sorted { $0.path < $1.path }
  }

  private var totalSessionCount: Int {
    claudeViewModel.totalSessionCount + codexViewModel.totalSessionCount
  }

  private func displayModuleCount(for viewModel: CLISessionsViewModel) -> Int {
    WorktreeModuleResolver.modulePaths(
      for: viewModel.selectedRepositories,
      mode: worktreeDisplayMode
    ).count
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
      triggerFocusedNewSessionFlow()

    case .switchToSession(let id, _, _, _):
      if let item = selectedSessionItems.first(where: { $0.id == id }) {
        selectedModuleLandingPath = nil
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

    case .toggleTerminalEditor:
      NotificationCenter.default.post(name: .toggleMonitoringContentMode, object: nil)
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
      columnVisibility = .detailOnly
      return
    }

    guard let previousVisibility = sidebarVisibilityBeforeAutoHide else { return }
    sidebarVisibilityBeforeAutoHide = nil

    guard columnVisibility == .detailOnly else { return }
    columnVisibility = previousVisibility
  }

  private var focusedSessionLaunchPath: String? {
    FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: primarySessionId,
      selectedModuleLandingPath: selectedModuleLandingPath,
      items: selectedSessionItems.map {
        FocusedSessionLaunchTargetResolver.SessionItem(
          id: $0.id,
          projectPath: $0.session.projectPath
        )
      },
      repositories: orderedTrackedRepos
    )
  }

  private func triggerFocusedNewSessionFlow() {
    guard let focusedSessionLaunchPath else { return }
    triggerNewSessionFlow(
      preferredRepositoryPath: focusedSessionLaunchPath,
      fallsBackToRepositoryPicker: false
    )
  }

  private func triggerNewSessionFlow(
    preferredRepositoryPath: String? = nil,
    fallsBackToRepositoryPicker: Bool = true
  ) {
    guard let multiLaunchViewModel else { return }
    multiLaunchViewModel.reset()

    guard let preferredRepositoryPath else {
      isStartSessionSheetPresented = true
      multiLaunchViewModel.selectRepository()
      return
    }

    Task { @MainActor in
      let didPreselect = await multiLaunchViewModel.preselectRepository(path: preferredRepositoryPath)
      if didPreselect {
        isStartSessionSheetPresented = true
      } else if fallsBackToRepositoryPicker {
        isStartSessionSheetPresented = true
        multiLaunchViewModel.selectRepository()
      }
    }
  }

  private func triggerForkSessionFlow(session: CLISession, targetProvider: SessionProviderKind) {
    guard let multiLaunchViewModel else { return }

    Task { @MainActor in
      let didConfigure = await multiLaunchViewModel.configureForFork(
        from: session,
        targetProvider: targetProvider
      )
      if didConfigure {
        isStartSessionSheetPresented = true
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

  private func navigateSessionHistory(direction: SidebarSessionNavigationDirection) {
    let orderedIDs = navigableSessionItems.map(\.id)
    guard let nextID = SidebarSessionOrdering.nextID(
      in: orderedIDs,
      currentID: primarySessionId,
      direction: direction
    ) else {
      return
    }

    selectedModuleLandingPath = nil
    primarySessionId = nextID
    scrollToSessionId = nextID
  }
}

// MARK: - PendingModuleRow

private struct PendingModuleRow: View {
  let name: String
  let isSelected: Bool

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.65)
        .frame(width: 13, height: 13)

      Text(name)
        .font(Font.geist(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected
              ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.12 : 0.1)
              : Color.clear)
    )
    .padding(.top, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Adding \(name)")
  }
}

// MARK: - ProjectGroupHeader

private struct ProjectGroupHeader: View {
  let name: String
  let isExpanded: Bool
  let canToggle: Bool
  let isSelected: Bool
  let onToggle: () -> Void
  let onSelectEmptyModule: () -> Void
  let repoPath: String
  let onStartSession: () -> Void
  let onOpenInFinder: () -> Void
  let onOpenGitHub: () -> Void
  let onArchiveSessions: (() -> Void)?
  let removeTitle: String
  let onRemove: (() -> Void)?
  let onDeleteWorktree: (() -> Void)?

  @State private var isHovered: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 4) {
      Button(action: { canToggle ? onToggle() : onSelectEmptyModule() }) {
        HStack(spacing: 8) {
          Image(systemName: isSelected || (canToggle && isExpanded) ? "folder.fill" : "folder")
            .font(.system(size: 13))
            .foregroundColor(.primary)
            .contentTransition(.symbolEffect(.replace))
          Text(name)
            .font(Font.geist(size: 13, weight: .semibold))
            .foregroundColor(.primary)
          if canToggle {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(.secondary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .animation(.easeInOut(duration: 0.15), value: isExpanded)
              .opacity(isHovered ? 1 : 0)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(canToggle ? "Expand or collapse sessions" : "Show module landing page")

      HeaderIconMenu(systemName: "ellipsis", size: 14, help: "More actions") {
        Button(action: onOpenInFinder) {
          Label("Open in Finder", systemImage: "folder")
        }
        Button(action: onOpenGitHub) {
          Label("GitHub", systemImage: "arrow.triangle.pull")
        }
        if onArchiveSessions != nil || onRemove != nil || onDeleteWorktree != nil {
          Divider()
          if let onArchiveSessions {
            Button(action: onArchiveSessions) {
              Label("Archive Sessions", systemImage: "archivebox")
            }
          }
          if let onRemove {
            Button(action: onRemove) {
              Label(removeTitle, systemImage: "xmark")
            }
          }
          if let onDeleteWorktree {
            Button(role: .destructive, action: onDeleteWorktree) {
              Label("Delete Worktree", systemImage: "trash")
            }
          }
        }
      }
      .opacity(isHovered ? 1 : 0)

      HeaderIconButton(
        systemName: "square.and.pencil",
        size: 14,
        help: "Start a new session"
      ) { onStartSession() }
      .opacity(isHovered ? 1 : 0)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected || isHovered
              ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.12 : 0.1)
              : Color.clear)
    )
    .padding(.top, 2)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
  }
}

// MARK: - PinnedSectionHeader

private struct PinnedSectionHeader: View {
  let count: Int
  let isExpanded: Bool
  let onToggle: () -> Void

  @State private var isHovered: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 6) {
        Image(systemName: "pin.fill")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
        Text("Pinned")
          .font(Font.geist(size: 13, weight: .semibold))
          .foregroundColor(.primary)
        Text("\(count)")
          .font(Font.geist(size: 11, weight: .regular))
          .foregroundColor(.secondary)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(.easeInOut(duration: 0.15), value: isExpanded)
          .padding(.trailing, 4)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovered
              ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.12 : 0.1)
              : Color.clear)
    )
    .padding(.top, 2)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
  }
}

// MARK: - StatusGroupSectionHeader

private struct StatusGroupSectionHeader: View {
  let category: StatusGroupCategory
  let count: Int
  let isExpanded: Bool
  let onToggle: () -> Void

  @State private var isHovered: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 8) {
        Circle()
          .fill(category.color)
          .frame(width: 10, height: 10)
        Text(category.rawValue)
          .font(Font.geist(size: 13, weight: .semibold))
          .foregroundColor(.primary)
        Text("\(count)")
          .font(Font.geist(size: 11, weight: .regular))
          .foregroundColor(.secondary)
        Spacer(minLength: 0)
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary)
          .padding(.trailing, 4)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovered
              ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.12 : 0.1)
              : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
  }
}

// MARK: - StartSessionSheet

/// Sheet wrapper that renders `MultiSessionLaunchView` in compact style for the
/// project-row pencil entry point. Auto-dismisses when the launch pipeline
/// finishes (unless the user cancelled or is in an interactive smart-mode phase).
private struct StartSessionSheet: View {
  @Bindable var launchViewModel: MultiSessionLaunchViewModel
  let intelligenceViewModel: IntelligenceViewModel?
  let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(launchViewModel.carrySourceChangesPath == nil ? "Start Session" : "Fork Session")
          .font(.heading)
        Spacer()
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Close")
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 10)

      Divider()

      MultiSessionLaunchView(
        viewModel: launchViewModel,
        intelligenceViewModel: intelligenceViewModel,
        expandRequestID: 0,
        style: .compact
      )
      .padding(16)
    }
    .frame(minWidth: 480, idealWidth: 520)
    .background(colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
    .onChange(of: launchViewModel.isLaunching) { wasLaunching, isLaunching in
      if !wasLaunching, isLaunching {
        // Launch started: manual launches hand progress off to the top bar and
        // close immediately. Smart (interactive) launches stay open to review
        // the orchestration plan.
        if !launchViewModel.isSmartInteractive {
          onDismiss()
        }
      } else if wasLaunching, !isLaunching {
        // Launch finished: dismiss flows that stayed open (e.g. smart), unless
        // still interactive or ended by cancellation.
        if launchViewModel.isSmartInteractive { return }
        if launchViewModel.lastLaunchEndedByCancellation { return }
        onDismiss()
      }
    }
  }
}

// MARK: - SessionsSectionHeader

private struct SessionsSectionHeader: View {
  @Binding var groupMode: SidebarGroupMode
  let repos: [SelectedRepository]
  let launchViewModel: MultiSessionLaunchViewModel?
  let intelligenceViewModel: IntelligenceViewModel?
  let isRefreshingGitHubStates: Bool
  let canRefreshGitHubStates: Bool
  let onRefreshGitHubStates: () -> Void
  let onAddFolder: () -> Void

  @State private var showGroupPopover = false
  @State private var showStartSheet = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 2) {
        Text("Sessions")
          .font(.heading)
          .foregroundColor(.secondary)

        Spacer()

        HeaderIconButton(
          systemName: "line.3.horizontal.decrease",
          help: "Group sessions"
        ) {
          showGroupPopover.toggle()
        }
        .popover(isPresented: $showGroupPopover, arrowEdge: .bottom) {
          GroupByPopover(groupMode: $groupMode)
        }

        HeaderIconButton(
          systemName: isRefreshingGitHubStates ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
          help: "Refresh GitHub PR and CI states",
          isDisabled: !canRefreshGitHubStates || isRefreshingGitHubStates,
          action: onRefreshGitHubStates
        )

        HeaderIconButton(
          systemName: "folder.badge.plus",
          help: "Add a folder as a new module",
          action: onAddFolder
        )

        if groupMode == .status {
          HeaderIconMenu(
            systemName: "plus",
            help: "Start a new session"
          ) {
            ForEach(repos, id: \.path) { repo in
              Button {
                guard let vm = launchViewModel else { return }
                Task { @MainActor in
                  vm.reset()
                  _ = await vm.preselectRepository(path: repo.path)
                  showStartSheet = true
                }
              } label: {
                Label(
                  URL(fileURLWithPath: repo.path).lastPathComponent,
                  systemImage: "folder"
                )
              }
            }
          }
          .sheet(isPresented: $showStartSheet) {
            if let vm = launchViewModel {
              StartSessionSheet(
                launchViewModel: vm,
                intelligenceViewModel: intelligenceViewModel,
                onDismiss: { showStartSheet = false }
              )
            }
          }
        }
      }
      .padding(.vertical, 4)
      .padding(.leading, 4)

      Divider()
    }
  }
}

// MARK: - GroupByPopover

private struct GroupByPopover: View {
  @Binding var groupMode: SidebarGroupMode

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Group by")
          .font(Font.geist(size: 13, weight: .medium))
          .foregroundColor(.secondary)
        Spacer(minLength: 16)
        Picker("", selection: $groupMode) {
          ForEach(SidebarGroupMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
    }
    .padding(12)
    .frame(minWidth: 200)
  }
}

// MARK: - Header icon primitives

/// Shared styling for small icon buttons/menus used in sidebar section headers.
/// Keeps the hit area generous (28×28) while the glyph size is tunable so
/// in-row controls can be visually smaller without losing tap area.
private extension View {
  func headerIconStyle(size: CGFloat = DesignTokens.IconSize.sm) -> some View {
    self
      .font(.system(size: size))
      .foregroundColor(.secondary)
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
  }
}

/// Small icon button with an enlarged square hit area, used in sidebar section headers.
private struct HeaderIconButton: View {
  let systemName: String
  var size: CGFloat = DesignTokens.IconSize.sm
  var help: String? = nil
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .headerIconStyle(size: size)
        .opacity(isDisabled ? 0.35 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(help ?? "")
  }
}

/// Icon-only Menu with the same styling as HeaderIconButton.
private struct HeaderIconMenu<Content: View>: View {
  let systemName: String
  var size: CGFloat = DesignTokens.IconSize.sm
  var help: String? = nil
  @ViewBuilder let content: () -> Content

  var body: some View {
    Menu {
      content()
    } label: {
      Image(systemName: systemName).headerIconStyle(size: size)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(help ?? "")
  }
}

// MARK: - ProviderSectionView

private struct ProviderSectionView: View {
  @Bindable var viewModel: CLISessionsViewModel
  let repositories: [SelectedRepository]
  let onOpenSessionFile: (CLISession) -> Void

  var body: some View {
    VStack(spacing: 12) {
      ForEach(repositories) { repository in
        CLIRepositoryTreeView(
          repository: repository,
          providerKind: viewModel.providerKind,
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
