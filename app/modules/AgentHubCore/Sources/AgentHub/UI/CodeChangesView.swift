//
//  CodeChangesView.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI
import PierreDiffsSwift
import ClaudeCodeSDK

// MARK: - CodeChangesView

/// Full-screen sheet showing code diffs for a session
public struct CodeChangesView: View {
  let session: CLISession
  let codeChangesState: CodeChangesState
  let onDismiss: () -> Void

  /// Claude client for inline editor operations (optional - inline editor disabled if nil)
  let claudeClient: (any ClaudeCode)?

  @State private var selectedFileId: UUID?
  @State private var diffInputs: [UUID: DiffInputData] = [:]
  @State private var loadingStates: [UUID: Bool] = [:]
  @State private var errorMessages: [UUID: String] = [:]
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var inlineEditorState = InlineEditorState()
  @State private var commentsState = DiffCommentsState()

  /// Controls visibility of the confirmation dialog shown when closing with unsent comments.
  @State private var showDiscardCommentsAlert = false

  public init(
    session: CLISession,
    codeChangesState: CodeChangesState,
    onDismiss: @escaping () -> Void,
    claudeClient: (any ClaudeCode)? = nil
  ) {
    self.session = session
    self.codeChangesState = codeChangesState
    self.onDismiss = onDismiss
    self.claudeClient = claudeClient
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if codeChangesState.consolidatedChanges.isEmpty {
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
    .onAppear {
      // Auto-select first file
      if selectedFileId == nil, let first = codeChangesState.consolidatedChanges.first {
        selectedFileId = first.id
        loadConsolidatedDiff(for: first)
      }
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
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Code Changes")
          .font(.title3.weight(.semibold))

        Text("(\(codeChangesState.consolidatedChanges.count) files)")
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

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Code Changes")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("This session hasn't made any Edit, Write, or MultiEdit operations yet.")
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
          ForEach(codeChangesState.consolidatedChanges) { consolidated in
            ConsolidatedFileRow(
              change: consolidated,
              isSelected: selectedFileId == consolidated.id,
              onSelect: {
                selectedFileId = consolidated.id
                loadConsolidatedDiff(for: consolidated)
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
      } else if let error = errorMessages[selectedId] {
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
      } else if let diffData = diffInputs[selectedId] {
        DiffViewWithHeader(
          oldContent: diffData.oldContent,
          newContent: diffData.newContent,
          fileName: URL(fileURLWithPath: diffData.fileName).lastPathComponent,
          filePath: diffData.fileName,
          diffStyle: $diffStyle,
          overflowMode: $overflowMode,
          inlineEditorState: inlineEditorState,
          commentsState: commentsState,
          claudeClient: claudeClient,
          session: session,
          onDismissView: onDismiss
        )
        .frame(minHeight: 400)
        .id(selectedId)
      } else {
        // No diff loaded
        Text("Select a change to view")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      Text("Select a change to view")
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Load Consolidated Diff

  private func loadConsolidatedDiff(for consolidated: ConsolidatedFileChange) {
    // Skip if already loaded
    if diffInputs[consolidated.id] != nil { return }

    loadingStates[consolidated.id] = true

    Task {
      do {
        let diffData = try await generateConsolidatedDiffData(for: consolidated, projectPath: session.projectPath)
        await MainActor.run {
          diffInputs[consolidated.id] = diffData
          loadingStates[consolidated.id] = false
        }
      } catch {
        await MainActor.run {
          errorMessages[consolidated.id] = error.localizedDescription
          loadingStates[consolidated.id] = false
        }
      }
    }
  }

  private func generateConsolidatedDiffData(
    for consolidated: ConsolidatedFileChange,
    projectPath: String
  ) async throws -> DiffInputData {
    let fileReader = DefaultFileDataReader(projectPath: projectPath)

    // Read current file from disk (final state after all edits)
    guard let currentFileContent = try? await fileReader.readFileContent(
      in: [consolidated.filePath],
      maxTasks: 1
    ).values.first else {
      // File doesn't exist on disk - check if first operation was Write (new file)
      if let firstOp = consolidated.operations.first,
         firstOp.input.toolType == .write {
        // New file - show empty -> final content
        return DiffInputData(
          oldContent: "",
          newContent: firstOp.input.newString ?? "",
          fileName: consolidated.filePath
        )
      }
      // Fall back to snippet mode using first/last operation
      return fallbackSnippetDiff(for: consolidated)
    }

    // Reconstruct original content by reversing ALL operations
    var originalContent = currentFileContent

    // Process operations in REVERSE order (newest to oldest)
    for operation in consolidated.operations.reversed() {
      originalContent = reverseOperation(operation.input, in: originalContent)
    }

    return DiffInputData(
      oldContent: originalContent,
      newContent: currentFileContent,
      fileName: consolidated.filePath
    )
  }

  /// Reverses a single operation to reconstruct previous state
  private func reverseOperation(_ input: CodeChangeInput, in content: String) -> String {
    switch input.toolType {
    case .edit:
      guard let oldString = input.oldString,
            let newString = input.newString else { return content }

      if input.replaceAll == true {
        return content.replacingOccurrences(of: newString, with: oldString)
      } else if let range = content.range(of: newString) {
        return content.replacingCharacters(in: range, with: oldString)
      }
      return content

    case .write:
      // Write replaces entire file - we can't reconstruct previous content
      // The diff will show from when the Write happened
      return ""

    case .multiEdit:
      var result = content
      // Reverse each edit within MultiEdit in reverse order
      for edit in (input.edits ?? []).reversed() {
        guard let oldString = edit["old_string"],
              let newString = edit["new_string"] else { continue }
        let replaceAll = edit["replace_all"] == "true"

        if replaceAll {
          result = result.replacingOccurrences(of: newString, with: oldString)
        } else if let range = result.range(of: newString) {
          result = result.replacingCharacters(in: range, with: oldString)
        }
      }
      return result
    }
  }

  /// Fallback when file can't be read - use first operation's old content and last operation's new content
  private func fallbackSnippetDiff(for consolidated: ConsolidatedFileChange) -> DiffInputData {
    let firstOp = consolidated.operations.first?.input
    let lastOp = consolidated.operations.last?.input

    return DiffInputData(
      oldContent: firstOp?.oldString ?? "",
      newContent: lastOp?.newString ?? "",
      fileName: consolidated.filePath
    )
  }

  // MARK: - Comments Actions

  /// Sends all pending comments to Claude as a batch review
  private func sendAllCommentsToCloud() {
    guard commentsState.hasComments, let client = claudeClient else { return }

    let prompt = commentsState.generatePrompt()

    // Open Terminal with resumed session
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

// MARK: - DiffInputData

/// Value type that encapsulates the data needed to render a file diff.
///
/// Used internally by `CodeChangesView` to pass consolidated diff data to
/// `DiffViewWithHeader` for rendering. This separates the data transformation
/// logic (in `CodeChangesView`) from the rendering logic (in `DiffViewWithHeader`).
///
/// - Note: The `oldContent` and `newContent` are the full file contents,
///   not just the changed lines. The diff algorithm computes the differences.
private struct DiffInputData {
  /// The original file content before changes (left side of diff)
  let oldContent: String

  /// The modified file content after changes (right side of diff)
  let newContent: String

  /// The file path/name displayed in the diff header
  let fileName: String
}

// MARK: - DiffViewWithHeader

/// Wrapper that adds header controls to PierreDiffView without re-rendering issues
/// Replicates the exact UI from DiffEditsView's PierreDiffContentView
private struct DiffViewWithHeader: View {
  let oldContent: String
  let newContent: String

  /// The file name displayed in the header (e.g., "Example.swift")
  let fileName: String

  /// The complete file path used for inline editor context (e.g., "/Users/.../Example.swift")
  let filePath: String

  @Binding var diffStyle: DiffStyle
  @Binding var overflowMode: OverflowMode
  @Bindable var inlineEditorState: InlineEditorState
  @Bindable var commentsState: DiffCommentsState
  let claudeClient: (any ClaudeCode)?
  let session: CLISession

  /// Callback to dismiss the entire diff view.
  /// Called when the user submits from the inline editor and Terminal opens successfully,
  /// since the session continues in Terminal and the diff view won't receive updates.
  let onDismissView: () -> Void

  @State private var webViewOpacity: Double = 1.0
  @State private var isWebViewReady = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with file info and controls
      headerView

      // Diff view with inline editor overlay - both in same coordinate space
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
              // localPoint is already in SwiftUI-compatible coordinates (origin at top-left)
              // Use localPoint.y directly - already converted to top-left origin
              let anchorPoint = CGPoint(x: geometry.size.width / 2, y: localPoint.y)

              // Determine which content to use based on the side
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

                // Open Terminal with resumed session
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

// MARK: - ConsolidatedFileRow

private struct ConsolidatedFileRow: View {
  let change: ConsolidatedFileChange
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
          Text(change.fileName)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .lineLimit(1)

          // Operation summary
          Text(change.operationSummary)
            .font(.caption2)
            .foregroundColor(.secondary)
        }

        Spacer()

        // Operation count badge (only show if > 1)
        if change.operationCount > 1 {
          Text("\(change.operationCount)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.brandPrimary))
        }
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

// MARK: - Preview

#Preview {
  CodeChangesView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    codeChangesState: CodeChangesState(changes: [
      // Multiple edits to same file - will be consolidated
      CodeChangeEntry(
        id: UUID(),
        timestamp: Date().addingTimeInterval(-60),
        input: CodeChangeInput(
          toolType: .edit,
          filePath: "/Users/test/project/src/main.swift",
          oldString: "let x = 1",
          newString: "let x = 2"
        )
      ),
      CodeChangeEntry(
        id: UUID(),
        timestamp: Date().addingTimeInterval(-45),
        input: CodeChangeInput(
          toolType: .edit,
          filePath: "/Users/test/project/src/main.swift",
          oldString: "let y = 1",
          newString: "let y = 2"
        )
      ),
      // Different file
      CodeChangeEntry(
        id: UUID(),
        timestamp: Date().addingTimeInterval(-30),
        input: CodeChangeInput(
          toolType: .write,
          filePath: "/Users/test/project/src/new-file.swift",
          newString: "// New file content"
        )
      )
    ]),
    onDismiss: {}
  )
}
