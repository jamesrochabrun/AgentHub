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
/// State for terminal branch switch confirmation
private struct TerminalConfirmation: Identifiable {
  let id = UUID()
  let worktree: WorktreeBranch
  let currentBranch: String
}

/// Identifiable wrapper for session file sheet
private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

public struct CLISessionsListView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @State private var createWorktreeRepository: SelectedRepository?
  @State private var terminalConfirmation: TerminalConfirmation?
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @Environment(\.colorScheme) private var colorScheme

  public init(viewModel: CLISessionsViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    HSplitView {
      // Left panel: Session list
      sessionListPanel
        .padding(12)
        .agentHubPanel()
        .frame(minWidth: 300, idealWidth: 400)
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 4)

      // Right panel: Monitoring
      MonitoringPanelView(viewModel: viewModel)
        .padding(12)
        .agentHubPanel()
        .frame(minWidth: 300, idealWidth: 350)
        .padding(.vertical, 8)
        .padding(.leading, 4)
        .padding(.trailing, 8)
    }
    .background(appBackground.ignoresSafeArea())
    .onAppear {
      // Auto-refresh sessions when view appears
      if viewModel.hasRepositories {
        viewModel.refresh()
      }
    }
    .sheet(item: $createWorktreeRepository) { repository in
      CreateWorktreeSheet(
        repositoryPath: repository.path,
        repositoryName: repository.name,
        onDismiss: { createWorktreeRepository = nil },
        onCreate: { branchName, directory, baseBranch, onProgress in
          try await viewModel.createWorktree(
            for: repository,
            branchName: branchName,
            directoryName: directory,
            baseBranch: baseBranch,
            onProgress: onProgress
          )
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
          if let error = await viewModel.openTerminalAndAutoObserve(confirmation.worktree, skipCheckout: false) {
            print("Failed to open terminal: \(error.localizedDescription)")
          }
        }
        terminalConfirmation = nil
      }
    } message: { confirmation in
      Text("You have uncommitted changes on '\(confirmation.currentBranch)'. Switching to '\(confirmation.worktree.name)' may fail or carry changes over.")
    }
    .alert(
      "Failed to Delete Worktree",
      isPresented: Binding(
        get: { viewModel.worktreeDeletionError != nil },
        set: { if !$0 { viewModel.clearWorktreeDeletionError() } }
      )
    ) {
      if let error = viewModel.worktreeDeletionError {
        Button("Try Again") {
          Task {
            let worktree = error.worktree
            viewModel.clearWorktreeDeletionError()
            await viewModel.deleteWorktree(worktree)
          }
        }
        Button("Open in Terminal") {
          if let error = viewModel.worktreeDeletionError {
            _ = viewModel.openTerminalInWorktree(error.worktree)
            viewModel.clearWorktreeDeletionError()
          }
        }
        Button("Cancel", role: .cancel) {
          viewModel.clearWorktreeDeletionError()
        }
      }
    } message: {
      if let error = viewModel.worktreeDeletionError {
        Text("Could not delete worktree at:\n\(error.worktree.path)\n\nError: \(error.message)")
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

  // MARK: - Session List Panel

  private var sessionListPanel: some View {
    VStack(spacing: 0) {
      // Add repository button (always visible)
      CLIRepositoryPickerView(onAddRepository: viewModel.showAddRepositoryPicker)
        .padding(.bottom, 10)

      // Search bar
      searchBar
        .padding(.bottom, 10)

      // Conditional content based on search state
      if viewModel.isSearchActive {
        searchResultsView
      } else if viewModel.isLoading && !viewModel.hasRepositories {
        loadingView
      } else if !viewModel.hasRepositories {
        CLIEmptyStateView(onAddRepository: viewModel.showAddRepositoryPicker)
      } else {
        repositoriesList
      }
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
        Image(systemName: "folder")
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
        .onChange(of: viewModel.searchQuery) { _, _ in
          viewModel.performSearch()
        }

      if !viewModel.searchQuery.isEmpty {
        Button(action: { viewModel.clearSearch() }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }

      if viewModel.isSearching {
        ProgressView()
          .scaleEffect(0.7)
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
        .stroke(viewModel.isSearchActive || viewModel.hasSearchFilter ? Color.brandPrimary.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
    )
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
    ScrollView {
      LazyVStack(spacing: 12) {
        // Status header
        statusHeader

        // Repository tree views
        ForEach(viewModel.selectedRepositories) { repository in
          CLIRepositoryTreeView(
            repository: repository,
            onRemove: { viewModel.removeRepository(repository) },
            onToggleExpanded: { viewModel.toggleRepositoryExpanded(repository) },
            onToggleWorktreeExpanded: { worktree in
              viewModel.toggleWorktreeExpanded(in: repository, worktree: worktree)
            },
            onConnectSession: { session in
              if let error = viewModel.connectToSession(session) {
                print("Failed to connect: \(error.localizedDescription)")
              }
            },
            onCopySessionId: { session in
              viewModel.copySessionId(session)
            },
            onOpenSessionFile: { session in
              // Build path: ~/.claude/projects/{encoded-project-path}/{sessionId}.jsonl
              let encodedPath = session.projectPath.replacingOccurrences(of: "/", with: "-")
              let homeDir = FileManager.default.homeDirectoryForCurrentUser
              let filePath = homeDir
                .appendingPathComponent(".claude/projects")
                .appendingPathComponent(encodedPath)
                .appendingPathComponent("\(session.id).jsonl")

              // Read file content
              if let data = FileManager.default.contents(atPath: filePath.path),
                 let content = String(data: data, encoding: .utf8) {
                sessionFileSheetItem = SessionFileSheetItem(
                  session: session,
                  fileName: "\(session.id).jsonl",
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
            onCreateWorktree: {
              createWorktreeRepository = repository
            },
            onOpenTerminalForWorktree: { worktree in
              Task {
                let check = await viewModel.checkBeforeOpeningTerminal(worktree)

                if !check.needsCheckout {
                  // Already on correct branch or is a worktree - open directly
                  if let error = await viewModel.openTerminalAndAutoObserve(worktree, skipCheckout: true) {
                    print("Failed to open terminal: \(error.localizedDescription)")
                  }
                } else if check.hasUncommittedChanges {
                  // Need checkout but have uncommitted changes - show confirmation
                  terminalConfirmation = TerminalConfirmation(
                    worktree: worktree,
                    currentBranch: check.currentBranch
                  )
                } else {
                  // Need checkout but no uncommitted changes - proceed with checkout
                  if let error = await viewModel.openTerminalAndAutoObserve(worktree, skipCheckout: false) {
                    print("Failed to open terminal: \(error.localizedDescription)")
                  }
                }
              }
            },
            onDeleteWorktree: { worktree in
              Task {
                await viewModel.deleteWorktree(worktree)
              }
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
        // Session count
        if viewModel.activeSessionCount > 0 {
          HStack(spacing: 6) {
            Circle()
              .fill(Color.green)
              .frame(width: DesignTokens.StatusSize.sm, height: DesignTokens.StatusSize.sm)
              .shadow(color: .green.opacity(0.4), radius: 2)
            Text("\(viewModel.activeSessionCount) active")
              .font(.system(.caption, weight: .medium))
              .foregroundColor(.green)
          }
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs)
          .background(
            Capsule()
              .fill(Color.green.opacity(0.1))
          )
        }

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

  print("[JSONL Filter] Content length: \(content.count), lines count: \(lines.count)")
  if let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
    print("[JSONL Filter] First non-empty line preview: \(String(firstLine.prefix(300)))")
  }

  // Debug counters
  var totalLines = 0
  var emptyLines = 0
  var jsonParseFailures = 0
  var noTypeField = 0
  var skippedTypes = 0
  var noMessageField = 0
  var noContentBlocks = 0
  var onlyToolResults = 0
  var noMeaningfulContent = 0

  for line in lines {
    totalLines += 1
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty {
      emptyLines += 1
      continue
    }

    guard let data = trimmed.data(using: .utf8) else {
      jsonParseFailures += 1
      continue
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      jsonParseFailures += 1
      // Log first failure to see what's happening
      if jsonParseFailures == 1 {
        print("[JSONL Filter] First parse failure, line preview: \(String(trimmed.prefix(200)))")
      }
      continue
    }

    // Skip non-message entries
    guard let type = json["type"] as? String else {
      noTypeField += 1
      print("[JSONL Filter] No type field, keys: \(json.keys)")
      continue
    }

    // Skip file-history-snapshot, summary, etc.
    if type != "user" && type != "assistant" {
      skippedTypes += 1
      print("[JSONL Filter] Skipped type: '\(type)'")
      continue
    }

    guard let message = json["message"] as? [String: Any] else {
      noMessageField += 1
      print("[JSONL Filter] No message field for type=\(type), keys: \(json.keys)")
      continue
    }

    guard let contentBlocks = message["content"] as? [[String: Any]] else {
      noContentBlocks += 1
      print("[JSONL Filter] No content blocks for type=\(type), message keys: \(message.keys)")
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
          // Add brief context for the tool
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
        // Skip entirely
        continue

      default:
        hasOnlyToolResults = false
      }
    }

    // Skip entries that only had tool_result blocks
    if hasOnlyToolResults {
      onlyToolResults += 1
      continue
    }

    // Build clean output line
    var output = "[\(type.uppercased())]"

    if !textParts.isEmpty {
      output += " " + textParts.joined(separator: " ")
    }

    if !toolNames.isEmpty {
      output += " [Tools: " + toolNames.joined(separator: ", ") + "]"
    }

    // Only add if we have meaningful content
    if textParts.isEmpty && toolNames.isEmpty {
      noMeaningfulContent += 1
      continue
    }

    result.append(output)
  }

  print("""
  [JSONL Filter] Stats:
    Content length: \(content.count)
    Total lines: \(totalLines)
    Empty lines: \(emptyLines)
    JSON parse failures: \(jsonParseFailures)
    No type field: \(noTypeField)
    Skipped types: \(skippedTypes)
    No message field: \(noMessageField)
    No content blocks: \(noContentBlocks)
    Only tool results: \(onlyToolResults)
    No meaningful content: \(noMeaningfulContent)
    Final result count: \(result.count)
  """)

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
  let viewModel = CLISessionsViewModel(monitorService: service)

  return CLISessionsListView(viewModel: viewModel)
    .frame(width: 800, height: 600)
}
