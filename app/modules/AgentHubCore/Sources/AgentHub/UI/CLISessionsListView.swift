//
//  CLISessionsListView.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import AppKit
import Foundation
import PierreDiffsSwift
import SwiftUI

// MARK: - CLISessionsListView

/// Main list view for displaying CLI sessions with repository-based organization

/// Identifiable wrapper for session file sheet
private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

public struct CLISessionsListView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var isSearchSheetVisible: Bool = false
  @State private var primarySessionId: String?
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isSearchFieldFocused: Bool

  public init(viewModel: CLISessionsViewModel, columnVisibility: Binding<NavigationSplitViewVisibility>) {
    self.viewModel = viewModel
    self._columnVisibility = columnVisibility
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      // Sidebar: Session list
      sidePanelView
        .agentHubPanel()
        .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    } detail: {
      // Detail: Monitoring panel
      MonitoringPanelView(
        viewModel: viewModel,
        claudeClient: viewModel.claudeClient,
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
    .onChange(of: viewModel.hasPerformedSearch) { oldValue, newValue in
      // Auto-dismiss sheet when search is cleared after selecting a result
      if oldValue && !newValue && isSearchSheetVisible {
        withAnimation(.easeInOut(duration: 0.25)) {
          isSearchSheetVisible = false
        }
      }
    }
    .onAppear {
      // Auto-refresh sessions when view appears
      if viewModel.hasRepositories {
        viewModel.refresh()
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
        get: { viewModel.worktreeDeletionError != nil },
        set: { if !$0 { viewModel.clearWorktreeDeletionError() } }
      )
    ) {
      if let error = viewModel.worktreeDeletionError {
        if error.isOrphaned, let parentRepoPath = error.parentRepoPath {
          // Orphaned worktree - offer to prune & delete
          Button("Prune & Delete") {
            Task {
              let worktree = error.worktree
              await viewModel.deleteOrphanedWorktree(worktree, parentRepoPath: parentRepoPath)
            }
          }
          Button("Cancel", role: .cancel) {
            viewModel.clearWorktreeDeletionError()
          }
        } else {
          // Regular error - offer retry
          Button("Try Again") {
            Task {
              let worktree = error.worktree
              viewModel.clearWorktreeDeletionError()
              await viewModel.deleteWorktree(worktree)
            }
          }
          Button("Cancel", role: .cancel) {
            viewModel.clearWorktreeDeletionError()
          }
        }
      }
    } message: {
      if let error = viewModel.worktreeDeletionError {
        if error.isOrphaned {
          Text("""
            This worktree is orphaned - the directory exists but git no longer tracks it.

            This can happen when worktree metadata is deleted or corrupted.

            "Prune & Delete" will run 'git worktree prune' and remove the directory.

            Path: \(error.worktree.path)
            """)
        } else {
          Text("Could not delete worktree at:\n\(error.worktree.path)\n\nError: \(error.message)")
        }
      }
    }
  }

  // MARK: - App Background

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

  // MARK: - Session List Content

  private var sessionListContent: some View {
    VStack(spacing: 0) {
      // Add repository button (always visible)
      CLIRepositoryPickerView(onAddRepository: viewModel.showAddRepositoryPicker)
        .padding(.bottom, 10)

      // Toggle between button and expanded search inline
      if isSearchSheetVisible {
        inlineExpandedSearch
          .padding(.bottom, 10)
      } else {
        searchButton
          .padding(.bottom, 10)
      }

      // Always show normal content
      if viewModel.isLoading && !viewModel.hasRepositories {
        loadingView
      } else {
        repositoriesList
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isSearchSheetVisible)
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

        SingleProviderCollapsibleSelectedSessionsPanel(
          viewModel: viewModel,
          primarySessionId: $primarySessionId
        )
        .frame(height: panelHeight(for: geometry.size.height))
      }
    }
  }

  private func panelHeight(for availableHeight: CGFloat) -> CGFloat {
    let headerHeight: CGFloat = 40
    let monitoredCount = viewModel.monitoredSessions.count + viewModel.pendingHubSessions.count

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

  // MARK: - Search Bar

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)

      // Folder filter button
      Button(action: { viewModel.showSearchFilterPicker() }) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(viewModel.hasSearchFilter ? .brandPrimary : .secondary)
      }
      .buttonStyle(.plain)
      .help("Filter by repository")

      // Filter chip (when active)
      if let filterName = viewModel.searchFilterName {
        HStack(spacing: 4) {
          Text(filterName)
            .font(.system(.caption, weight: .medium))
            .foregroundColor(.brandPrimary)
          Button(action: { viewModel.clearSearchFilter() }) {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundColor(.brandPrimary.opacity(0.8))
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Capsule()
            .fill(Color.brandPrimary.opacity(0.15))
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
        // Clear text button
        Button(action: { viewModel.clearSearch() }) {
          Image(systemName: "delete.left.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)

        // Search button / Loading indicator
        if viewModel.isSearching {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 20, height: 20)
            .transition(.opacity.combined(with: .scale))
        } else {
          Button(action: { viewModel.performSearch() }) {
            Image(systemName: "arrow.right.circle.fill")
              .foregroundColor(.brandPrimary)
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .scale))
        }
      }
    }
    .animation(.easeInOut(duration: 0.15), value: viewModel.isSearching)
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(viewModel.isSearchActive || viewModel.hasSearchFilter ? Color.brandPrimary.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Search Button

  private var searchButton: some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.25)) {
        isSearchSheetVisible = true
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
          .foregroundColor(.primary)

        Text("Search all sessions...")
          .font(.system(size: 13))
          .foregroundColor(.primary)

        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(Color.secondary.opacity(0.2))
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }
    .buttonStyle(.plain)
  }

  // MARK: - Inline Expanded Search

  private var inlineExpandedSearch: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        // Reuse searchBar
        searchBar

        // Close button to collapse back to button
        Button(action: { dismissSearchSheet() }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }

      // Results dropdown (existing)
      inlineSearchResultsDropdown
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.hasPerformedSearch)
  }

  // MARK: - Dismiss Search Sheet

  private func dismissSearchSheet() {
    withAnimation(.easeInOut(duration: 0.25)) {
      isSearchSheetVisible = false
    }
    viewModel.clearSearch()
  }

  // MARK: - Inline Search Results Dropdown

  @ViewBuilder
  private var inlineSearchResultsDropdown: some View {
    if viewModel.hasPerformedSearch && !viewModel.isSearching {
      VStack(spacing: 0) {
        if viewModel.searchResults.isEmpty {
          // No results UI (compact version)
          noResultsDropdownView
        } else {
          // Results list
          ScrollView {
            LazyVStack(spacing: 8) {
              ForEach(viewModel.searchResults.prefix(10)) { result in
                SearchResultRow(
                  result: result,
                  onSelect: { viewModel.selectSearchResult(result) }
                )
              }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
          }
          .frame(maxHeight: 280)
        }
      }
      .background(Color.surfaceOverlay)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
      .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
      .animation(.easeInOut(duration: 0.2), value: viewModel.searchResults.isEmpty)
    }
  }

  // MARK: - No Results Dropdown View

  private var noResultsDropdownView: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundColor(.secondary.opacity(0.5))
      Text("No sessions found")
        .font(.system(.caption, weight: .medium))
        .foregroundColor(.secondary.opacity(0.7))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }

  // MARK: - Search Results View

  private var searchResultsView: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        if viewModel.searchResults.isEmpty && !viewModel.isSearching {
          noSearchResultsView
        } else {
          ForEach(viewModel.searchResults) { result in
            SearchResultRow(
              result: result,
              onSelect: { viewModel.selectSearchResult(result) }
            )
          }
        }
      }
      .padding(.vertical, 8)
    }
  }

  private var noSearchResultsView: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 32))
        .foregroundColor(.secondary.opacity(0.6))
      Text("No sessions found")
        .font(.system(.headline, weight: .medium))
        .foregroundColor(.secondary)
      Text("Try a different search term")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.8))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.top, 60)
  }

  // MARK: - Loading View

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle())
      Text(viewModel.loadingState.message)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Repositories List

  private var repositoriesList: some View {
    ScrollView(showsIndicators: false) {
      LazyVStack(spacing: 12) {
        // Status header
        statusHeader

        // Repository tree views
        ForEach(viewModel.selectedRepositories) { repository in
          CLIRepositoryTreeView(
            repository: repository,
            providerKind: viewModel.providerKind,
            onRemove: { viewModel.removeRepository(repository) },
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
              guard let fileURL = viewModel.sessionFileURL(for: session),
                    let data = FileManager.default.contents(atPath: fileURL.path),
                    let content = String(data: data, encoding: .utf8) else {
                return
              }

              // Read file content
              if !content.isEmpty {
                sessionFileSheetItem = SessionFileSheetItem(
                  session: session,
                  fileName: fileURL.lastPathComponent,
                  content: content
                )
              }
            },
            isSessionMonitored: { sessionId in
              viewModel.isMonitoring(sessionId: sessionId)
            },
            onToggleMonitoring: { session in
              viewModel.toggleMonitoring(for: session)
            },
            onDeleteWorktree: { worktree in
              Task {
                await viewModel.deleteWorktree(worktree)
              }
            },
            getCustomName: { sessionId in
              viewModel.sessionCustomNames[sessionId]
            },
            showLastMessage: viewModel.showLastMessage,
            isDebugMode: true,  // Enable debug mode for now
            deletingWorktreePath: viewModel.deletingWorktreePath
          )
        }
      }
      .padding(.vertical, 8)
    }
  }

  // MARK: - Status Header

  private var statusHeader: some View {
    VStack(spacing: 8) {
      // Loading indicator (when loading with repositories)
      if viewModel.isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .scaleEffect(0.7)
          Text(viewModel.loadingState.message)
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
        Text("\(viewModel.selectedRepositories.count) \(viewModel.selectedRepositories.count == 1 ? "module" : "modules") selected · \(viewModel.totalSessionCount) sessions")
          .font(.caption)
          .foregroundColor(.secondary)

        Spacer()

        // Approval timeout picker
        Menu {
          ForEach([3, 5, 10, 15, 30], id: \.self) { seconds in
            Button(action: { viewModel.approvalTimeoutSeconds = seconds }) {
              HStack {
                Text("\(seconds)s")
                if viewModel.approvalTimeoutSeconds == seconds {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "bell")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text("\(viewModel.approvalTimeoutSeconds)s")
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
        .menuStyle(.borderlessButton)
        .help("Alert sound delay: \(viewModel.approvalTimeoutSeconds) seconds")

        // First/Last message toggle
        Button(action: { viewModel.showLastMessage.toggle() }) {
          HStack(spacing: 6) {
            Image(systemName: viewModel.showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text(viewModel.showLastMessage ? "Last message" : "First message")
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
        .help(viewModel.showLastMessage ? "Showing last message" : "Showing first message")

        // Refresh button
        Button(action: viewModel.refresh) {
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
        .disabled(viewModel.isLoading)
        .help("Refresh sessions")
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.xs)
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

    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
      continue
    }

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

    guard type == "user" || type == "assistant",
          let message = json["message"] as? [String: Any],
          let contentBlocks = message["content"] as? [[String: Any]] else {
      continue
    }

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

    if !textParts.isEmpty || !toolNames.isEmpty {
      result.append(output)
    }
  }

  if result.isEmpty {
    return "[No conversation content found - this session may only contain file history snapshots or tool results]"
  }

  return result.joined(separator: "\n\n")
}

// MARK: - SessionFileSheetView

/// Sheet view that displays session JSONL content using PierreDiffView
private struct SessionFileSheetView: View {
  let session: CLISession
  let fileName: String
  let content: String
  let onDismiss: () -> Void

  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap

  var body: some View {
    VStack(spacing: 0) {
      // Header
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

      // Diff view showing filtered content (removes tool results, thinking blocks, etc.)
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

// MARK: - Preview

#Preview {
  let service = CLISessionMonitorService()
  let viewModel = CLISessionsViewModel(
    monitorService: service,
    fileWatcher: SessionFileWatcher(),
    searchService: GlobalSearchService(),
    cliConfiguration: .claudeDefault,
    providerKind: .claude
  )

  CLISessionsListView(viewModel: viewModel, columnVisibility: .constant(.all))
    .frame(width: 800, height: 600)
}
