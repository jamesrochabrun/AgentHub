//
//  GlobalSessionControlPanelView.swift
//  AgentHub
//

import AgentHubGitHub
import SwiftUI

// MARK: - GlobalSessionControlPanelView

public struct GlobalSessionControlPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  let selectionRouter: GlobalSessionSelectionRouter
  let onClose: () -> Void
  let onSelectSession: () -> Void

  @State private var gitHubStates: [String: GlobalSessionControlPanelGitHubState] = [:]
  @State private var selectedItemID: String?
  @FocusState private var isPanelFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    selectionRouter: GlobalSessionSelectionRouter,
    onClose: @escaping () -> Void = {},
    onSelectSession: @escaping () -> Void = {}
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
    self.onClose = onClose
    self.onSelectSession = onSelectSession
  }

  public var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .opacity(0.5)

      if items.isEmpty {
        emptyState
      } else {
        sessionList
      }
    }
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
    .onAppear {
      revalidateSelection()
      isPanelFocused = true
    }
    .onChange(of: items.map(\.id)) { _, _ in
      revalidateSelection()
    }
  }

  private var sessionList: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: true) {
        LazyVStack(spacing: 4) {
          ForEach(items) { item in
            GlobalSessionControlPanelRow(
              item: item,
              isSelected: item.id == selectedItemID,
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

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.plain)
      .help("Close")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
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

  private func moveSelection(_ direction: GlobalSessionListNavigationDirection) -> KeyPress.Result {
    let itemIDs = items.map(\.id)
    guard !itemIDs.isEmpty else { return .ignored }
    selectedItemID = GlobalSessionPanelNavigator.nextSelection(
      currentID: selectedItemID,
      direction: direction,
      itemIDs: itemIDs
    )
    return .handled
  }

  private func activateSelectedItem() -> KeyPress.Result {
    guard
      let selectedItemID,
      let item = items.first(where: { $0.id == selectedItemID })
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
      itemIDs: items.map(\.id)
    )
  }
}

// MARK: - GlobalSessionControlPanelRow

private struct GlobalSessionControlPanelRow: View {
  let item: GlobalSessionControlPanelItem
  let isSelected: Bool
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
      linkedPullRequestNumber: item.linkedPullRequestNumber
    )
    return "\(item.id)|\(repositoryKey)|\(item.isPending)|\(agentHub != nil)"
  }

  private var gitHubSignature: String {
    let prNumber = gitHubViewModel.currentBranchPR?.number ?? 0
    let summary = gitHubViewModel.ciSummary
    return [
      "\(prNumber)",
      "\(summary.overallStatus.rawValue)",
      "\(summary.passed)",
      "\(summary.failed)",
      "\(summary.pending)",
      "\(summary.total)",
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
          pathLines
        }

        Spacer(minLength: 8)

        Image(systemName: "arrow.up.forward")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered || isSelected ? 0.9 : 0.45))
          .padding(.top, 3)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
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

      Spacer(minLength: 4)

      Text(item.timestamp.timeAgoDisplay())
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
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
        Image(systemName: gitHubViewModel.ciSummary.overallStatus.icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(ciColor)
          .frame(width: 12, height: 12)

        Text("PR #\(pullRequest.number)")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)

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
    case .ciFailure: return .red
    case .working: return .blue
    case .pending: return .orange
    case .ready: return .green
    case .idle: return .secondary
    }
  }

  private var ciColor: Color {
    switch gitHubViewModel.ciSummary.overallStatus {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .secondary
    }
  }

  private var ciText: String {
    let summary = gitHubViewModel.ciSummary
    switch summary.overallStatus {
    case .success:
      return summary.total > 0 ? "CI passing \(summary.passed)/\(summary.total)" : "CI passing"
    case .failure:
      return summary.failed == 1 ? "1 check failing" : "\(summary.failed) checks failing"
    case .pending:
      return summary.pending == 1 ? "1 check pending" : "\(summary.pending) checks pending"
    case .none:
      return "CI unavailable"
    }
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
      linkedPullRequestNumber: item.linkedPullRequestNumber,
      observationService: observationService,
      refreshOnSubscribe: false,
      recordInitialActivity: false,
      forceRefreshLinkedPullRequest: item.linkedPullRequestNumber != nil
    )
    await gitHubViewModel.notifySessionActivity(at: item.timestamp)
  }

  private func publishGitHubState() {
    guard gitHubViewModel.currentBranchPR != nil else {
      onGitHubStateChange(nil)
      return
    }

    onGitHubStateChange(GlobalSessionControlPanelGitHubState(
      hasPullRequest: true,
      ciStatus: gitHubViewModel.ciSummary.overallStatus,
      isRefreshing: gitHubViewModel.observationState.isRefreshing
    ))
  }
}
