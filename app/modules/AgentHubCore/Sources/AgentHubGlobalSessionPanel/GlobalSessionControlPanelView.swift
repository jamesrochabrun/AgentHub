//
//  GlobalSessionControlPanelView.swift
//  AgentHub
//

import Foundation
import SwiftUI
import AgentHubCore
import AgentHubGitHub

// MARK: - GlobalSessionControlPanelView

private struct GlobalSessionCleanupDeletionConfirmation: Identifiable {
  let id = UUID()
  let suggestions: [GlobalSessionCleanupSuggestion]

  var message: String {
    suggestions.map { suggestion in
      let pullRequestText = suggestion.mergedPullRequestNumbers
        .map { "#\($0)" }
        .joined(separator: ", ")
      return "- \(suggestion.worktreeName) (merged PR \(pullRequestText))\n  \(suggestion.worktreePath)"
    }
    .joined(separator: "\n")
  }
}

private struct GlobalSessionCleanupDeletionFailure: Identifiable, Equatable {
  let id = UUID()
  let suggestion: GlobalSessionCleanupSuggestion
  let message: String
}

private struct GlobalSessionCleanupDeletionResult: Identifiable {
  let id = UUID()
  let deleted: [GlobalSessionCleanupSuggestion]
  let failures: [GlobalSessionCleanupDeletionFailure]

  var title: String {
    failures.isEmpty ? "Deleted Suggested Worktrees" : "Deleted Some Worktrees"
  }

  var message: String {
    var lines: [String] = []
    lines.append("\(deleted.count) deleted.")
    if !failures.isEmpty {
      lines.append("\(failures.count) failed:")
      lines.append(contentsOf: failures.map { "- \($0.suggestion.worktreeName): \($0.message)" })
    }
    return lines.joined(separator: "\n")
  }
}

public struct GlobalSessionControlPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  let selectionRouter: GlobalSessionSelectionRouter
  let onClose: () -> Void
  let onSelectSession: () -> Void
  let onDisplayModeChange: (GlobalSessionControlPanelDisplayMode) -> Void
  let onCompactContentHeightChange: (CGFloat) -> Void
  private let defaults: UserDefaults
  private let displayModeToggleRelay: GlobalSessionPanelDisplayModeToggleRelay?

  @State private var gitHubStates: [String: GlobalSessionControlPanelGitHubState] = [:]
  @State private var selectedItemID: String?
  @State private var displayMode: GlobalSessionControlPanelDisplayMode
  @State private var deletionConfirmation: GlobalSessionCleanupDeletionConfirmation?
  @State private var deletionResult: GlobalSessionCleanupDeletionResult?
  @State private var isDeletingSuggestedWorktrees = false
  @FocusState private var isPanelFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    selectionRouter: GlobalSessionSelectionRouter,
    displayModeToggleRelay: GlobalSessionPanelDisplayModeToggleRelay? = nil,
    defaults: UserDefaults = .standard,
    onClose: @escaping () -> Void = {},
    onSelectSession: @escaping () -> Void = {},
    onDisplayModeChange: @escaping (GlobalSessionControlPanelDisplayMode) -> Void = { _ in },
    onCompactContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
    self.displayModeToggleRelay = displayModeToggleRelay
    self.defaults = defaults
    self.onClose = onClose
    self.onSelectSession = onSelectSession
    self.onDisplayModeChange = onDisplayModeChange
    self.onCompactContentHeightChange = onCompactContentHeightChange
    _displayMode = State(initialValue: GlobalSessionControlPanelDisplayMode.load(from: defaults))
  }

  public var body: some View {
    ZStack(alignment: .top) {
      switch displayMode {
      case .regular:
        regularPanelContent
          .transition(.opacity)
      case .compact:
        compactPanelContent
          .background(
            GeometryReader { proxy in
              // Report the compact layout's intrinsic height so the AppKit
              // window can hug it instead of using a fixed (too-tall) size.
              Color.clear
                .onChange(of: proxy.size.height, initial: true) { _, height in
                  onCompactContentHeightChange(height)
                }
            }
          )
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(panelBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 1)
    )
    .focusable()
    .focusEffectDisabled()
    .focused($isPanelFocused)
    .onKeyPress(.downArrow) { moveSelection(.down) }
    .onKeyPress(.upArrow) { moveSelection(.up) }
    .onKeyPress(.return) { activateSelectedItem() }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    .alert(item: $deletionConfirmation, content: deletionConfirmationAlert)
    .alert(item: $deletionResult, content: deletionResultAlert)
    .onAppear {
      revalidateSelection()
      isPanelFocused = true
    }
    .onChange(of: selectionItemIDs) { _, _ in
      revalidateSelection()
    }
    .onChange(of: displayMode) { _, _ in
      revalidateSelection()
    }
    .onChange(of: displayModeToggleRelay?.toggleRequestCount) { _, _ in
      toggleDisplayMode()
    }
  }

  // The window snaps to its new size in the AppKit presenter (no per-frame
  // relayout, no alpha blink); here we only cross-fade the content between
  // layouts so the swap reads as a clean dissolve rather than a flash.
  private var displayModeCrossfadeAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.18)
  }

  private var regularPanelContent: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .opacity(0.5)

      panelContent
    }
  }

  private var panelContent: some View {
    primarySessionsContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var compactPanelContent: some View {
    // Even 8pt inset on all sides (matching the regular list) with a small,
    // balanced gap to the control bar — keeps the featured row's vertical
    // padding symmetric instead of jammed against the top.
    VStack(spacing: 6) {
      compactFeaturedContent
      compactControlBar
    }
    .padding(8)
  }

  @ViewBuilder
  private var compactFeaturedContent: some View {
    if let compactFeaturedItem {
      // Show the full row content (including the worktree/root path lines) so the
      // featured session in compact mode matches a regular-mode row exactly.
      GlobalSessionControlPanelRow(
        item: compactFeaturedItem,
        isSelected: compactFeaturedItem.id == selectedItemID,
        isCleanupCandidate: cleanupCandidateIDs.contains(compactFeaturedItem.id),
        onSelect: { activate(compactFeaturedItem) },
        onGitHubStateChange: { state in
          updateGitHubState(state, for: compactFeaturedItem.id)
        }
      )
    } else {
      compactEmptyState
    }
  }

  private var compactControlBar: some View {
    ZStack {
      Button(action: expandPanel) {
        Label("Expand Sessions", systemImage: "chevron.down")
          .labelStyle(.iconOnly)
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Expand")

      HStack {
        Spacer()

        Button(action: onClose) {
          Label("Close", systemImage: "xmark")
            .labelStyle(.iconOnly)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
      }
    }
  }

  @ViewBuilder
  private var primarySessionsContent: some View {
    if items.isEmpty {
      emptyState
    } else {
      sessionList
    }
  }

  private var sessionList: some View {
    let suggestions = cleanupSuggestions
    let candidateIDs = Set(suggestions.flatMap(\.sessionIDs))
    return ScrollViewReader { proxy in
      ScrollView(showsIndicators: true) {
        LazyVStack(spacing: 4) {
          if !suggestions.isEmpty {
            GlobalSessionCleanupBanner(
              suggestions: suggestions,
              isDeleting: isDeletingSuggestedWorktrees,
              onDelete: {
                deletionConfirmation = GlobalSessionCleanupDeletionConfirmation(
                  suggestions: suggestions
                )
              }
            )
            .padding(.bottom, 4)
          }

          ForEach(items) { item in
            GlobalSessionControlPanelRow(
              item: item,
              isSelected: item.id == selectedItemID,
              isCleanupCandidate: candidateIDs.contains(item.id),
              onSelect: { activate(item) },
              onGitHubStateChange: { state in
                updateGitHubState(state, for: item.id)
              }
            )
            .id(item.id)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
      .onChange(of: selectedItemID) { _, newValue in
        guard displayMode == .regular else { return }
        guard let newValue else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
          proxy.scrollTo(newValue)
        }
      }
    }
  }

  private var items: [GlobalSessionControlPanelItem] {
    GlobalSessionControlPanelSnapshotBuilder.makeItems(
      claudePending: claudeViewModel.pendingHubSessions,
      codexPending: codexViewModel.pendingHubSessions,
      claudeMonitored: claudeViewModel.monitoredSessions,
      codexMonitored: codexViewModel.monitoredSessions,
      claudeCustomNames: claudeViewModel.sessionCustomNames,
      codexCustomNames: codexViewModel.sessionCustomNames,
      gitHubStates: gitHubStates
    )
  }

  private var compactFeaturedItem: GlobalSessionControlPanelItem? {
    GlobalSessionControlPanelCompactItemSelector.featuredItem(from: items)
  }

  private var selectionItems: [GlobalSessionControlPanelItem] {
    switch displayMode {
    case .regular:
      return items
    case .compact:
      return compactFeaturedItem.map { [$0] } ?? []
    }
  }

  private var selectionItemIDs: [String] {
    selectionItems.map(\.id)
  }

  private var cleanupSuggestions: [GlobalSessionCleanupSuggestion] {
    GlobalSessionCleanupSuggestionBuilder.makeSuggestions(
      items: items,
      repositories: cleanupRepositories
    )
  }

  private var cleanupRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )
  }

  // Item IDs whose worktree is a safe-to-delete cleanup candidate (merged PR and
  // quiet state). Used to flag individual rows, consistent with the banner.
  private var cleanupCandidateIDs: Set<String> {
    Set(cleanupSuggestions.flatMap(\.sessionIDs))
  }

  private var panelBackground: some View {
    Group {
      if runtimeTheme?.hasCustomBackgrounds == true {
        Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
          .opacity(colorScheme == .dark ? 0.96 : 0.98)
      } else {
        Color(colorScheme == .dark ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor)
          .opacity(0.98)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.stack")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.brandPrimary(from: runtimeTheme))
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text("Sessions")
          .font(.heading)
          .foregroundStyle(.primary)

        Text("\(items.count) monitored")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(GlobalHotKey.sessionControlPanelDefault.displayString)
        .font(.primaryCaption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

      Button(action: compactPanel) {
        Label("Compact Sessions", systemImage: "chevron.up")
          .labelStyle(.iconOnly)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Compact")

      Button(action: onClose) {
        Label("Close", systemImage: "xmark")
          .labelStyle(.iconOnly)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }

  private var compactEmptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "terminal")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text("No monitored sessions")
          .font(.secondaryDefault)
          .foregroundStyle(.primary)

        Text("Start or select sessions in AgentHub.")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "terminal")
        .font(.system(size: 30, weight: .regular))
        .foregroundStyle(.secondary)

      Text("No monitored sessions")
        .font(.secondaryLarge)
        .foregroundStyle(.primary)

      Text("Start or select sessions in AgentHub to show them here.")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 260)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func updateGitHubState(_ state: GlobalSessionControlPanelGitHubState?, for itemID: String) {
    if let state {
      gitHubStates[itemID] = state
    } else {
      gitHubStates.removeValue(forKey: itemID)
    }
  }

  private func compactPanel() {
    setDisplayMode(.compact)
  }

  private func expandPanel() {
    setDisplayMode(.regular)
  }

  private func setDisplayMode(_ mode: GlobalSessionControlPanelDisplayMode) {
    guard displayMode != mode else { return }
    mode.persist(to: defaults)

    // Snap the window to its new size immediately (the presenter resizes without
    // animating the frame), then cross-fade the content for a clean dissolve.
    onDisplayModeChange(mode)
    withAnimation(displayModeCrossfadeAnimation) {
      displayMode = mode
    }
  }

  private func toggleDisplayMode() {
    setDisplayMode(displayMode == .regular ? .compact : .regular)
  }

  private func moveSelection(_ direction: GlobalSessionListNavigationDirection) -> KeyPress.Result {
    guard !selectionItemIDs.isEmpty else { return .ignored }
    selectedItemID = GlobalSessionPanelNavigator.nextSelection(
      currentID: selectedItemID,
      direction: direction,
      itemIDs: selectionItemIDs
    )
    return .handled
  }

  private func activateSelectedItem() -> KeyPress.Result {
    guard
      let selectedItemID,
      let item = selectionItems.first(where: { $0.id == selectedItemID })
    else { return .ignored }
    activate(item)
    return .handled
  }

  private func activate(_ item: GlobalSessionControlPanelItem) {
    selectedItemID = item.id
    selectionRouter.select(
      providerKind: item.providerKind,
      sessionId: item.session.id,
      projectPath: item.session.projectPath,
      itemId: item.id
    )
    onSelectSession()
  }

  private func revalidateSelection() {
    selectedItemID = GlobalSessionPanelNavigator.validatedSelection(
      currentID: selectedItemID,
      itemIDs: selectionItemIDs
    )
  }

  private func deletionConfirmationAlert(_ confirmation: GlobalSessionCleanupDeletionConfirmation) -> Alert {
    Alert(
      title: Text("Delete Suggested Worktrees?"),
      message: Text(confirmation.message),
      primaryButton: .destructive(Text("Delete Worktrees")) {
        Task {
          await deleteSuggestedWorktrees(confirmation.suggestions)
        }
      },
      secondaryButton: .cancel()
    )
  }

  private func deletionResultAlert(_ result: GlobalSessionCleanupDeletionResult) -> Alert {
    Alert(
      title: Text(result.title),
      message: Text(result.message),
      dismissButton: .default(Text("OK"))
    )
  }

  private func deleteSuggestedWorktrees(_ suggestions: [GlobalSessionCleanupSuggestion]) async {
    guard !isDeletingSuggestedWorktrees else { return }
    isDeletingSuggestedWorktrees = true

    var deleted: [GlobalSessionCleanupSuggestion] = []
    var failures: [GlobalSessionCleanupDeletionFailure] = []

    for suggestion in suggestions {
      let viewModel = deletionViewModel(for: suggestion)
      let worktree = matchingWorktree(at: suggestion.worktreePath)
        ?? WorktreeBranch(
          name: suggestion.worktreeName,
          path: suggestion.worktreePath,
          isWorktree: true
        )
      let succeeded = await viewModel.deleteWorktree(worktree, force: false)

      if succeeded {
        deleted.append(suggestion)
        removeFromSidebars(worktreePath: suggestion.worktreePath)
      } else {
        failures.append(GlobalSessionCleanupDeletionFailure(
          suggestion: suggestion,
          message: viewModel.worktreeDeletionError?.message
            ?? "The worktree could not be deleted."
        ))
        viewModel.clearWorktreeDeletionError()
      }
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
    isDeletingSuggestedWorktrees = false
    deletionResult = GlobalSessionCleanupDeletionResult(deleted: deleted, failures: failures)
  }

  private func deletionViewModel(for suggestion: GlobalSessionCleanupSuggestion) -> CLISessionsViewModel {
    if containsWorktree(at: suggestion.worktreePath, in: claudeViewModel) {
      return claudeViewModel
    }
    if containsWorktree(at: suggestion.worktreePath, in: codexViewModel) {
      return codexViewModel
    }
    if suggestion.providerKinds.contains(.codex), !suggestion.providerKinds.contains(.claude) {
      return codexViewModel
    }
    return claudeViewModel
  }

  private func matchingWorktree(at path: String) -> WorktreeBranch? {
    for viewModel in [claudeViewModel, codexViewModel] {
      for repository in viewModel.selectedRepositories {
        if let worktree = repository.worktrees.first(where: {
          WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
        }) {
          return worktree
        }
      }
    }
    return nil
  }

  private func containsWorktree(at path: String, in viewModel: CLISessionsViewModel) -> Bool {
    viewModel.selectedRepositories.contains { repository in
      repository.worktrees.contains {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
      }
    }
  }

  private func removeFromSidebars(worktreePath: String) {
    for viewModel in [claudeViewModel, codexViewModel] {
      viewModel.archiveMonitoredSessions(inWorktreePath: worktreePath)
      viewModel.forgetOwnedWorktreePath(worktreePath)
    }
  }
}

// MARK: - GlobalSessionControlPanelRow

private struct GlobalSessionCleanupBanner: View {
  let suggestions: [GlobalSessionCleanupSuggestion]
  let isDeleting: Bool
  let onDelete: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "flag.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.secondaryDefault)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text(summary)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 8)

      Button(action: onDelete) {
        Label(isDeleting ? "Deleting" : "Delete Suggested", systemImage: "trash")
          .font(.secondarySmall)
          .foregroundStyle(.white)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Color.red.opacity(isDeleting ? 0.55 : 0.86))
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(isDeleting)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(colorScheme == .dark ? 0.28 : 0.22), lineWidth: 1)
    )
  }

  private var title: String {
    let noun = suggestions.count == 1 ? "worktree" : "worktrees"
    return "\(suggestions.count) merged \(noun) can be deleted"
  }

  private var summary: String {
    let names = suggestions.prefix(2).map(\.worktreeName)
    let remaining = suggestions.count - names.count
    if remaining > 0 {
      return names.joined(separator: ", ") + " +\(remaining) more"
    }
    return names.joined(separator: ", ")
  }
}

private struct GlobalSessionControlPanelRow: View {
  let item: GlobalSessionControlPanelItem
  let isSelected: Bool
  var showsPathLines = true
  var isCleanupCandidate = false
  let onSelect: () -> Void
  let onGitHubStateChange: (GlobalSessionControlPanelGitHubState?) -> Void

  @State private var isHovered = false
  @State private var gitHubViewModel = SessionGitHubQuickAccessViewModel()
  @State private var resolvedRootPath: String?
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme

  private var gitHubObservationTaskID: String {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: item.session.projectPath,
      branchName: item.session.branchName,
      linkedPullRequests: item.linkedPullRequests
    )
    return "\(item.id)|\(repositoryKey)|\(item.isPending)|\(agentHub != nil)"
  }

  private var gitHubSignature: String {
    let pullRequest = gitHubViewModel.currentBranchPR
    let prNumber = pullRequest?.number ?? 0
    let summary = gitHubViewModel.ciSummary
    return [
      "\(prNumber)",
      pullRequest?.state ?? "",
      pullRequest?.mergeable ?? "",
      pullRequest?.reviewDecision ?? "",
      "\(summary.overallStatus.rawValue)",
      "\(summary.passed)",
      "\(summary.failed)",
      "\(summary.pending)",
      "\(summary.total)",
      gitHubViewModel.blockers.map(\.rawValue).sorted().map(String.init).joined(separator: ","),
      "\(gitHubViewModel.observationState.isUnavailable)",
      "\(gitHubViewModel.observationState.isRefreshing)"
    ].joined(separator: "|")
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        statusIndicator
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: 5) {
          topLine
          detailLine
          gitHubLine
          if showsPathLines {
            pathLines
          }
        }

        Spacer(minLength: 8)

        Image(systemName: "arrow.up.forward")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered || isSelected ? 0.9 : 0.45))
          .padding(.top, 3)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
      .background(rowBackground)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
    .task(id: gitHubObservationTaskID) {
      await observeGitHubIfAvailable()
      publishGitHubState()
    }
    .task(id: item.session.projectPath) {
      await resolveRootPath()
    }
    .onDisappear {
      gitHubViewModel.stopPolling()
      onGitHubStateChange(nil)
    }
    .onChange(of: item.timestamp) { _, newValue in
      Task {
        await gitHubViewModel.notifySessionActivity(at: newValue)
      }
    }
    .onChange(of: gitHubSignature) { _, _ in
      publishGitHubState()
    }
  }

  private var topLine: some View {
    HStack(spacing: 6) {
      Text(item.displayName)
        .font(.primaryDefault)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(item.providerKind.rawValue)
        .font(.secondaryCaption)
        .foregroundStyle(Color.brandPrimary(for: item.providerKind))
        .fixedSize(horizontal: true, vertical: false)

      if isCleanupCandidate {
        cleanupBadge
      }

      Spacer(minLength: 4)

      Text(item.timestamp.timeAgoDisplay())
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var cleanupBadge: some View {
    Text("Cleanup")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.orange, in: Capsule())
      .fixedSize()
      .help("This worktree's PR is merged — safe to clean up")
  }

  private var detailLine: some View {
    HStack(spacing: 6) {
      Text(statusText)
        .font(.secondarySmall)
        .foregroundStyle(statusColor)
        .lineLimit(1)
        .truncationMode(.tail)

      Text("·")
        .font(.secondaryCaption)
        .foregroundStyle(.secondary.opacity(0.7))

      Text(projectText)
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var gitHubLine: some View {
    if let pullRequest = gitHubViewModel.currentBranchPR {
      HStack(spacing: 5) {
        Image(systemName: gitHubStatusIcon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(ciColor)
          .frame(width: 12, height: 12)

        Text("PR #\(pullRequest.number)")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)

        if pullRequest.stateKind == .merged {
          prStateBadge("Merged", color: .purple)
        } else if pullRequest.stateKind == .closed {
          prStateBadge("Closed", color: .red)
        }

        Text("·")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary.opacity(0.7))

        Text(ciText)
          .font(.secondaryCaption)
          .foregroundStyle(ciColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .transition(.opacity)
    }
  }

  private func prStateBadge(_ title: String, color: Color) -> some View {
    Text(title)
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color, in: Capsule())
      .fixedSize()
  }

  private var pathLines: some View {
    VStack(alignment: .leading, spacing: 3) {
      if item.session.isWorktree {
        pathRow(icon: "arrow.triangle.branch", label: "Worktree", path: item.session.projectPath)
      }
      pathRow(icon: "house", label: "Root", path: rootPath)
    }
  }

  private func pathRow(icon: String, label: String, path: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary.opacity(0.7))
        .frame(width: 12, height: 12)

      Text(displayPath(path))
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help("\(label): \(path)")
  }

  private var rootPath: String {
    resolvedRootPath ?? item.session.projectPath
  }

  private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private func resolveRootPath() async {
    let path = item.session.projectPath
    let resolved = await Task.detached(priority: .utility) {
      GitWorktreeDetector.mainRepoPath(forWorktreeAt: path)
    }.value
    resolvedRootPath = resolved
  }

  private var statusIndicator: some View {
    Circle()
      .fill(statusColor)
      .frame(width: 8, height: 8)
      .shadow(color: statusColor.opacity(item.attention == .working ? 0.55 : 0), radius: 4)
  }

  private var rowBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(rowBackgroundColor)
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(rowBorderColor, lineWidth: isSelected ? 1.5 : 1)
      )
  }

  private var rowBackgroundColor: Color {
    if isSelected {
      return Color.brandPrimary(for: item.providerKind)
        .opacity(colorScheme == .dark ? 0.26 : 0.30)
    }
    if isHovered {
      return Color.brandPrimary(for: item.providerKind)
        .opacity(colorScheme == .dark ? 0.16 : 0.22)
    }
    return Color.surfaceOverlay
      .opacity(colorScheme == .dark ? 0.55 : 0.65)
  }

  private var rowBorderColor: Color {
    if isSelected {
      return Color.brandPrimary(for: item.providerKind).opacity(0.7)
    }
    return Color.secondary.opacity(isHovered ? 0.24 : 0.12)
  }

  private var projectText: String {
    if let branchName = item.session.branchName, !branchName.isEmpty {
      return "\(item.session.projectName) · \(branchName)"
    }
    return item.session.projectName
  }

  private var statusText: String {
    if item.isPending { return "starting" }
    guard let status = item.status else { return item.session.isActive ? "active" : "idle" }
    switch status {
    case .thinking:
      return "working"
    case .executingTool(let name):
      return name.lowercased()
    case .waitingForUser:
      return "ready"
    case .awaitingApproval(let tool):
      return "approval: \(tool.lowercased())"
    case .idle:
      return "idle"
    }
  }

  private var statusColor: Color {
    switch item.attention {
    case .awaitingApproval: return .yellow
    case .gitHubBlocked: return .red
    case .working: return .blue
    case .pending: return .orange
    case .ready: return .green
    case .idle: return .secondary
    }
  }

  private var ciColor: Color {
    if !gitHubViewModel.blockers.isEmpty { return .red }
    if gitHubViewModel.observationState.isUnavailable { return .orange }
    switch gitHubViewModel.ciSummary.overallStatus {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .secondary
    }
  }

  private var ciText: String {
    if gitHubViewModel.observationState.isUnavailable {
      return gitHubViewModel.hasStaleObservation
        ? "Last known: \(gitHubStatusText)"
        : "GitHub unavailable"
    }
    return gitHubStatusText
  }

  private var gitHubStatusText: String {
    let blockers = gitHubViewModel.blockers.sorted { $0.rawValue < $1.rawValue }
    if blockers.count == 1, let blocker = blockers.first {
      return blocker.displayName
    }
    if blockers.count > 1 {
      return "\(blockers.count) PR blockers"
    }

    let summary = gitHubViewModel.ciSummary
    switch summary.overallStatus {
    case .success:
      return summary.total > 0 ? "CI passing \(summary.passed)/\(summary.total)" : "CI passing"
    case .failure:
      return summary.failed == 1 ? "1 check failing" : "\(summary.failed) checks failing"
    case .pending:
      return summary.pending == 1 ? "1 check pending" : "\(summary.pending) checks pending"
    case .none:
      // `.none` means the commit's check rollup is empty — i.e. no CI checks
      // exist for it, not that the status failed to load.
      return summary.total > 0 ? "Checks skipped" : "No checks"
    }
  }

  private var gitHubStatusIcon: String {
    if !gitHubViewModel.blockers.isEmpty {
      return "exclamationmark.triangle.fill"
    }
    if gitHubViewModel.observationState.isUnavailable {
      return "exclamationmark.triangle.fill"
    }
    return gitHubViewModel.ciSummary.overallStatus.icon
  }

  private func observeGitHubIfAvailable() async {
    guard !item.isPending, let observationService = agentHub?.gitHubPRObservationService else {
      gitHubViewModel.stopPolling()
      onGitHubStateChange(nil)
      return
    }

    await gitHubViewModel.load(
      projectPath: item.session.projectPath,
      branchName: item.session.branchName,
      linkedPullRequests: item.linkedPullRequests,
      observationService: observationService,
      refreshOnSubscribe: false,
      recordInitialActivity: false,
      forceRefreshLinkedPullRequest: !item.linkedPullRequests.isEmpty
    )
    await gitHubViewModel.notifySessionActivity(at: item.timestamp)
  }

  private func publishGitHubState() {
    guard let pullRequest = gitHubViewModel.currentBranchPR else {
      onGitHubStateChange(nil)
      return
    }

    onGitHubStateChange(GlobalSessionControlPanelGitHubState(
      hasPullRequest: true,
      ciStatus: gitHubViewModel.ciSummary.overallStatus,
      isRefreshing: gitHubViewModel.observationState.isRefreshing,
      pullRequestNumber: pullRequest.number,
      pullRequestState: pullRequest.stateKind,
      pullRequestMergeability: pullRequest.mergeabilityKind,
      blockers: gitHubViewModel.blockers
    ))
  }
}
