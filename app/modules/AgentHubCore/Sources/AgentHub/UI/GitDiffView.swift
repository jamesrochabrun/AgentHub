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
        HSplitView {
          // File list sidebar
          fileListSidebar
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

          // Diff viewer
          diffViewer
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
      onDismiss()
      return .handled
    }
    .task {
      await loadUnstagedChanges()
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
        onDismiss()
      }
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Loading State

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading unstaged changes...")
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
        Task { await loadUnstagedChanges() }
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

      Text("No Unstaged Changes")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Your working directory is clean.")
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
                loadFileDiff(for: file)
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

  private func loadUnstagedChanges() async {
    isLoading = true
    errorMessage = nil

    do {
      let state = try await gitDiffService.getUnstagedChanges(at: projectPath)
      await MainActor.run {
        diffState = state
        isLoading = false

        // Auto-select first file
        if selectedFileId == nil, let first = state.files.first {
          selectedFileId = first.id
          loadFileDiff(for: first)
        }
      }
    } catch {
      await MainActor.run {
        errorMessage = error.localizedDescription
        isLoading = false
      }
    }
  }

  private func loadFileDiff(for file: GitDiffFileEntry) {
    // Skip if already loaded
    if diffContents[file.id] != nil { return }

    loadingStates[file.id] = true

    Task {
      do {
        let (oldContent, newContent) = try await gitDiffService.getFileDiff(
          filePath: file.filePath,
          at: projectPath
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
                  lineContent: inlineEditorState.lineContent ?? "",
                  fileName: file
                )

                // Use callback if provided (redirects to built-in terminal)
                if let callback = onInlineRequestSubmit {
                  callback(prompt, session)
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
              }
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
    lineContent: String,
    fileName: String
  ) -> String {
    return """
      I'm looking at line \(lineNumber) in \(fileName):
      ```
      \(lineContent)
      ```

      \(question)
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
