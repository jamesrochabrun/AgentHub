//
//  GitDiffView.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import SwiftUI
import PierreDiffsSwift
import ClaudeCodeSDK

// MARK: - GitDiffView

/// Full-screen sheet displaying git diffs (staged and unstaged) for a CLI session's repository.
///
/// Provides a split-pane interface with a file list sidebar and diff viewer. Supports both
/// unified and split diff styles with word wrap toggle. When `claudeClient` is provided,
/// enables an inline editor overlay that allows users to click on any diff line and ask
/// questions about the code, which opens Terminal with a resumed session containing the
/// contextual prompt.
///
/// - Note: Uses `GitDiffService` to fetch diffs via git commands on the session's project path.
public struct GitDiffView: View {
  let session: CLISession
  let projectPath: String
  let onDismiss: () -> Void
  let claudeClient: (any ClaudeCode)?
  let cliConfiguration: CLICommandConfiguration?
  let providerKind: SessionProviderKind
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  var isEmbedded: Bool = false

  /// Inline editor is enabled when either claudeClient or cliConfiguration is available
  private var isInlineEditorEnabled: Bool {
    claudeClient != nil || cliConfiguration != nil
  }

  @State private var diffState: GitDiffState = .empty
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var selectedFileId: UUID?
  @State private var diffContents: [UUID: (old: String, new: String)] = [:]
  @State private var parsedDiffs: [UUID: ParsedFileDiff] = [:]
  @State private var loadingStates: [UUID: Bool] = [:]
  @State private var fileErrorMessages: [UUID: String] = [:]
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var inlineEditorState = InlineEditorState()
  @State private var diffMode: DiffMode = .unstaged
  @State private var detectedBaseBranch: String?
  @State private var commentsState = DiffCommentsState()
  @State private var showDiscardCommentsAlert = false
  @State private var expandedPaths: Set<String> = []
  @State private var showSidebar: Bool = true
  @State private var treeCommonPrefix: String = ""

  private let gitDiffService = GitDiffService()

  public init(
    session: CLISession,
    projectPath: String,
    onDismiss: @escaping () -> Void,
    claudeClient: (any ClaudeCode)? = nil,
    cliConfiguration: CLICommandConfiguration? = nil,
    providerKind: SessionProviderKind = .claude,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.claudeClient = claudeClient
    self.cliConfiguration = cliConfiguration
    self.providerKind = providerKind
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.isEmbedded = isEmbedded
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if isLoading {
        loadingState
      } else if let error = errorMessage {
        errorState(error)
      } else if diffState.files.isEmpty {
        emptyState
      } else {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            if showSidebar {
              // File list sidebar
              fileListSidebar
                .frame(width: 250)
              Divider()
            }

            // Diff viewer
            diffViewer
          }
          .animation(.easeInOut(duration: 0.25), value: showSidebar)

          // Comments panel (shown when there are comments)
          if commentsState.hasComments {
            DiffCommentsPanelView(
              commentsState: commentsState,
              providerKind: providerKind,
              onSendToCloud: sendAllCommentsToCloud
            )
          }
        }
      }
    }
    .frame(
      minWidth: isEmbedded ? 400 : 1200, idealWidth: .infinity, maxWidth: .infinity,
      minHeight: isEmbedded ? 400 : 800, idealHeight: .infinity, maxHeight: .infinity
    )
    .onKeyPress(.escape) {
      if inlineEditorState.isShowing {
        withAnimation(.easeOut(duration: 0.15)) {
          inlineEditorState.dismiss()
        }
        return .handled
      }
      // Check for unsent comments before dismissing
      if commentsState.hasComments {
        showDiscardCommentsAlert = true
        return .handled
      }
      onDismiss()
      return .handled
    }
    .task {
      await loadChanges(for: diffMode)
    }
    .confirmationDialog(
      "Discard Unsent Comments?",
      isPresented: $showDiscardCommentsAlert,
      titleVisibility: .visible
    ) {
      Button("Discard \(commentsState.commentCount) Comment\(commentsState.commentCount == 1 ? "" : "s")", role: .destructive) {
        commentsState.clearAll()
        onDismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You have \(commentsState.commentCount) unsent comment\(commentsState.commentCount == 1 ? "" : "s"). Closing will discard them.")
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      HStack(spacing: 8) {
        // Comment count badge
        if commentsState.hasComments {
          HStack(spacing: 4) {
            Image(systemName: "text.bubble.fill")
              .font(.caption)
            Text("\(commentsState.commentCount)")
              .font(.caption.bold())
          }
          .foregroundColor(.primary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule()
              .fill(Color.secondary.opacity(0.2))
          )
        }
      }

      // Session info
      HStack(spacing: 8) {
        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      // Segmented control
      Picker("", selection: $diffMode) {
        ForEach(DiffMode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 250)
      .tint(Color.primary)
      .onChange(of: diffMode) { _, newMode in
        Task { await loadChanges(for: newMode) }
      }

      Button("Close") {
        if commentsState.hasComments {
          showDiscardCommentsAlert = true
        } else {
          onDismiss()
        }
      }
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Loading State

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(diffMode.loadingMessage)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error State

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.red.opacity(0.5))

      Text("Failed to Load Git Diff")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)

      Button("Retry") {
        Task { await loadChanges(for: diffMode) }
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 48))
        .foregroundColor(.green.opacity(0.5))

      Text(diffMode.emptyStateTitle)
        .font(.headline)
        .foregroundColor(.secondary)

      Text(diffMode.emptyStateDescription)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - File List Sidebar

  /// Builds a hierarchical tree from flat file entries
  private var fileTree: [FileTreeNode] {
    buildFileTree(from: diffState.files).nodes
  }

  /// Finds the longest common directory prefix among all file paths
  private func findCommonPrefix(from files: [GitDiffFileEntry]) -> [String] {
    guard let first = files.first else { return [] }

    // Get directory components (exclude filename)
    var commonComponents = Array(first.relativePath.components(separatedBy: "/").dropLast())

    for file in files.dropFirst() {
      let components = Array(file.relativePath.components(separatedBy: "/").dropLast())
      // Keep only matching prefix components
      var matchCount = 0
      for (a, b) in zip(commonComponents, components) {
        if a == b {
          matchCount += 1
        } else {
          break
        }
      }
      commonComponents = Array(commonComponents.prefix(matchCount))
      if commonComponents.isEmpty { break }
    }

    return commonComponents
  }

  /// Result of building the file tree
  private struct FileTreeResult {
    let nodes: [FileTreeNode]
    let commonPrefix: String
    let allFolderPaths: Set<String>
  }

  private func buildFileTree(from files: [GitDiffFileEntry]) -> FileTreeResult {
    guard !files.isEmpty else {
      return FileTreeResult(nodes: [], commonPrefix: "", allFolderPaths: [])
    }

    // Find common prefix to strip
    let commonComponents = findCommonPrefix(from: files)
    let commonPrefix = commonComponents.joined(separator: "/")
    let stripCount = commonComponents.count

    // Root node to hold top-level children
    let root = FileTreeNode(name: "", fullPath: "", file: nil)
    var allFolderPaths: Set<String> = []

    for file in files {
      // Strip common prefix from path components
      let allComponents = file.relativePath.components(separatedBy: "/")
      let pathComponents = Array(allComponents.dropFirst(stripCount))

      var currentNode = root
      var currentPath = ""

      for (index, component) in pathComponents.enumerated() {
        let isLastComponent = index == pathComponents.count - 1
        currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"

        if isLastComponent {
          // This is a file node
          let fileNode = FileTreeNode(
            name: component,
            fullPath: currentPath,
            file: file
          )
          currentNode.childrenDict[component] = fileNode
        } else {
          // This is a folder node
          if currentNode.childrenDict[component] == nil {
            let folderNode = FileTreeNode(
              name: component,
              fullPath: currentPath,
              file: nil
            )
            currentNode.childrenDict[component] = folderNode
          }
          allFolderPaths.insert(currentPath)
          // Move into this folder
          currentNode = currentNode.childrenDict[component]!
        }
      }
    }

    // Convert dictionary to sorted array starting from root's children
    let nodes = sortNodes(from: root.childrenDict)
    return FileTreeResult(nodes: nodes, commonPrefix: commonPrefix, allFolderPaths: allFolderPaths)
  }

  private func sortNodes(from dict: [String: FileTreeNode]) -> [FileTreeNode] {
    dict.values
      .map { node in
        // Recursively sort children
        if !node.childrenDict.isEmpty {
          node.children = sortNodes(from: node.childrenDict)
        }
        return node
      }
      .sorted { lhs, rhs in
        // Folders first, then alphabetically
        if lhs.isFolder != rhs.isFolder {
          return lhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  private var fileListSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Changes")
          .font(.headline)
        Spacer()
      }
      .padding()

      Divider()

      // Common prefix header (shows collapsed path context)
      if !treeCommonPrefix.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "folder.fill")
            .font(.caption2)
            .foregroundColor(.secondary)
          Text(treeCommonPrefix)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
      }

      // Hierarchical file tree
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(fileTree) { node in
            FileTreeNodeRow(
              node: node,
              depth: 0,
              expandedPaths: $expandedPaths,
              selectedFileId: selectedFileId,
              onSelectFile: { file in
                selectedFileId = file.id
                loadFileDiff(for: file, mode: diffMode)
              }
            )
          }
        }
        .padding(8)
      }
    }
  }

  // MARK: - Diff Viewer

  @ViewBuilder
  private var diffViewer: some View {
    if let selectedId = selectedFileId {
      if loadingStates[selectedId] == true {
        // Loading state
        VStack {
          ProgressView()
          Text("Loading diff...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = fileErrorMessages[selectedId] {
        // Error state
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundColor(.red)
          Text(error)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
      } else if let contents = diffContents[selectedId] {
        // Find the file entry for the name
        if let file = diffState.files.first(where: { $0.id == selectedId }) {
          GitDiffContentView(
            oldContent: contents.old,
            newContent: contents.new,
            fileName: file.fileName,
            filePath: file.filePath,
            showSidebar: $showSidebar,
            diffStyle: $diffStyle,
            overflowMode: $overflowMode,
            inlineEditorState: inlineEditorState,
            commentsState: commentsState,
            claudeClient: claudeClient,
            cliConfiguration: cliConfiguration,
            providerKind: providerKind,
            session: session,
            onDismissView: onDismiss,
            onInlineRequestSubmit: onInlineRequestSubmit
          )
          .frame(minHeight: 400)
          .id(selectedId)
        }
      } else {
        // No diff loaded
        Text("Select a file to view")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      Text("Select a file to view")
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Data Loading

  private func loadChanges(for mode: DiffMode) async {
    // Clear existing state when switching modes
    await MainActor.run {
      isLoading = true
      errorMessage = nil
      diffState = .empty
      diffContents = [:]
      parsedDiffs = [:]
      selectedFileId = nil
      loadingStates = [:]
      fileErrorMessages = [:]
      treeCommonPrefix = ""
      expandedPaths = []
    }

    do {
      // Detect base branch for branch mode (cache it for later use)
      if mode == .branch && detectedBaseBranch == nil {
        detectedBaseBranch = try await gitDiffService.detectBaseBranch(at: projectPath)
      }

      let gitRoot = try await gitDiffService.findGitRoot(at: projectPath)

      // Get unified diff in ONE command (fast path)
      let unifiedDiff = try await gitDiffService.getUnifiedDiffOutput(
        at: projectPath,
        mode: mode,
        baseBranch: detectedBaseBranch
      )

      // Parse all tracked file diffs upfront
      let parsed = DiffParserUtils.parse(diffOutput: unifiedDiff)
      var entries = DiffParserUtils.toGitDiffFileEntries(parsed, gitRoot: gitRoot)

      // Build lookup for parsed content by matching relativePath
      var parsedLookup: [UUID: ParsedFileDiff] = [:]
      for diff in parsed {
        if let entry = entries.first(where: { $0.relativePath == diff.filePath }) {
          parsedLookup[entry.id] = diff
        }
      }

      // HYBRID: For unstaged mode, also get untracked files (not included in git diff)
      if mode == .unstaged {
        let untrackedEntries = try await fetchUntrackedFiles(gitRoot: gitRoot)
        entries.append(contentsOf: untrackedEntries)
        // Note: untracked files won't be in parsedLookup, so they'll use fallback
      }

      await MainActor.run {
        diffState = GitDiffState(files: entries)
        parsedDiffs = parsedLookup
        isLoading = false

        // Build tree and auto-expand all folders
        let treeResult = buildFileTree(from: entries)
        treeCommonPrefix = treeResult.commonPrefix
        expandedPaths = treeResult.allFolderPaths

        // Auto-select first file
        if let first = entries.first {
          selectedFileId = first.id
          // Use cache if available (instant), otherwise loadFileDiff handles fallback
          if let cachedParsed = parsedLookup[first.id] {
            let contents = DiffParserUtils.extractContentsFromDiff(cachedParsed.diffContent)
            diffContents[first.id] = contents
          } else {
            loadFileDiff(for: first, mode: mode)
          }
        }
      }

    } catch {
      await MainActor.run {
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
  }

  /// Fetches untracked files from git status --porcelain
  private func fetchUntrackedFiles(gitRoot: String) async throws -> [GitDiffFileEntry] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["status", "--porcelain", "-uall"]
    process.currentDirectoryURL = URL(fileURLWithPath: gitRoot)

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    let data = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
    let output = String(data: data, encoding: .utf8) ?? ""

    var untrackedPaths: [(relativePath: String, fullPath: String)] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      guard line.count > 3 else { continue }
      let statusCode = String(line.prefix(2))
      let filePath = String(line.dropFirst(3))

      // "??" means untracked file
      if statusCode == "??" {
        let fullPath = (gitRoot as NSString).appendingPathComponent(filePath)
        untrackedPaths.append((relativePath: filePath, fullPath: fullPath))
      }
    }

    // Count lines in parallel for untracked files
    return await withTaskGroup(of: GitDiffFileEntry.self) { group in
      for (relativePath, fullPath) in untrackedPaths {
        group.addTask {
          let lineCount = await self.countLinesInFile(at: fullPath)
          return GitDiffFileEntry(
            filePath: fullPath,
            relativePath: relativePath,
            additions: lineCount,
            deletions: 0
          )
        }
      }

      var results: [GitDiffFileEntry] = []
      for await entry in group {
        results.append(entry)
      }
      return results
    }
  }

  /// Counts lines in a file
  private func countLinesInFile(at path: String) async -> Int {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
      return 0
    }
    return content.components(separatedBy: .newlines).count
  }

  private func loadFileDiff(for file: GitDiffFileEntry, mode: DiffMode? = nil) {
    // Skip if already loaded
    if diffContents[file.id] != nil { return }

    // Check parsed cache first (instant - no async needed)
    if let parsed = parsedDiffs[file.id] {
      let contents = DiffParserUtils.extractContentsFromDiff(parsed.diffContent)
      diffContents[file.id] = contents
      return
    }

    // Fallback to old approach for untracked files (not in git diff output)
    loadingStates[file.id] = true

    let currentMode = mode ?? diffMode

    Task {
      do {
        let (oldContent, newContent) = try await gitDiffService.getFileDiff(
          filePath: file.filePath,
          at: projectPath,
          mode: currentMode,
          baseBranch: detectedBaseBranch
        )
        await MainActor.run {
          diffContents[file.id] = (old: oldContent, new: newContent)
          loadingStates[file.id] = false
        }
      } catch {
        await MainActor.run {
          fileErrorMessages[file.id] = error.localizedDescription
          loadingStates[file.id] = false
        }
      }
    }
  }

  // MARK: - Comments Actions

  /// Sends all pending comments to Claude as a batch review
  private func sendAllCommentsToCloud() {
    guard commentsState.hasComments, isInlineEditorEnabled else { return }

    let prompt = commentsState.generatePrompt()

    // Use callback if provided (redirects to built-in terminal)
    if let callback = onInlineRequestSubmit {
      callback(prompt, session)
      commentsState.clearAll()
      onDismiss()
    } else if let client = claudeClient {
      // Fallback to external Terminal with claudeClient
      if let error = TerminalLauncher.launchTerminalWithSession(
        session.id,
        claudeClient: client,
        projectPath: session.projectPath,
        initialPrompt: prompt
      ) {
        inlineEditorState.errorMessage = error.localizedDescription
      } else {
        commentsState.clearAll()
        onDismiss()
      }
    } else if let config = cliConfiguration {
      // Fallback to external Terminal with cliConfiguration
      if let error = TerminalLauncher.launchTerminalWithSession(
        session.id,
        cliConfiguration: config,
        projectPath: session.projectPath,
        initialPrompt: prompt
      ) {
        inlineEditorState.errorMessage = error.localizedDescription
      } else {
        commentsState.clearAll()
        onDismiss()
      }
    }
  }

}

// MARK: - FileTreeNode

/// Represents a node in the hierarchical file tree (folder or file)
private class FileTreeNode: Identifiable {
  let id = UUID()
  let name: String                        // Folder or file name
  let fullPath: String                    // Full relative path
  var children: [FileTreeNode] = []       // Child nodes (populated after tree build)
  var childrenDict: [String: FileTreeNode] = [:] // Used during tree construction
  let file: GitDiffFileEntry?             // Non-nil for leaf file nodes

  var isFolder: Bool { file == nil }

  init(name: String, fullPath: String, file: GitDiffFileEntry?) {
    self.name = name
    self.fullPath = fullPath
    self.file = file
  }
}

// MARK: - FileTreeNodeRow

/// Recursive view for rendering tree nodes with proper indentation
private struct FileTreeNodeRow: View {
  let node: FileTreeNode
  let depth: Int
  @Binding var expandedPaths: Set<String>
  let selectedFileId: UUID?
  let onSelectFile: (GitDiffFileEntry) -> Void

  private var isExpanded: Bool {
    expandedPaths.contains(node.fullPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // This row
      Button(action: toggleOrSelect) {
        HStack(spacing: 4) {
          // Indentation based on depth
          if depth > 0 {
            Spacer()
              .frame(width: CGFloat(depth) * 16)
          }

          // Chevron (folders only)
          if node.isFolder {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundColor(.secondary)
              .frame(width: 12)
          } else {
            Spacer()
              .frame(width: 12)
          }

          // Icon
          Image(systemName: node.isFolder ? "folder.fill" : "doc.text")
            .font(.caption)
            .foregroundColor(node.isFolder ? .yellow : .blue)
            .frame(width: 16)

          // Name
          Text(node.name)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(node.isFolder ? .medium : .regular)
            .lineLimit(1)

          Spacer()

          // Change counts (files only)
          if let file = node.file {
            HStack(spacing: 2) {
              Text("+\(file.additions)")
                .foregroundColor(.green)
              Text("/")
                .foregroundColor(.secondary)
              Text("-\(file.deletions)")
                .foregroundColor(.red)
            }
            .font(.caption2.bold())
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.primary.opacity(0.15) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(isSelected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Children (if expanded folder)
      if node.isFolder && isExpanded {
        ForEach(node.children) { child in
          FileTreeNodeRow(
            node: child,
            depth: depth + 1,
            expandedPaths: $expandedPaths,
            selectedFileId: selectedFileId,
            onSelectFile: onSelectFile
          )
        }
      }
    }
  }

  private var isSelected: Bool {
    guard let file = node.file else { return false }
    return file.id == selectedFileId
  }

  private func toggleOrSelect() {
    if node.isFolder {
      // Toggle expansion
      if isExpanded {
        expandedPaths.remove(node.fullPath)
      } else {
        expandedPaths.insert(node.fullPath)
      }
    } else if let file = node.file {
      // Select file
      onSelectFile(file)
    }
  }
}

// MARK: - GitDiffFileRow

private struct GitDiffFileRow: View {
  let entry: GitDiffFileEntry
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        // File icon
        Image(systemName: "doc.text")
          .font(.caption)
          .foregroundColor(.blue)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 2) {
          // File name
          Text(entry.fileName)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .lineLimit(1)

          // Directory path
          if !entry.directoryPath.isEmpty {
            Text(entry.directoryPath)
              .font(.caption2)
              .foregroundColor(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        // Change counts: +N / -N
        HStack(spacing: 2) {
          Text("+\(entry.additions)")
            .foregroundColor(.green)
          Text("/")
            .foregroundColor(.secondary)
          Text("-\(entry.deletions)")
            .foregroundColor(.red)
        }
        .font(.caption2.bold())
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color.primary.opacity(0.15) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(isSelected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - GitDiffContentView

/// Wrapper that adds header controls to PierreDiffView
private struct GitDiffContentView: View {
  let oldContent: String
  let newContent: String
  let fileName: String
  let filePath: String

  @Binding var showSidebar: Bool
  @Binding var diffStyle: DiffStyle
  @Binding var overflowMode: OverflowMode
  @Bindable var inlineEditorState: InlineEditorState
  @Bindable var commentsState: DiffCommentsState
  let claudeClient: (any ClaudeCode)?
  let cliConfiguration: CLICommandConfiguration?
  let providerKind: SessionProviderKind
  let session: CLISession
  let onDismissView: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?

  @State private var webViewOpacity: Double = 1.0
  @State private var isWebViewReady = false

  /// Inline editor is enabled when either claudeClient or cliConfiguration is available
  private var isInlineEditorEnabled: Bool {
    let enabled = claudeClient != nil || cliConfiguration != nil
    return enabled
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with file info and controls
      headerView

      // Diff view with inline editor overlay
      GeometryReader { geometry in
        ZStack {
          PierreDiffView(
            oldContent: oldContent,
            newContent: newContent,
            fileName: fileName,
            diffStyle: $diffStyle,
            overflowMode: $overflowMode,
            onLineClickWithPosition: isInlineEditorEnabled ? { position, localPoint in
              print("[GitDiffContentView] Line clicked! lineNumber=\(position.lineNumber), side=\(position.side)")
              let anchorPoint = CGPoint(x: geometry.size.width / 2, y: localPoint.y)

              // Determine which content to use based on the side (left=old, right=new)
              let fileContent = position.side == "left" ? oldContent : newContent
              let lineContent = extractLine(from: fileContent, lineNumber: position.lineNumber)

              withAnimation(.easeOut(duration: 0.2)) {
                inlineEditorState.show(
                  at: anchorPoint,
                  lineNumber: position.lineNumber,
                  side: position.side,
                  fileName: filePath,
                  lineContent: lineContent,
                  fullFileContent: fileContent
                )
              }
            } : nil,
            onReady: {
              withAnimation(.easeInOut(duration: 0.3)) {
                isWebViewReady = true
              }
            }
          )
          .opacity(isWebViewReady ? webViewOpacity : 0)

          if !isWebViewReady {
            VStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)
              Text("Loading diff...")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
          }

          // Inline editor overlay - shown when claudeClient or cliConfiguration is available
          if isInlineEditorEnabled {
            InlineEditorOverlay(
              state: inlineEditorState,
              containerSize: geometry.size,
              providerKind: providerKind,
              onSubmit: { message, lineNumber, side, file in
                // Build contextual prompt with line context
                let prompt = buildInlinePrompt(
                  question: message,
                  lineNumber: lineNumber,
                  side: side,
                  lineContent: inlineEditorState.lineContent ?? "",
                  fileName: file
                )

                // Use callback if provided (redirects to built-in terminal)
                if let callback = onInlineRequestSubmit {
                  callback(prompt, session)
                  inlineEditorState.dismiss()
                  onDismissView()
                } else if let client = claudeClient {
                  // Fallback to external Terminal with claudeClient
                  if let error = TerminalLauncher.launchTerminalWithSession(
                    session.id,
                    claudeClient: client,
                    projectPath: session.projectPath,
                    initialPrompt: prompt
                  ) {
                    inlineEditorState.errorMessage = error.localizedDescription
                  } else {
                    onDismissView()
                  }
                } else if let config = cliConfiguration {
                  // Fallback to external Terminal with cliConfiguration
                  if let error = TerminalLauncher.launchTerminalWithSession(
                    session.id,
                    cliConfiguration: config,
                    projectPath: session.projectPath,
                    initialPrompt: prompt
                  ) {
                    inlineEditorState.errorMessage = error.localizedDescription
                  } else {
                    onDismissView()
                  }
                }
              },
              onAddComment: { message, lineNumber, side, file, lineContent in
                // Add comment to the collection
                commentsState.addComment(
                  filePath: file,
                  lineNumber: lineNumber,
                  side: side,
                  lineContent: lineContent,
                  text: message
                )
                // Auto-expand panel when first comment is added
                if commentsState.commentCount == 1 {
                  commentsState.isPanelExpanded = true
                }
              },
              commentsState: commentsState
            )
          }
        }
      }
      .animation(.easeInOut(duration: 0.3), value: isWebViewReady)
    }
  }

  private var headerView: some View {
    VStack(alignment: .leading) {
      HStack {
        Button {
          showSidebar.toggle()
        } label: {
          Image(systemName: "sidebar.left")
            .font(.system(size: 14))
            .foregroundStyle(showSidebar ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(showSidebar ? "Hide file list" : "Show file list")

        // File name with icon
        HStack {
          Image(systemName: "doc.text.fill")
            .foregroundStyle(.blue)
          Text(fileName)
            .font(.headline)
        }

        Spacer()

        HStack(spacing: 8) {
          // Split/Unified toggle button
          Button {
            toggleDiffStyle()
          } label: {
            Image(systemName: diffStyle == .split ? "rectangle.split.2x1" : "rectangle.stack")
              .font(.system(size: 14))
          }
          .buttonStyle(.plain)
          .help(diffStyle == .split ? "Switch to unified view" : "Switch to split view")

          // Wrap toggle button
          Button {
            toggleOverflowMode()
          } label: {
            Image(systemName: overflowMode == .wrap ? "text.alignleft" : "text.aligncenter")
              .font(.system(size: 14))
              .foregroundStyle(overflowMode == .wrap ? .primary : .secondary)
          }
          .buttonStyle(.plain)
          .help(overflowMode == .wrap ? "Disable word wrap" : "Enable word wrap")
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  // MARK: - Toggle Functions

  private func toggleDiffStyle() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      diffStyle = diffStyle == .split ? .unified : .split
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }

  private func toggleOverflowMode() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      overflowMode = overflowMode == .scroll ? .wrap : .scroll
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }

  // MARK: - Helper Functions

  /// Extracts a specific line from file content
  private func extractLine(from content: String, lineNumber: Int) -> String {
    let lines = content.components(separatedBy: .newlines)
    let index = lineNumber - 1 // Convert 1-indexed to 0-indexed
    guard index >= 0 && index < lines.count else {
      return ""
    }
    return lines[index]
  }

  /// Builds a contextual prompt for the inline question
  private func buildInlinePrompt(
    question: String,
    lineNumber: Int,
    side: String,
    lineContent: String,
    fileName: String
  ) -> String {
    let sideLabel = side == "left" ? "old" : "new"
    return """
      I have the following review comment on the code changes:

      ## \(fileName)

      **Line \(lineNumber)** (\(sideLabel)):
      ```
      \(lineContent)
      ```
      Comment: \(question)

      Please address this review comment.
      """
  }
}

// MARK: - Preview

#Preview {
  GitDiffView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    projectPath: "/Users/test/project",
    onDismiss: {}
  )
}
