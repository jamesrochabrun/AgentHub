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
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?

  @State private var diffState: GitDiffState = .empty
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var selectedFileId: UUID?
  @State private var diffContents: [UUID: (old: String, new: String)] = [:]
  @State private var loadingStates: [UUID: Bool] = [:]
  @State private var fileErrorMessages: [UUID: String] = [:]
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var inlineEditorState = InlineEditorState()
  @State private var diffMode: DiffMode = .unstaged
  @State private var detectedBaseBranch: String?
  @State private var commentsState = DiffCommentsState()
  @State private var showDiscardCommentsAlert = false

  private let gitDiffService = GitDiffService()

  public init(
    session: CLISession,
    projectPath: String,
    onDismiss: @escaping () -> Void,
    claudeClient: (any ClaudeCode)? = nil,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.claudeClient = claudeClient
    self.onInlineRequestSubmit = onInlineRequestSubmit
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
          HSplitView {
            // File list sidebar
            fileListSidebar
              .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

            // Diff viewer
            diffViewer
          }

          // Comments panel (shown when there are comments)
          if commentsState.hasComments {
            DiffCommentsPanelView(
              commentsState: commentsState,
              onSendToCloud: sendAllCommentsToCloud
            )
          }
        }
      }
    }
    .frame(minWidth: 1200, idealWidth: .infinity, maxWidth: .infinity,
           minHeight: 800, idealHeight: .infinity, maxHeight: .infinity)
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
        Image(systemName: "arrow.left.arrow.right")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Git Diff")
          .font(.title3.weight(.semibold))

        Text("(\(diffState.fileCount) files)")
          .font(.title3)
          .foregroundColor(.secondary)

        // Comment count badge
        if commentsState.hasComments {
          HStack(spacing: 4) {
            Image(systemName: "text.bubble.fill")
              .font(.caption)
            Text("\(commentsState.commentCount)")
              .font(.caption.bold())
          }
          .foregroundColor(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule()
              .fill(Color.brandPrimary)
          )
        }
      }

      Spacer()

      // Mode segmented control
      Picker("Diff Mode", selection: $diffMode) {
        ForEach(DiffMode.allCases) { mode in
          Label(mode.rawValue, systemImage: mode.icon)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 280)
      .onChange(of: diffMode) { _, newMode in
        Task { await loadChanges(for: newMode) }
      }

      Spacer()

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

      // File list
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(diffState.files) { file in
            GitDiffFileRow(
              entry: file,
              isSelected: selectedFileId == file.id,
              onSelect: {
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
            diffStyle: $diffStyle,
            overflowMode: $overflowMode,
            inlineEditorState: inlineEditorState,
            commentsState: commentsState,
            claudeClient: claudeClient,
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
      selectedFileId = nil
      loadingStates = [:]
      fileErrorMessages = [:]
    }

    do {
      // Detect base branch for branch mode (cache it for later use)
      if mode == .branch && detectedBaseBranch == nil {
        detectedBaseBranch = try await gitDiffService.detectBaseBranch(at: projectPath)
      }

      let state = try await gitDiffService.getChanges(
        at: projectPath,
        mode: mode,
        baseBranch: detectedBaseBranch
      )

      await MainActor.run {
        diffState = state
        isLoading = false

        // Auto-select first file
        if let first = state.files.first {
          selectedFileId = first.id
          loadFileDiff(for: first, mode: mode)
        }
      }

      // Preload first few file diffs in background
      await preloadInitialDiffs(for: state, mode: mode)

    } catch {
      await MainActor.run {
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
  }

  /// Preloads diffs for the first N files to enable instant display when selected
  private func preloadInitialDiffs(for state: GitDiffState, mode: DiffMode, count: Int = 3) async {
    let filesToPreload = Array(state.files.prefix(count))

    await withTaskGroup(of: Void.self) { group in
      for file in filesToPreload {
        // Skip if already loaded (first file was loaded during selection)
        if await MainActor.run(body: { diffContents[file.id] != nil }) {
          continue
        }

        group.addTask {
          do {
            let (oldContent, newContent) = try await gitDiffService.getFileDiff(
              filePath: file.filePath,
              at: projectPath,
              mode: mode,
              baseBranch: detectedBaseBranch
            )
            await MainActor.run {
              // Only set if not already loaded (avoid race conditions)
              if diffContents[file.id] == nil {
                diffContents[file.id] = (old: oldContent, new: newContent)
              }
            }
          } catch {
            // Silently ignore preload errors - they'll be shown when file is selected
          }
        }
      }
    }
  }

  private func loadFileDiff(for file: GitDiffFileEntry, mode: DiffMode? = nil) {
    // Skip if already loaded
    if diffContents[file.id] != nil { return }

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
    guard commentsState.hasComments else { return }

    let prompt = commentsState.generatePrompt()

    // Use callback if provided (redirects to built-in terminal)
    if let callback = onInlineRequestSubmit {
      callback(prompt, session)
      commentsState.clearAll()
      onDismiss()
    } else if let client = claudeClient {
      // Fallback to external Terminal
      if let error = TerminalLauncher.launchTerminalWithSession(
        session.id,
        claudeClient: client,
        projectPath: session.projectPath,
        initialPrompt: prompt
      ) {
        inlineEditorState.errorMessage = error.localizedDescription
      } else {
        // Clear comments and dismiss
        commentsState.clearAll()
        onDismiss()
      }
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

  @Binding var diffStyle: DiffStyle
  @Binding var overflowMode: OverflowMode
  @Bindable var inlineEditorState: InlineEditorState
  @Bindable var commentsState: DiffCommentsState
  let claudeClient: (any ClaudeCode)?
  let session: CLISession
  let onDismissView: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?

  @State private var webViewOpacity: Double = 1.0
  @State private var isWebViewReady = false

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
            onLineClickWithPosition: claudeClient != nil ? { position, localPoint in
              // Only enable inline editor when claudeClient is available
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

          // Inline editor overlay - only shown when claudeClient is available
          if let client = claudeClient {
            InlineEditorOverlay(
              state: inlineEditorState,
              containerSize: geometry.size,
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
                  inlineEditorState.dismiss()  // Dismiss inline editor first
                  onDismissView()
                } else {
                  // Fallback to external Terminal
                  if let error = TerminalLauncher.launchTerminalWithSession(
                    session.id,
                    claudeClient: client,
                    projectPath: session.projectPath,
                    initialPrompt: prompt
                  ) {
                    inlineEditorState.errorMessage = error.localizedDescription
                  } else {
                    // Dismiss entire diff view - session continues in Terminal
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
