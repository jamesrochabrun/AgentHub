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
  @Environment(\.colorScheme) private var colorScheme

  @AppStorage(AgentHubDefaults.enabledProviders + ".claude")
  private var claudeEnabled = true

  @AppStorage(AgentHubDefaults.enabledProviders + ".codex")
  private var codexEnabled = true

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
      sessionListPanel
        .padding(12)
        .agentHubPanel()
        .navigationSplitViewColumnWidth(min: 300, ideal: 420)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    } detail: {
      MultiProviderMonitoringPanelView(
        claudeViewModel: claudeViewModel,
        codexViewModel: codexViewModel
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

  private var sessionListPanel: some View {
    VStack(spacing: 0) {
      CLIRepositoryPickerView(onAddRepository: showAddRepositoryPicker)
        .padding(.bottom, 10)

      if !hasRepositories {
        CLIEmptyStateView(onAddRepository: showAddRepositoryPicker)
      } else {
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 16) {
            statusHeader

            if claudeEnabled && claudeHasSessions {
              ProviderSectionView(
                title: "Claude",
                viewModel: claudeViewModel,
                onRemoveRepository: removeRepository,
                onCreateWorktree: { repository in
                  createWorktreeContext = WorktreeCreateContext(providerKind: .claude, repository: repository)
                },
                onOpenTerminalForWorktree: { worktree in
                  handleOpenTerminal(worktree: worktree, viewModel: claudeViewModel)
                },
                onOpenSessionFile: { session in
                  openSessionFile(for: session, viewModel: claudeViewModel)
                },
                onSelectSearchResult: { result in
                  handleSearchSelection(result, for: claudeViewModel)
                }
              )
            }

            if codexEnabled && codexHasSessions {
              ProviderSectionView(
                title: "Codex",
                viewModel: codexViewModel,
                onRemoveRepository: removeRepository,
                onCreateWorktree: { repository in
                  createWorktreeContext = WorktreeCreateContext(providerKind: .codex, repository: repository)
                },
                onOpenTerminalForWorktree: { worktree in
                  handleOpenTerminal(worktree: worktree, viewModel: codexViewModel)
                },
                onOpenSessionFile: { session in
                  openSessionFile(for: session, viewModel: codexViewModel)
                },
                onSelectSearchResult: { result in
                  handleSearchSelection(result, for: codexViewModel)
                }
              )
            }

            if !hasVisibleSessions {
              noSessionsView
            }
          }
          .padding(.vertical, 8)
        }
      }
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
        Text("\(allRepositories.count) \(allRepositories.count == 1 ? "module" : "modules") selected · \(totalSessionCount) sessions")
          .font(.caption)
          .foregroundColor(.secondary)

        Spacer()

        // Approval timeout picker (keeps both providers in sync)
        Menu {
          ForEach([3, 5, 10, 15, 30], id: \.self) { seconds in
            Button(action: { setApprovalTimeout(seconds) }) {
              HStack {
                Text("\(seconds)s")
                if approvalTimeoutSeconds == seconds {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "bell")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text("\(approvalTimeoutSeconds)s")
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

        // Toggle first/last message (keeps both providers in sync)
        Button(action: { toggleShowLastMessage() }) {
          HStack(spacing: 6) {
            Image(systemName: showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text(showLastMessage ? "Last message" : "First message")
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
        .help(showLastMessage ? "Showing last message" : "Showing first message")
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
    claudeViewModel.addRepository(at: path)
    codexViewModel.addRepository(at: path)
  }

  private func removeRepository(_ repository: SelectedRepository) {
    claudeViewModel.removeRepository(repository)
    codexViewModel.removeRepository(repository)
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

  private func toggleShowLastMessage() {
    let newValue = !showLastMessage
    claudeViewModel.showLastMessage = newValue
    codexViewModel.showLastMessage = newValue
  }

  private func setApprovalTimeout(_ seconds: Int) {
    claudeViewModel.approvalTimeoutSeconds = seconds
    codexViewModel.approvalTimeoutSeconds = seconds
  }

  // MARK: - Computed

  private var claudeHasSessions: Bool {
    claudeViewModel.totalSessionCount + claudeViewModel.pendingHubSessions.count > 0
  }

  private var codexHasSessions: Bool {
    codexViewModel.totalSessionCount + codexViewModel.pendingHubSessions.count > 0
  }

  private var hasVisibleSessions: Bool {
    (claudeEnabled && claudeHasSessions) || (codexEnabled && codexHasSessions)
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

  private var showLastMessage: Bool {
    claudeViewModel.showLastMessage
  }

  private var approvalTimeoutSeconds: Int {
    claudeViewModel.approvalTimeoutSeconds
  }
}

// MARK: - ProviderSectionView

private struct ProviderSectionView: View {
  let title: String
  @Bindable var viewModel: CLISessionsViewModel
  let onRemoveRepository: (SelectedRepository) -> Void
  let onCreateWorktree: (SelectedRepository) -> Void
  let onOpenTerminalForWorktree: (WorktreeBranch) -> Void
  let onOpenSessionFile: (CLISession) -> Void
  let onSelectSearchResult: (SessionSearchResult) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title)
          .font(.system(.subheadline, weight: .semibold))
          .foregroundColor(Color.brandPrimary(for: viewModel.providerKind))
        Spacer()
        Text("\(viewModel.totalSessionCount)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
      .padding(.horizontal, 4)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.brandPrimary(for: viewModel.providerKind))
          .frame(height: 1)
      }

      ProviderSearchPanel(viewModel: viewModel, onSelectResult: onSelectSearchResult)

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
            onStartInHubForWorktree: { worktree in
              viewModel.startNewSessionInHub(worktree)
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
    .padding(.vertical, 8)
  }
}

// MARK: - ProviderSearchPanel

private struct ProviderSearchPanel: View {
  @Bindable var viewModel: CLISessionsViewModel
  let onSelectResult: (SessionSearchResult) -> Void
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    VStack(spacing: 4) {
      searchBar
      if viewModel.hasPerformedSearch && !viewModel.isSearching {
        searchResultsDropdown
      }
    }
  }

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)

      Button(action: { viewModel.showSearchFilterPicker() }) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(viewModel.hasSearchFilter ? .brandPrimary(for: viewModel.providerKind) : .secondary)
      }
      .buttonStyle(.plain)
      .help("Filter by repository")

      if let filterName = viewModel.searchFilterName {
        HStack(spacing: 4) {
          Text(filterName)
            .font(.system(.caption, weight: .medium))
            .foregroundColor(.brandPrimary(for: viewModel.providerKind))
          Button(action: { viewModel.clearSearchFilter() }) {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundColor(.brandPrimary(for: viewModel.providerKind).opacity(0.8))
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Capsule()
            .fill(Color.brandPrimary(for: viewModel.providerKind).opacity(0.15))
        )
      }

      TextField(
        viewModel.hasSearchFilter ? "Search in \(viewModel.searchFilterName ?? "")..." : "Search all sessions...",
        text: $viewModel.searchQuery
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .focused($isSearchFieldFocused)
      .onSubmit { viewModel.performSearch() }

      if !viewModel.searchQuery.isEmpty {
        Button(action: { viewModel.clearSearch() }) {
          Image(systemName: "delete.left.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)

        if viewModel.isSearching {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 20, height: 20)
        } else {
          Button(action: { viewModel.performSearch() }) {
            Image(systemName: "arrow.right.circle.fill")
              .foregroundColor(.brandPrimary(for: viewModel.providerKind))
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
        .stroke(viewModel.isSearchActive || viewModel.hasSearchFilter ? Color.brandPrimary(for: viewModel.providerKind).opacity(0.5) : Color.borderSubtle, lineWidth: 1)
    )
  }

  private var searchResultsDropdown: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
        .padding(.bottom, 4)

      if viewModel.searchResults.isEmpty {
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
        ForEach(viewModel.searchResults) { result in
          SearchResultRow(
            result: result,
            onSelect: { onSelectResult(result) }
          )
        }
      }
    }
    .padding(.vertical, 8)
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
